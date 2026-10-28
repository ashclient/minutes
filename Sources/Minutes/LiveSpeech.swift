import AVFoundation
import Speech
import SwiftUI

final class SpeechFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var history: [(AVAudioPCMBuffer, Double, Double)] = []
    private var total = 0.0
    private var modern: (@Sendable (AVAudioPCMBuffer) -> Void)?
    func connectModern(_ callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { lock.lock(); modern = callback; lock.unlock() }
    func disconnectModern() { lock.lock(); modern = nil; lock.unlock() }
    var receivedSeconds: Double { lock.lock(); defer { lock.unlock() }; return total }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let modern { modern(buffer) } else { request?.append(buffer) }
        let start = total; total += Double(buffer.frameLength) / buffer.format.sampleRate
        // The capture worker gives us independently owned buffers.
        history.append((buffer, start, total))
        while let first = history.first, first.2 < total - 12 { history.removeFirst() }
    }
    func attach(_ next: SFSpeechAudioBufferRecognitionRequest, since: Double) {
        lock.lock(); defer { lock.unlock() }
        for (buffer, _, end) in history where end > since { next.append(buffer) }
        request = next
    }
    @discardableResult func detach() -> Double {
        lock.lock(); let previous = request; request = nil; let time = total; lock.unlock()
        previous?.endAudio(); return time
    }
}

@MainActor final class LiveSpeech {
    let feed = SpeechFeed()
    private var modern: AnyObject?
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var transition: Task<Void, Never>?
    private var stopped = false
    private var ended = false
    private var failed = false
    private var token = UUID()
    private var completed = ""
    private var current = LiveTextAccumulator()
    private var onText: (([TranscriptLine]) -> Void)?
    var status = "Live microphone transcript"
    func prepare() async throws {
        if #available(macOS 26.0, *) {
            let session = TahoeSpeech()
            try await session.prepare()
            modern = session; status = "Apple SpeechAnalyzer · on device"
            return
        }
        let permission = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard permission == .authorized else { throw AppFailure("Speech permission is off. Enable Minutes in Privacy & Security → Speech Recognition.") }
        let locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw AppFailure("On-device speech is unavailable for \(locale). Check Dictation language assets in macOS Keyboard settings.") }
        self.recognizer = recognizer
    }
    func start(onText: @escaping ([TranscriptLine]) -> Void) async throws {
        if recognizer == nil && modern == nil { try await prepare() }
        if #available(macOS 26.0, *), let modern = modern as? TahoeSpeech {
            try await modern.start(feed: feed, onText: onText)
            return
        }
        self.onText = onText; begin(since: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rotate() }
        }
    }
    private func begin(since: Double) {
        guard !stopped, let recognizer else { return }
        token = UUID(); let id = token; ended = false; current = LiveTextAccumulator()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.taskHint = .dictation; request.addsPunctuation = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.token == id else { return }
                if let result { self.current.update(result.bestTranscription.formattedString); self.ended = result.isFinal; self.publish() }
                if let error, !self.ended {
                    self.failed = true; self.ended = true
                    self.status = "Live speech interrupted (\((error as NSError).code)); saved audio will be checked after stopping."
                }
                if self.ended, !self.stopped { self.rotate() }
            }
        }
        feed.attach(request, since: since)
    }
    private func rotate() {
        guard !stopped, transition == nil else { return }
        let cutoff = feed.detach()
        transition = Task {
            // Finish/cancel the previous task BEFORE creating the next one.
            // Incoming audio remains buffered during this handoff.
            for _ in 0..<20 {
                if ended || stopped { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !stopped else { transition = nil; return }
            if !ended { failed = true }
            task?.cancel(); token = UUID()
            completed = TranscriptText.stitch(completed, current.text)
            begin(since: max(0, cutoff - 2))
            transition = nil
        }
    }
    private func publish() {
        let text = TranscriptText.stitch(completed, current.text)
        onText?(text.isEmpty ? [] : [TranscriptLine(seconds: 0, source: "Microphone", text: text)])
    }
    func stop() async -> Bool {
        if #available(macOS 26.0, *), let modern = modern as? TahoeSpeech {
            let complete = await modern.stop(feed: feed)
            if let error = modern.failure { status = "Apple speech: " + error }
            return complete
        }
        stopped = true; timer?.invalidate(); timer = nil
        await transition?.value
        feed.detach()
        for _ in 0..<40 {
            if ended { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        publish(); task?.cancel(); token = UUID(); onText = nil
        return !failed && ended
    }
}
