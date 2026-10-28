import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia

@MainActor final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var failure: String?
    @Published var liveStatus = ""
    var onLiveText: (([TranscriptLine], String) -> Void)?
    private var live: LiveSpeech?
    private(set) var liveComplete = false
    private var microphone: MicrophoneCapture?
    @Published var inputName = "System microphone"
    private(set) var diagnostics = ""
    private(set) var voicedDuration = 0.0
    private var liveWords = 0
    private var computer: ComputerAudio?
    private var timer: Timer?
    private var started = Date()
    private(set) var meetingID: UUID?
    private(set) var files: [String] = []

    func start(id: UUID, directory: URL, includeComputer: Bool) async throws {
        guard !recording else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppFailure("Microphone access is off. Enable Minutes in System Settings → Privacy & Security → Microphone.") }
        let speech = LiveSpeech()
        var liveAvailable = true
        do { try await speech.prepare() } catch { liveAvailable = false }
        let stem = "\(id.uuidString)-\(UUID().uuidString)"
        let micName = stem + "-mic.caf"
        let rec = MicrophoneCapture()
        liveStatus = "Live microphone transcript"
        var system: ComputerAudio?
        do {
            if includeComputer {
                let capture = ComputerAudio()
                try await capture.start(url: directory.appendingPathComponent(stem + "-computer.m4a"))
                system = capture
            }
            if liveAvailable {
                do {
                    try await speech.start { [weak self] lines in
                        self?.liveWords = lines.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
                        self?.onLiveText?(lines, micName)
                    }
                    live = speech
                } catch { liveAvailable = false; liveStatus = error.localizedDescription }
            }
            if !liveAvailable { liveStatus = "Live speech unavailable; saved audio will be transcribed after stopping." }
            try rec.start(url: directory.appendingPathComponent(micName), feed: speech.feed)
        } catch {
            if let live { _ = await live.stop() }; live = nil
            if let system { try? await system.stop() }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(micName))
            throw error
        }
        microphone = rec; computer = system; meetingID = id; files = [micName]
        if includeComputer { files.append(stem + "-computer.m4a") }
        started = Date(); elapsed = 0; failure = nil; recording = true
        liveComplete = false; liveWords = 0; voicedDuration = 0
        inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "System microphone"
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
                if let microphone = self.microphone {
                    let status = microphone.status
                    self.level = status.0
                    if let error = status.1 { self.failure = error }
                }
                if let live = self.live { self.liveStatus = live.status }
                if let error = self.computer?.captureFailure { self.failure = error }
            }
        }
    }
    func stop() async -> (UUID, [String])? {
        guard recording, let id = meetingID else { return nil }
        timer?.invalidate(); timer = nil
        await microphone?.stop(); voicedDuration = microphone?.voicedDuration ?? 0; microphone = nil
        if let live { liveComplete = await live.stop() }; live = nil
        if voicedDuration > 10, Double(liveWords) < voicedDuration * 0.5 { liveComplete = false; liveStatus = "Very little speech recognized; checking the saved audio." }
        if let computer { do { try await computer.stop() } catch { failure = error.localizedDescription } }
        diagnostics = "Input: \(inputName). Duration: \(Int(elapsed))s. Microphone signal: \(Int(voicedDuration))s. Live words: \(liveWords). Live finalized: \(liveComplete). Status: \(liveStatus)."
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
    private var continuation: CheckedContinuation<[SpeechToken], Error>?
    private var latestTokens: [SpeechToken] = []
    private var textAccumulator = LiveTextAccumulator()
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?

    func transcribe(url: URL, source: String, timeOffset: Double = 0, progress: (String) -> Void, partial: @escaping ([TranscriptLine]) -> Void) async throws -> [TranscriptLine] {
        if #available(macOS 26.0, *) {
            return try await TahoeSpeech.transcribe(url: url, source: source, timeOffset: timeOffset, progress: progress, partial: partial)
        }
        let permission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard permission == .authorized else { throw AppFailure("Enable Speech Recognition for Minutes in System Settings → Privacy & Security.") }
        let locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw AppFailure("On-device recognition is unavailable for \(locale) on this Mac. Try enabling Dictation and downloading that language in System Settings → Keyboard, then relaunch. You can also paste a transcript in Details.")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AppFailure("This audio file is empty or unreadable.") }
        var text = ""
        let windows = SpeechWindow.plan(duration: duration)
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            progress("Transcribing \(source.lowercased()) · \(index + 1) of \(windows.count)")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw AppFailure("This audio format cannot be decoded. Try M4A, MP3, or WAV.") }
            exporter.outputURL = temporary; exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 600), duration: CMTime(seconds: window.end - window.start, preferredTimescale: 600))
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw exporter.error ?? AppFailure("Could not prepare audio for transcription.") }
            let recognized = try await recognize(temporary, recognizer: recognizer, offset: window.start)
            text = TranscriptText.stitch(text, recognized.map(\.text).joined(separator: " "))
            partial(text.isEmpty ? [] : [TranscriptLine(seconds: timeOffset, source: source, text: text)])
        }
        return text.isEmpty ? [] : [TranscriptLine(seconds: timeOffset, source: source, text: text)]
    }
    private func recognize(_ url: URL, recognizer: SFSpeechRecognizer, offset: Double) async throws -> [SpeechToken] {
        let token = UUID()
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.requestID = token
                self.latestTokens = []; self.textAccumulator = LiveTextAccumulator()
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.continuation != nil, self.requestID == token else { return }
                        if let result {
                            self.textAccumulator.update(result.bestTranscription.formattedString)
                            self.latestTokens = [SpeechToken(seconds: offset, duration: 0, text: self.textAccumulator.text)]
                            if result.isFinal { self.finish(.success(self.latestTokens)); return }
                        }
                        if let error {
                            // A trailing no-speech event must not discard words already recognized.
                            if (error as NSError).code == 1110 { self.finish(.success(self.latestTokens)) }
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
    private func finish(_ result: Result<[SpeechToken], Error>) {
        guard let continuation else { return }
        self.continuation = nil; requestID = nil; timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        continuation.resume(with: result)
    }
}
