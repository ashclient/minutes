import Foundation

struct ActionItem: Sendable, Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done = false
}
struct TranscriptLine: Sendable, Identifiable, Codable, Equatable {
    var id = UUID()
    var seconds: Double
    var source: String
    var audioFile: String? = nil
    var text: String
    var timestamp: String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
struct Meeting: Sendable, Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "Untitled meeting"
    var createdAt = Date()
    var updatedAt = Date()
    var notebook = "Meetings"
    var notes = ""
    var summary = ""
    var actions: [ActionItem] = []
    var transcript: [TranscriptLine] = []
    var audioFiles: [String] = []
    var transcribedFiles: [String]? = nil
    var pipelineStatus: String? = nil
    var pipelineError: String? = nil
    var audioDiagnostics: String? = nil
    var calendarEventKey: String? = nil
    var eventStart: Date? = nil
    var eventEnd: Date? = nil
    var eventCalendar: String? = nil
    var eventAllDay: Bool? = nil
    var notionPageID: String? = nil
    var notionURL: String? = nil
    var notionBlockID: String? = nil
    var notionBlockIDs: [String]? = nil
    var notesLength: NotesLength? = nil
    var notionSyncedAt: Date? = nil
    var notionError: String? = nil
    var notionParentKind: String? = nil
    var notionParentID: String? = nil
    var notionNeedsSync: Bool? = nil
    var notionSyncEnabled: Bool? = nil
    var notionDeliveryRevision: UUID? = nil
    var favorite = false
    var trashed = false
    var transcriptText: String { transcript.map { "[\($0.timestamp)] \($0.source): \($0.text)" }.joined(separator: "\n") }
    var searchableText: String { [title, notebook, notes, summary, transcriptText, actions.map(\.text).joined(separator: " ")].joined(separator: " ") }
    var markdown: String {
        "# \(title)\n\n\(createdAt.formatted()) · \(notebook)\n\n## Notes\n\n\(notes)\n\n## Summary\n\n\(summary)\n\n## Action items\n\n" + actions.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n\n## Transcript\n\n\(transcriptText)\n"
    }
}
struct Archive: Sendable, Codable {
    var version = 1
    var meetings: [Meeting]
}
enum RecordingTrack {
    static func source(_ file: String) -> String {
        if file.hasSuffix("-computer.m4a") || file.hasSuffix("-computer.caf") { return "Computer" }
        if file.hasSuffix("-mic.m4a") || file.hasSuffix("-mic.caf") { return "Microphone" }
        return "Recording"
    }
}
struct SummaryResult: Sendable, Codable {
    var title: String? = nil
    var summary: String
    var decisions: [String]
    var actions: [String]
}
struct AppFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum SummaryParser {
    static func parse(_ text: String) throws -> SummaryResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}"), first <= last else { throw AppFailure("The model did not return a summary. Try again; your transcript is saved.") }
        let result: SummaryResult
        do { result = try JSONDecoder().decode(SummaryResult.self, from: Data(cleaned[first...last].utf8)) }
        catch { throw AppFailure("The model returned notes in an unexpected format. Try again; your transcript is saved.") }
        guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("The model returned an empty summary.") }
        return result
    }
}

// Both the screen and export use the same final note text.
extension Meeting {
    var finishedNotes: String {
        var result = summary
        if !actions.isEmpty {
            result += "\n\n## Next steps\n" + actions.map { "- " + $0.text }.joined(separator: "\n")
        }
        return result
    }
    mutating func apply(_ result: SummaryResult, originalTitle: String) {
        summary = result.summary
        if !result.decisions.isEmpty { summary += "\n\n## Decisions\n" + result.decisions.map { "- " + $0 }.joined(separator: "\n") }
        var seen = Set<String>()
        let old = actions
        actions = result.actions.compactMap { value in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            return old.first(where: { $0.text.lowercased() == text.lowercased() }) ?? ActionItem(text: text)
        }
        if title == originalTitle, title == "Untitled meeting" || title.hasPrefix("Meeting ·") {
            if let suggested = result.title?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty { title = String(suggested.prefix(80)) }
        }
        pipelineStatus = "ready"; pipelineError = nil
    }
}

struct SpeechWindow {
    let start: Double
    let end: Double
    let ownedStart: Double
    let ownedEnd: Double
    func owns(_ token: SpeechToken) -> Bool {
        let midpoint = token.seconds + token.duration / 2
        return midpoint >= ownedStart && midpoint < ownedEnd
    }
    static func plan(duration: Double) -> [SpeechWindow] {
        guard duration.isFinite, duration > 0 else { return [] }
        return stride(from: 0.0, to: duration, by: 40).map {
            SpeechWindow(start: max(0, $0 - 5), end: min(duration, $0 + 45), ownedStart: $0, ownedEnd: min(duration, $0 + 40))
        }
    }
}
struct SpeechToken {
    var seconds: Double
    var duration: Double
    var text: String
}
enum SpeechParagraphs {
    static func lines(_ tokens: [SpeechToken], source: String, timeOffset: Double) -> [TranscriptLine] {
        var result: [TranscriptLine] = []; var words: [String] = []; var start = 0.0; var previousEnd = 0.0
        func flush() {
            if !words.isEmpty { result.append(TranscriptLine(seconds: timeOffset + start, source: source, text: words.joined(separator: " "))); words = [] }
        }
        for token in tokens.sorted(by: { $0.seconds < $1.seconds }) {
            if !words.isEmpty, token.seconds - previousEnd > 2.0 || words.count >= 60 { flush() }
            if words.isEmpty { start = token.seconds }
            words.append(token.text); previousEnd = token.seconds + token.duration
            if token.text.hasSuffix(".") || token.text.hasSuffix("?") || token.text.hasSuffix("!") { flush() }
        }
        flush(); return result
    }
}

// Recognition text is authoritative; provisional word timings must never delete it.
enum TranscriptText {
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    static func key(_ word: String) -> String { word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    static func stitch(_ first: String, _ second: String) -> String {
        let a = words(first), b = words(second)
        if a.isEmpty { return second }; if b.isEmpty { return first }
        let ak = a.map(key), bk = b.map(key)
        if ak == bk { return first }
        for n in stride(from: min(a.count, b.count, 100), through: 1, by: -1) {
            if Array(ak.suffix(n)) == Array(bk.prefix(n)), n > 1 || (bk[0].count > 7) {
                return (a + b.dropFirst(n)).joined(separator: " ")
            }
        }
        return first + " " + second
    }
}
struct LiveTextAccumulator {
    private(set) var committed = ""
    private(set) var current = ""
    var text: String { TranscriptText.stitch(committed, current) }
    mutating func update(_ next: String) {
        guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let a = TranscriptText.words(current).map(TranscriptText.key)
        let b = TranscriptText.words(next).map(TranscriptText.key)
        if a.isEmpty { current = next; return }
        if b.starts(with: a) { current = next; return }
        // A shorter provisional result must not erase a longer result.
        if a.starts(with: b) { return }
        let common = zip(a,b).prefix(while: { $0 == $1 }).count
        if common >= min(3, min(a.count, b.count)), b.count * 2 >= a.count { current = next; return }
        committed = TranscriptText.stitch(committed, current); current = next
    }
}
