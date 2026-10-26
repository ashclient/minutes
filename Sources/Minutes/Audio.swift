import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia

@MainActor final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var failure: String?
    private var microphone: AVAudioRecorder?
    private var computer: ComputerAudio?
    private var timer: Timer?
    private var started = Date()
    private(set) var meetingID: UUID?
    private(set) var files: [String] = []

    func start(id: UUID, directory: URL, includeComputer: Bool) async throws {
        guard !recording else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppFailure("Microphone access is off. Enable Minutes in System Settings → Privacy & Security → Microphone.") }
        let stem = "\(id.uuidString)-\(UUID().uuidString)"
        let micName = stem + "-mic.m4a"
        let rec = try AVAudioRecorder(url: directory.appendingPathComponent(micName), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        rec.isMeteringEnabled = true
        var system: ComputerAudio?
        do {
            if includeComputer {
                let capture = ComputerAudio()
                try await capture.start(url: directory.appendingPathComponent(stem + "-computer.m4a"))
                system = capture
            }
            guard rec.record() else { throw AppFailure("The microphone could not start. Check that an input device is connected.") }
        } catch {
            if let system { try? await system.stop() }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(micName))
            throw error
        }
        microphone = rec; computer = system; meetingID = id; files = [micName]
        if includeComputer { files.append(stem + "-computer.m4a") }
        started = Date(); elapsed = 0; failure = nil; recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
                if self.microphone?.isRecording == false { self.failure = "The microphone stopped unexpectedly. Stop and save, then check your input device." }
                self.microphone?.updateMeters()
                self.level = pow(10, (self.microphone?.averagePower(forChannel: 0) ?? -160) / 40)
                if let error = self.computer?.captureFailure { self.failure = error }
            }
        }
    }
    func stop() async -> (UUID, [String])? {
        guard recording, let id = meetingID else { return nil }
        timer?.invalidate(); timer = nil; microphone?.stop(); microphone = nil
        if let computer { do { try await computer.stop() } catch { failure = error.localizedDescription } }
        self.computer = nil; recording = false; level = 0; meetingID = nil
        return (id, files)
    }
}

// Audio buffers are serialized on queue; only audio is written to disk.
final class ComputerAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Minutes.computer-audio")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let lock = NSLock()
    private var failure: String?
    var captureFailure: String? { lock.lock(); defer { lock.unlock() }; return failure }
    private func fail(_ text: String) { lock.lock(); failure = text; lock.unlock() }

    func start(url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppFailure("No display available for computer audio capture.") }
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AppFailure("Could not configure computer audio recording.") }
        writer.add(input); self.writer = writer; self.input = input
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(buffer), let writer, let input else { return }
        if writer.status == .unknown {
            guard writer.startWriting() else { fail(writer.error?.localizedDescription ?? "Computer audio could not start writing."); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            if !input.append(buffer) { fail(writer.error?.localizedDescription ?? "A computer audio buffer could not be saved.") }
        } else if writer.status == .failed { fail(writer.error?.localizedDescription ?? "Computer audio capture failed.") }
        else if writer.status == .writing { fail("Computer audio storage could not keep up. The recording may have gaps.") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error.localizedDescription) }
    func stop() async throws {
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        let outputWriter = writer
        let outputInput = input
        let currentFailure = captureFailure
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let writer = outputWriter, let input = outputInput else { continuation.resume(); return }
                guard writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume(throwing: AppFailure(currentFailure ?? "No computer audio was captured. The microphone recording is still saved.")); return
                }
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? AppFailure("Could not finish computer audio.")) }
                }
            }
        }
        if let stopError { throw stopError }
        if let error = captureFailure { throw AppFailure(error) }
    }
}

@MainActor final class SpeechTranscriber {
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[TranscriptLine], Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?

    func transcribe(url: URL, source: String, timeOffset: Double = 0, progress: (String) -> Void, partial: ([TranscriptLine]) -> Void) async throws -> [TranscriptLine] {
        let permission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard permission == .authorized else { throw AppFailure("Enable Speech Recognition for Minutes in System Settings → Privacy & Security.") }
        let locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw AppFailure("On-device recognition is unavailable for \(locale) on this Mac. Try enabling Dictation and downloading that language in System Settings → Keyboard, then relaunch. You can also paste a transcript in Details.")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AppFailure("This audio file is empty or unreadable.") }
        var lines: [TranscriptLine] = []
        var offset = 0.0
        while offset < duration {
            try Task.checkCancellation()
            progress("Transcribing \(source.lowercased()) · \(Int(offset / max(duration, 1) * 100))%")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw AppFailure("This audio format cannot be decoded. Try M4A, MP3, or WAV.") }
            exporter.outputURL = temporary; exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600), duration: CMTime(seconds: min(45, duration - offset), preferredTimescale: 600))
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? AppFailure("Could not prepare audio for transcription.") }
            let chunk = try await recognize(temporary, recognizer: recognizer, source: source, offset: timeOffset + offset)
            lines += chunk; partial(lines)
            offset += 45
        }
        return lines
    }
    private func recognize(_ url: URL, recognizer: SFSpeechRecognizer, source: String, offset: Double) async throws -> [TranscriptLine] {
        let token = UUID()
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.requestID = token
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.continuation != nil, self.requestID == token else { return }
                        if let result, result.isFinal {
                            var lines: [TranscriptLine] = []; var words: [String] = []; var start = 0.0
                            for segment in result.bestTranscription.segments {
                                if words.isEmpty { start = segment.timestamp }
                                words.append(segment.substring)
                                if segment.timestamp - start >= 12 || segment.substring.hasSuffix(".") || segment.substring.hasSuffix("?") {
                                    lines.append(TranscriptLine(seconds: offset + start, source: source, text: words.joined(separator: " "))); words = []
                                }
                            }
                            if !words.isEmpty { lines.append(TranscriptLine(seconds: offset + start, source: source, text: words.joined(separator: " "))) }
                            self.finish(.success(lines))
                        } else if let error {
                            if (error as NSError).code == 1110 { self.finish(.success([])) }
                            else { self.finish(.failure(error)) }
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                    self?.finish(.failure(AppFailure("Speech recognition timed out. Saved audio and completed transcript sections are retained.")))
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }
    private func finish(_ result: Result<[TranscriptLine], Error>) {
        guard let continuation else { return }
        self.continuation = nil; requestID = nil; timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        continuation.resume(with: result)
    }
}
