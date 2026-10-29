import Foundation
import FoundationModels

enum NotesAIProvider: String {
    case openRouter = "openrouter"
    case apple = "apple"
    case nvidia
    var cloud: CloudAIProvider? { self == .apple ? nil : self == .nvidia ? .nvidia : .openRouter }
    @MainActor var configured: Bool { cloud.map { UserDefaults.standard.bool(forKey: $0.enabledKey) } ?? AppleAIAvailability.current.available }
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

@MainActor protocol AppleNoteInference {
    func generate(_ text: String, instruction: String, tokens: Int, key: String, partial: @escaping @MainActor (String) -> Void) async throws -> String
}
@available(macOS 26.0, *)
@MainActor private struct SystemNoteInference: AppleNoteInference {
    func generate(_ text: String, instruction: String, tokens: Int, key: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await AppleNotesAI.generate(text, instruction: instruction, tokens: tokens, key: key, partial: partial)
    }
}
@MainActor enum AppleNotesAI {
    private static var completedSections: [String: String] = [:]
    static func summarize(_ source: String, length: NotesLength = .complete, format: StudyFormat = .outline, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void, partial: @escaping @MainActor (String) -> Void = { _ in }, activity: @escaping @MainActor ([NoteWorker]) -> Void = { _ in }, sections: @escaping @MainActor ([LiveNoteSection]) -> Void = { _ in }) async throws -> SummaryResult {
        let availability = AppleAIAvailability.current
        guard availability.available else { throw AppFailure(availability.message) }
        guard #available(macOS 27.0, *) else { throw AppFailure("Apple Intelligence requires macOS 27 or newer.") }
        let configured = UserDefaults.standard.object(forKey: "appleNoteWorkers") == nil ? 2 : UserDefaults.standard.integer(forKey: "appleNoteWorkers")
        let workers = max(1, min(4, configured))
        let editing = UserDefaults.standard.object(forKey: "appleCollaborativeEditing") == nil || UserDefaults.standard.bool(forKey: "appleCollaborativeEditing")
        return try await compose(source, length: length, format: format, workers: workers, editing: editing, infer: SystemNoteInference(), fraction: fraction, progress: progress, partial: partial, activity: activity, sections: sections)
    }
    static func compose(_ source: String, length: NotesLength, format: StudyFormat, workers: Int, editing: Bool, infer: any AppleNoteInference, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void = { _ in }, partial: @escaping @MainActor (String) -> Void = { _ in }, activity: @escaping @MainActor ([NoteWorker]) -> Void = { _ in }, sections: @escaping @MainActor ([LiveNoteSection]) -> Void = { _ in }) async throws -> SummaryResult {
        let parts = AppleTextBudget.chunks(source, bytes: 2400)
        guard !parts.isEmpty else { throw AppFailure("Add notes or a transcript first.") }
        fraction(0); progress("Reading the lecture for its main concepts…")
        // Evidence is internal, not a growing set of per-chunk finished notes.
        // The document is written once from the whole-lecture synthesis below.
        let evidenceParts = try await NoteWorkerPool.map(parts, limit: workers, activity: activity,
            completed: { done, total in fraction(Double(done) / Double(total) * 0.5); progress("Reading source · \(done) of \(total) passages checked") },
            label: { "Reading passage \($0 + 1)" }) { _, _, text in
            try await infer.generate(text, instruction: "Collect compact factual evidence, not finished notes. Keep the main concept with its meaning, necessary conditions, formulas and quantity roles. Merge repeated explanations. Retain at most one complete example when essential to understand the concept. No headings per utterance, transcript retelling, outside facts or invented assignments. " + (length == .brief ? "Select only the highest-priority concepts in at most 45 words." : length == .complete ? "Keep distinct meaningful concepts in at most 160 words." : "Prefer about 80 words of essential evidence; omit secondary detail."), tokens: length == .brief ? 130 : length == .complete ? 350 : 220, key: "evidence-v7-" + length.rawValue, partial: { _ in })
        }
        var evidence = evidenceParts.joined(separator: "\n")
        progress("Combining related concepts across the lecture…")
        for round in 0..<8 {
            let groups = AppleTextBudget.chunks(evidence, bytes: 2400)
            if groups.count <= 1 { break }
            let reduced = try await NoteWorkerPool.map(groups, limit: workers, activity: activity,
                label: { "Merging related concepts · \($0 + 1)" }) { _, _, group in
                try await infer.generate(group, instruction: "Merge these factual extracts into a compact concept inventory. Combine synonyms and repetition; preserve the meaning, essential conditions, formulas and units. Keep one representative example only if necessary and complete. Remove secondary examples and minor detail. No textbook expansion, section recap, invented facts or isolated keyword lists. Use at most 90 words.", tokens: 200, key: "reduce-v7-" + length.rawValue, partial: { _ in })
            }
            let next = reduced.joined(separator: "\n")
            guard next.utf8.count < evidence.utf8.count else { throw AppFailure("Apple could not consolidate this lecture safely. Your previous notes are kept.") }
            evidence = next; fraction(0.5 + Double(round + 1) / 8 * 0.15)
        }
        guard evidence.utf8.count <= 2400 else { throw AppFailure("Apple could not fit the selected concepts into its context. Your transcript and previous notes are saved.") }
        fraction(0.65); progress("Writing one set of notes for the whole lecture…")
        activity([NoteWorker(id: 1, task: "Writing the whole-lecture draft")])
        let final = try await infer.generate(evidence, instruction: length.instruction + " " + format.instruction + " This source represents the ENTIRE lecture. Use a small set of distinct main topics, not one heading or note per source passage. Explain each concept once. Keep only useful, concise details. Merge repetition and synonymous topics. Do not expand brief source facts into textbook lessons or manufacture examples.", tokens: length == .brief ? 550 : length == .complete ? 1800 : 1300, key: "global-v7-" + length.rawValue + format.rawValue, partial: { partial(StudyBudget.limit($0, words: StudyBudget.maximum(length))) })
        let initial = StudyBudget.limit(final, words: StudyBudget.maximum(length))
        activity([]); fraction(editing ? 0.8 : 1)
        guard editing else { return SummaryResult(summary: initial, decisions: [], actions: []) }
        progress("Editors are refining the topics…")
        let document = CollaborativeDraft(text: initial) { values, text in sections(values); partial(text) }
        sections(document.sections)
        let originals = document.sections
        // Preserve a topic unchanged if its own text would crowd the model's
        // context; never silently truncate the original draft to make it fit.
        let editable = originals.indices.filter { originals[$0].text.utf8.count <= 2400 }
        _ = try await NoteWorkerPool.map(editable, limit: workers, activity: activity,
            completed: { done, total in fraction(0.8 + Double(done) / Double(total) * 0.2) },
            label: { "Editing “" + originals[editable[$0]].title + "”" }) { worker, _, index in
            let section = originals[index]
            document.update(index: index, worker: worker)
            let sourceText = NoteEvidence.excerpts(for: section.text, source: source, limit: 1800)
            let cap = length == .complete ? max(StudyBudget.words(section.text), StudyBudget.words(section.text) * 6 / 5) : StudyBudget.words(section.text)
            func clean(_ value: String) -> String {
                StudyBudget.limit(LiveNoteSection.normalized(value, title: section.title), words: cap)
            }
            let edited = try await infer.generate("TOPIC DRAFT:\n" + section.text + "\nRELEVANT ORIGINAL SOURCE EXCERPTS:\n" + sourceText,
                instruction: "Edit only this topic as a college study note. Keep the heading. Remove repetition, filler and excessive examples. Combine overlapping points. Clarify an essential definition or condition only when supported by the source. These excerpts may be incomplete; do not delete a meaningful draft fact merely because it is absent here. Do not add outside facts, new numbers or another topic. Return the revised section only. " + length.instruction + " Keep it concise and within the draft’s existing scope.",
                tokens: length == .brief ? 350 : 900, key: "editor-v7-" + length.rawValue,
                partial: { value in
                    let text = clean(value)
                    if !text.isEmpty { document.update(index: index, value: text, worker: worker) }
                })
            let result = clean(edited)
            document.update(index: index, value: result.isEmpty ? section.text : result, worker: nil)
            return result
        }
        try Task.checkCancellation(); fraction(1)
        return SummaryResult(summary: StudyBudget.limit(document.text, words: StudyBudget.maximum(length)), decisions: [], actions: [])
    }
    @available(macOS 26.0, *)
    fileprivate static func generate(_ text: String, instruction: String, tokens: Int, key cacheTag: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        let key = "lecture-v7:" + cacheTag + instruction + "\n" + text
        if let saved = completedSections[key] { partial(saved); return saved }
        // Plain-text streaming avoids schema parsing failures and their full retries.
        let attempt = await AsyncDeadline.run(seconds: 120) {
            let session = LanguageModelSession(instructions: LectureNotes.instruction + "\n" + instruction)
            var output = ""; var last = Date.distantPast
            for try await snapshot in session.streamResponse(to: "<source>\n" + text + "\n</source>", options: GenerationOptions(sampling: .greedy, maximumResponseTokens: tokens)) {
                try Task.checkCancellation()
                output = snapshot.content
                if Date().timeIntervalSince(last) > 0.12 { partial(output); last = Date() }
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
