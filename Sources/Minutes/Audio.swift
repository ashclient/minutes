import AVFoundation
import Speech
import CoreMedia

@MainActor final class Recorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var paused = false
    @Published private(set) var microphoneMuted = false
    @Published private(set) var computerEnabled = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var computerLevel: Float = 0
    @Published var failure: String?
    @Published private(set) var liveStatus = ""
    @Published private(set) var computerStatus = "Off"
    @Published private(set) var inputName = "System microphone"
    @Published private(set) var meetingID: UUID?
    var onLiveText: (([TranscriptLine], String) -> Void)?
    private var live: LiveSpeech?
    private var computerSpeech: LiveSpeech?
    private var microphone: MicrophoneCapture?
    private var computer: ComputerAudio?
    private var timer: Timer?
    private var lastTick = Date()
    private var micName = ""
    private var computerName = ""
    private var liveWords = 0
    private(set) var completedFiles: [String] = []
    private(set) var diagnostics = ""
    private(set) var voicedDuration = 0.0
    private(set) var files: [String] = []

    func start(id: UUID, directory: URL, includeComputer: Bool) async throws {
        guard !recording else { return }
        try Task.checkCancellation()
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppFailure("Microphone access is off. Enable Minutes in System Settings → Privacy & Security → Microphone.") }
        paused = false; microphoneMuted = false; computerEnabled = includeComputer
        completedFiles = []; liveWords = 0; voicedDuration = 0; elapsed = 0; failure = nil
        let stem = "\(id.uuidString)-\(UUID().uuidString)"
        micName = stem + "-mic.caf"; computerName = stem + "-computer.caf"
        let microphoneSpeech = LiveSpeech()
        let mic = MicrophoneCapture()
        var system: ComputerAudio?
        do {
            do {
                try await microphoneSpeech.prepare()
                try Task.checkCancellation()
                try await microphoneSpeech.start { [weak self] lines in
                    guard let self else { return }
                    self.liveWords = lines.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
                    self.onLiveText?(lines, self.micName)
                }
                live = microphoneSpeech; liveStatus = microphoneSpeech.status
            } catch { liveStatus = "Live microphone speech unavailable; saved audio will be transcribed after stopping." }
            try Task.checkCancellation()
            if includeComputer {
                let speech = LiveSpeech(source: "Computer")
                do {
                    try await speech.prepare()
                    try await speech.start { [weak self] lines in
                        guard let self else { return }; self.onLiveText?(lines, self.computerName)
                    }
                    computerSpeech = speech
                } catch { computerStatus = "Live computer speech unavailable; transcribing after stopping." }
                let capture = ComputerAudio()
                do { try await capture.start(url: directory.appendingPathComponent(computerName), feed: speech.feed) }
                catch { throw AppFailure("Computer audio could not start. " + error.localizedDescription) }
                system = capture
            }
            try Task.checkCancellation()
            try mic.start(url: directory.appendingPathComponent(micName), feed: microphoneSpeech.feed)
        } catch {
            if let live { _ = await live.stop() }; live = nil
            if let computerSpeech { _ = await computerSpeech.stop() }; computerSpeech = nil
            if let system { try? await system.stop() }
            for name in [micName, computerName] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            throw error
        }
        microphone = mic; computer = system; meetingID = id; files = [micName]
        if includeComputer { files.append(computerName); computerStatus = "Waiting for computer audio" }
        recording = true; lastTick = Date()
        inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "System microphone"
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }
    private func tick() {
        let now = Date()
        if !paused { elapsed += now.timeIntervalSince(lastTick) }; lastTick = now
        if let mic = microphone {
            let state = mic.status; level = paused || microphoneMuted ? 0 : state.0
            if let error = state.1 { failure = error }
        }
        if let live { liveStatus = live.status }
        if let computer {
            let state = computer.status; computerLevel = paused ? 0 : state.0
            computerStatus = state.2 > 0 ? (state.0 > 0.015 ? "Receiving computer audio" : "Connected · quiet") : "Waiting for computer audio"
            if let error = state.1 { failure = error; computerStatus = error }
        }
    }
    func toggleMicrophone() {
        guard recording else { return }; microphoneMuted.toggle()
        microphone?.setGate(paused: paused, muted: microphoneMuted)
        if microphoneMuted { level = 0 }
    }
    func togglePause() {
        guard recording else { return }; tick(); paused.toggle()
        microphone?.setGate(paused: paused, muted: microphoneMuted)
        computer?.setPaused(paused)
        if paused { level = 0; computerLevel = 0 }
    }
    func stop() async -> (UUID, [String])? {
        guard recording, let id = meetingID else { return nil }
        tick(); timer?.invalidate(); timer = nil
        await microphone?.stop(); voicedDuration = microphone?.voicedDuration ?? 0; microphone = nil
        if let computer { do { try await computer.stop() } catch { failure = error.localizedDescription } }
        if let live, await live.stop(), !(voicedDuration > 10 && Double(liveWords) < voicedDuration * 0.5) { completedFiles.append(micName) }
        if let computerSpeech, await computerSpeech.stop() { completedFiles.append(computerName) }
        // An idle source may deliver no buffers at all. Never hand a missing file to transcription.
        if let computer, !computer.hasFrames { files.removeAll { $0 == computerName }; completedFiles.removeAll { $0 == computerName } }
        diagnostics = "Input: \(inputName). Duration: \(Int(elapsed))s. Microphone signal: \(Int(voicedDuration))s. Microphone words: \(liveWords). Computer: \(computerEnabled ? computerStatus : "Off")."
        live = nil; computerSpeech = nil; computer = nil
        recording = false; paused = false; level = 0; computerLevel = 0; meetingID = nil
        return (id, files)
    }
    // Close audio without waiting for speech or AI. Saved tracks can be finished later.
    func saveForQuit() async {
        timer?.invalidate(); timer = nil
        microphone?.setGate(paused: true, muted: microphoneMuted); computer?.setPaused(true)
        live?.cancel(); computerSpeech?.cancel(); onLiveText = nil
        await microphone?.stop(); microphone = nil
        if let computer { try? await computer.stop() }
        live = nil; computerSpeech = nil; computer = nil; recording = false
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
