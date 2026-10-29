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
    static func summarize(_ source: String, length: NotesLength = .complete, format: StudyFormat = .outline, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void, partial: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SummaryResult {
        let availability = AppleAIAvailability.current
        guard availability.available else { throw AppFailure(availability.message) }
        guard #available(macOS 27.0, *) else { throw AppFailure("Apple Intelligence requires macOS 27 or newer.") }
        let parts = AppleTextBudget.chunks(source, bytes: 2400)
        guard !parts.isEmpty else { throw AppFailure("Add notes or a transcript first.") }
        progress("Reading and selecting key concepts…")
        var notes: [String] = []
        for (index, text) in parts.enumerated() {
            try Task.checkCancellation()
            let purpose = length == .auto ? "Review this source and extract the distinct concepts, essential reasoning and supported examples needed for study. Merge repetition. No length target. Preserve quantity labels exactly. Do not invent missing definitions, examples or assignments." : "Extract only source-supported concepts in at most \(StudyBudget.evidenceWords(length)) words. Do not create coursework, numeric examples or definitions absent from this source. Omit unclear or incomplete examples rather than filling gaps."
            let output = try await generate(text, instruction: purpose + " " + format.instruction, tokens: length == .auto ? 1000 : length == .brief ? 130 : length == .detailed ? 250 : 550, key: length.rawValue + format.rawValue, partial: { value in
                if length == .complete { partial(LectureNotes.organize(notes + [value])) }
            })
            notes.append(output)
            fraction(Double(index + 1) / Double(parts.count) * (length == .complete ? 1 : 0.65))
        }
        if length == .complete { return SummaryResult(summary: LectureNotes.organize(notes), decisions: [], actions: []) }
        if length == .auto {
            progress("Reviewing topics and choosing useful detail…")
            let evidence = LectureNotes.organize(notes)
            let groups = AppleTextBudget.chunks(evidence, bytes: 2400)
            var reviewed: [String] = []
            for (index, group) in groups.enumerated() {
                let output = try await generate(group, instruction: length.instruction + " " + format.instruction + " These are reviewed source extracts from the whole lecture. Consolidate the topics here. Keep only supported content; correct no facts from outside knowledge. Close every formula delimiter before starting prose.", tokens: 1600, key: "auto-review-" + format.rawValue, partial: { value in partial(LectureNotes.organize(reviewed + [value])) })
                reviewed.append(output)
                fraction(0.65 + 0.35 * Double(index + 1) / Double(groups.count))
            }
            return SummaryResult(summary: LectureNotes.organize(reviewed), decisions: [], actions: [])
        }
        // The final request represents the entire lecture, not one source chunk.
        // Reduce evidence recursively within Apple's small session context.
        var evidence = notes.joined(separator: "\n")
        progress("Combining topics for the whole lecture…")
        for _ in 0..<8 {
            let groups = AppleTextBudget.chunks(evidence, bytes: 2400)
            if groups.count <= 1 { break }
            var condensed: [String] = []
            for group in groups {
                condensed.append(try await generate(group, instruction: "Consolidate these source extracts into at most 60 words of key concepts. Merge repeats. Retain the essential rules. Do not add examples, facts or assignments.", tokens: 150, key: "reduce", partial: { _ in }))
            }
            let next = condensed.joined(separator: "\n")
            guard next.utf8.count < evidence.utf8.count else { throw AppFailure("Apple could not condense this lecture safely. Retry; your previous notes are kept.") }
            evidence = next
        }
        guard evidence.utf8.count <= 2400 else { throw AppFailure("Apple could not fit the selected concepts into its context. Your transcript and previous notes are saved.") }
        fraction(0.85); progress("Writing your study notes…")
        let final = try await generate(evidence, instruction: length.instruction + " " + format.instruction + " This source represents the ENTIRE lecture. Combine topics; no section-by-section recap. No invented coursework or examples.", tokens: length == .brief ? 550 : 1500, key: "final-" + length.rawValue + format.rawValue, partial: { partial(StudyBudget.limit($0, words: StudyBudget.maximum(length))) })
        fraction(1)
        return SummaryResult(summary: StudyBudget.limit(final, words: StudyBudget.maximum(length)), decisions: [], actions: [])
    }
    @available(macOS 26.0, *)
    private static func generate(_ text: String, instruction: String, tokens: Int, key cacheTag: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        let key = "lecture-v4:" + cacheTag + instruction + "\n" + text
        if let saved = completedSections[key] { partial(saved); return saved }
        // Plain-text streaming avoids schema parsing failures and their full retries.
        let attempt = await AsyncDeadline.run(seconds: 120) {
            let session = LanguageModelSession(instructions: LectureNotes.instruction + "\n" + instruction)
            var output = ""; var last = Date.distantPast
            for try await snapshot in session.streamResponse(to: "<source>\n" + text + "\n</source>", options: GenerationOptions(sampling: .greedy, maximumResponseTokens: tokens)) {
                try Task.checkCancellation()
                output = snapshot.content
                if Date().timeIntervalSince(last) > 0.7 { partial(output); last = Date() }
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
