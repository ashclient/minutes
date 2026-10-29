import Foundation
import AVFoundation
import Speech

// Buffers are independently owned by the capture worker and never mutated after delivery.
struct CapturedPCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

@available(macOS 26.0, *)
@MainActor final class TahoeSpeech {
    private var module: Speech.SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Error>?
    private var pump: Task<Void, Error>?
    private var continuation: AsyncStream<CapturedPCM>.Continuation?
    private var finalized: [TranscriptLine] = []
    private var volatile = ""
    private var onText: (([TranscriptLine]) -> Void)?
    private var source = "Microphone"
    private var timeOffset = 0.0
    private(set) var failure: String?

    func prepare(live: Bool = true) async throws {
        guard Speech.SpeechTranscriber.isAvailable else { throw AppFailure("Apple’s Tahoe transcription is unavailable on this hardware.") }
        let requested = Locale(identifier: UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US")
        guard let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: requested) else { throw AppFailure("Apple’s Tahoe transcription does not support this language. Choose another in Settings.") }
        let transcriber = Speech.SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: live ? [.volatileResults] : [], attributeOptions: [.audioTimeRange])
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download.downloadAndInstall()
        }
        module = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }
    private func collect() throws {
        guard let module else { throw AppFailure("Apple speech was not prepared.") }
        results = Task {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized.append(TranscriptLine(seconds: timeOffset + result.range.start.seconds, source: source, text: text))
                        volatile = ""
                    } else { volatile = text }
                    publish()
                }
            } catch { failure = error.localizedDescription; throw error }
        }
    }
    private func publish() {
        var lines = finalized
        if !volatile.isEmpty { lines.append(TranscriptLine(seconds: finalized.last?.seconds ?? timeOffset, source: source, text: volatile)) }
        onText?(lines)
    }
    func start(feed: SpeechFeed, source: String = "Microphone", onText: @escaping ([TranscriptLine]) -> Void) async throws {
        guard let analyzer, let module else { throw AppFailure("Apple speech was not prepared.") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw AppFailure("Apple speech language assets are not ready. Check your network and try again.") }
        self.onText = onText; self.source = source
        try collect()
        let (audio, builder) = AsyncStream<CapturedPCM>.makeStream()
        continuation = builder
        let (inputs, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        pump = Task {
            let conversion = SpeechPCMConverter(target: format)
            do {
                for await packet in audio {
                    try Task.checkCancellation()
                    let buffer = try conversion.convert(packet.buffer)
                    if buffer.frameLength > 0 { inputBuilder.yield(AnalyzerInput(buffer: buffer)) }
                }
                for buffer in try conversion.finish() { inputBuilder.yield(AnalyzerInput(buffer: buffer)) }
                inputBuilder.finish()
            } catch {
                failure = error.localizedDescription; inputBuilder.finish(); throw error
            }
        }
        feed.connectModern { buffer in builder.yield(CapturedPCM(buffer: buffer)) }
    }
    func stop(feed: SpeechFeed) async -> Bool {
        feed.disconnectModern(); continuation?.finish(); continuation = nil
        guard let analyzer else { return false }
        do {
            try await pump?.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results?.value
            publish(); onText = nil
            return failure == nil
        } catch {
            failure = error.localizedDescription
            await analyzer.cancelAndFinishNow()
            results?.cancel(); publish(); onText = nil
            return false
        }
    }
    func cancel(feed: SpeechFeed) {
        feed.disconnectModern(); continuation?.finish(); continuation = nil
        pump?.cancel(); results?.cancel(); publish(); onText = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
    static func transcribe(url: URL, source: String, timeOffset: Double, progress: (String) -> Void, partial: @escaping ([TranscriptLine]) -> Void) async throws -> [TranscriptLine] {
        let session = TahoeSpeech()
        progress("Preparing Apple’s Tahoe transcription…")
        try await session.prepare(live: false)
        session.source = source; session.timeOffset = timeOffset; session.onText = partial
        guard let analyzer = session.analyzer else { throw AppFailure("Apple speech was not prepared.") }
        try session.collect()
        progress("Apple is transcribing the recording…")
        do {
            let file = try AVAudioFile(forReading: url)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: last)
            } else { await analyzer.cancelAndFinishNow() }
            try await session.results?.value
            return session.finalized
        } catch {
            await analyzer.cancelAndFinishNow(); session.results?.cancel(); throw error
        }
    }
}

// Only converts sample rate/channel layout. It does not split, filter, or edit speech.
final class SpeechPCMConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    init(target: AVAudioFormat) { self.target = target }
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == target { return input }
        if inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.primeMethod = .none
            inputFormat = input.format
        }
        guard let converter else { throw AppFailure("Could not convert microphone audio to Apple’s required format.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AppFailure("Could not allocate Apple speech input.") }
        var provided = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? AppFailure("Audio conversion failed.") }
        return output
    }
    func finish() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw AppFailure("Could not finish audio conversion.") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream; return nil
            }
            if status == .error { throw error ?? AppFailure("Could not finish audio conversion.") }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        return buffers
    }
}
