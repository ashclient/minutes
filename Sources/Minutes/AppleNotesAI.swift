import Foundation
import FoundationModels

enum NotesAIProvider: String {
    case openRouter = "openrouter"
    case apple = "apple"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: "notesAIProvider") ?? "openrouter") ?? .openRouter }
}
struct AppleAIAvailability: Equatable {
    let available: Bool
    let message: String
    static func evaluate(major: Int, eligible: Bool, enabled: Bool, ready: Bool) -> Self {
        guard major >= 27 else { return Self(available: false, message: "Requires macOS 27 or newer. Your recording and transcription still work.") }
        guard eligible else { return Self(available: false, message: "This Mac does not support Apple Intelligence.") }
        guard enabled else { return Self(available: false, message: "Turn on Apple Intelligence in System Settings, then check again.") }
        guard ready else { return Self(available: false, message: "Apple’s model is not ready yet. Let its download finish, then check again.") }
        return Self(available: true, message: "Ready. Summaries run on this Mac without an API key.")
    }
    @MainActor static var current: Self {
        guard #available(macOS 27.0, *) else { return evaluate(major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, eligible: false, enabled: false, ready: false) }
        switch SystemLanguageModel.default.availability {
        case .available: return evaluate(major: 27, eligible: true, enabled: true, ready: true)
        case .unavailable(.deviceNotEligible): return evaluate(major: 27, eligible: false, enabled: false, ready: false)
        case .unavailable(.appleIntelligenceNotEnabled): return evaluate(major: 27, eligible: true, enabled: false, ready: false)
        case .unavailable(.modelNotReady): return evaluate(major: 27, eligible: true, enabled: true, ready: false)
        case .unavailable: return Self(available: false, message: "Apple Intelligence is unavailable for this Mac, language, or region.")
        @unknown default: return Self(available: false, message: "Apple Intelligence is unavailable right now.")
        }
    }
}
enum AppleTextBudget {
    // Conservatively bound UTF-8 input instead of assuming English tokenization.
    static func chunks(_ text: String, bytes limit: Int = 2200) -> [String] {
        guard limit >= 4, !text.isEmpty else { return [] }
        var result: [String] = []; var current = ""; var size = 0
        for scalar in text.unicodeScalars {
            let count = String(scalar).utf8.count
            if size + count > limit {
                if let boundary = current.lastIndex(where: { $0.isWhitespace }), current.distance(from: current.startIndex, to: boundary) > current.count / 2 {
                    let split = current.index(after: boundary)
                    result.append(String(current[..<split])); current = String(current[split...]); size = current.utf8.count
                } else { result.append(current); current = ""; size = 0 }
            }
            current.unicodeScalars.append(scalar); size += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

@MainActor enum AppleNotesAI {
    private static var completedSections: [String: String] = [:]
    static func summarize(_ source: String, length: NotesLength = .complete, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void, partial: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SummaryResult {
        let availability = AppleAIAvailability.current
        guard availability.available else { throw AppFailure(availability.message) }
        guard #available(macOS 27.0, *) else { throw AppFailure("Apple Intelligence requires macOS 27 or newer.") }
        let parts = AppleTextBudget.chunks(source, bytes: 2400)
        guard !parts.isEmpty else { throw AppFailure("Add notes or a transcript first.") }
        let draft = LectureDraft(partial: partial)
        progress("Writing lecture notes…")
        let notes = try await OrderedBatch.map(Array(parts.enumerated()), concurrency: 2, progress: fraction) { item in
            try await generate(item.element, length: length) { text in draft.update(index: item.offset, text: text) }
        }
        return SummaryResult(summary: LectureNotes.organize(notes), decisions: [], actions: [])
    }
    @available(macOS 26.0, *)
    private static func generate(_ text: String, length: NotesLength, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        let key = "lecture-v3:" + length.rawValue + "\n" + text
        if let saved = completedSections[key] { partial(saved); return saved }
        // Plain-text streaming avoids schema parsing failures and their full retries.
        let attempt = await AsyncDeadline.run(seconds: 120) {
            let session = LanguageModelSession(instructions: LectureNotes.instruction + "\n" + length.instruction)
            var output = ""; var last = Date.distantPast
            for try await snapshot in session.streamResponse(to: "<source>\n" + text + "\n</source>", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 1600)) {
                try Task.checkCancellation()
                output = snapshot.content
                if Date().timeIntervalSince(last) > 0.25 { partial(output); last = Date() }
            }
            try Task.checkCancellation(); partial(output)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try Task.checkCancellation()
        guard let attempt else { throw AppFailure("Apple Intelligence timed out. Your live draft is available; retry or keep partial notes.") }
        let output = try attempt.get()
        guard !output.isEmpty else { throw AppFailure("Apple returned an empty section. Your draft and transcript are kept.") }
        if completedSections.count >= 256 { completedSections.removeValue(forKey: completedSections.keys.first!) }
        completedSections[key] = output
        return output
    }
}
@MainActor private final class LectureDraft {
    var sections: [Int: String] = [:]
    let partial: @MainActor (String) -> Void
    init(partial: @escaping @MainActor (String) -> Void) { self.partial = partial }
    func update(index: Int, text: String) {
        sections[index] = text
        partial(LectureNotes.organize(sections.keys.sorted().compactMap { sections[$0] }))
    }
}

// A malformed generated schema must not abort a long lecture without trying
// a fresh plain-text session. Cancellation always exits without another request.
@MainActor enum AppleNotesRecovery {
    static func run(primary: () async throws -> SummaryResult, fallback: () async throws -> SummaryResult) async throws -> SummaryResult {
        do { return try await primary() }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            return try await fallback()
        }
    }
}
