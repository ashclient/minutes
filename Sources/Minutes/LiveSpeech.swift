import AVFoundation
import Speech
import SwiftUI

// The audio callback and recognition rotations share only this locked buffer feed.
final class SpeechFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var history: [AVAudioPCMBuffer] = []
    private var historySeconds = 0.0
    private var totalSeconds = 0.0
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        totalSeconds += seconds
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in src.indices {
            if let from = src[i].mData, let to = dst[i].mData { memcpy(to, from, Int(src[i].mDataByteSize)) }
        }
        history.append(copy); historySeconds += seconds
        while historySeconds > 3.5, history.count > 1 {
            let removed = history.removeFirst(); historySeconds -= Double(removed.frameLength) / removed.format.sampleRate
        }
    }
    func replace(with next: SFSpeechAudioBufferRecognitionRequest) -> (Double, Double, SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        let previous = request
        for buffer in history { next.append(buffer) }
        request = next
        return (totalSeconds - historySeconds, totalSeconds, previous)
    }
    func finish() {
        lock.lock(); let previous = request; request = nil; lock.unlock()
        previous?.endAudio()
    }
}

@MainActor final class LiveSpeech {
    private struct Session {
        var id: UUID
        var offset: Double
        var from: Double
        var to = Double.infinity
        var tokens: [SpeechToken] = []
        var final = false
    }
    private let feed = SpeechFeed()
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var sessions: [Session] = []
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var timer: Timer?
    private var stopped = false
    private var failed = false
    private var onText: (([TranscriptLine]) -> Void)?

    func start(onText: @escaping ([TranscriptLine]) -> Void) async throws {
        let permission = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard permission == .authorized else { throw AppFailure("Live speech permission is unavailable.") }
        let locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw AppFailure("Live on-device speech is unavailable for this language.") }
        self.recognizer = recognizer; self.onText = onText
        let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure("No microphone input for live transcription.") }
        rotate()
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); feed.finish(); tasks.values.forEach { $0.cancel() }; throw error }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rotate() }
        }
    }
    private func rotate() {
        guard !stopped, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.addsPunctuation = true; request.taskHint = .dictation
        let (offset, total, previous) = feed.replace(with: request)
        // Transfer the last second to the new request, with 3 seconds of context.
        let boundary = sessions.isEmpty ? 0 : max(0, total - 1)
        if !sessions.isEmpty { sessions[sessions.count - 1].to = boundary }
        let id = UUID(); sessions.append(Session(id: id, offset: offset, from: boundary))
        previous?.endAudio()
        tasks[id] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                if let result {
                    let base = self.sessions[index].offset
                    self.sessions[index].tokens = result.bestTranscription.segments.map { SpeechToken(seconds: base + $0.timestamp, duration: $0.duration, text: $0.substring) }
                    self.sessions[index].final = result.isFinal
                    self.publish()
                }
                if error != nil, !self.sessions[index].final { self.failed = true }
            }
        }
    }
    private func publish() {
        let tokens = sessions.flatMap { session in session.tokens.filter {
            let midpoint = $0.seconds + $0.duration / 2
            return midpoint >= session.from && midpoint < session.to
        } }
        onText?(SpeechParagraphs.lines(tokens, source: "Microphone", timeOffset: 0))
    }
    func stop() async -> Bool {
        stopped = true; timer?.invalidate(); timer = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        feed.finish()
        for _ in 0..<40 {
            if sessions.allSatisfy(\.final) || failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        publish()
        let complete = !failed && !sessions.isEmpty && sessions.allSatisfy(\.final)
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); onText = nil
        return complete
    }
}
