import Foundation

struct ActionItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done = false
}
struct TranscriptLine: Identifiable, Codable, Equatable {
    var id = UUID()
    var seconds: Double
    var source: String
    var audioFile: String? = nil
    var text: String
    var timestamp: String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
struct Meeting: Identifiable, Codable, Equatable {
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
    var favorite = false
    var trashed = false
    var transcriptText: String { transcript.map { "[\($0.timestamp)] \($0.source): \($0.text)" }.joined(separator: "\n") }
    var searchableText: String { [title, notebook, notes, summary, transcriptText, actions.map(\.text).joined(separator: " ")].joined(separator: " ") }
    var markdown: String {
        "# \(title)\n\n\(createdAt.formatted()) · \(notebook)\n\n## Notes\n\n\(notes)\n\n## Summary\n\n\(summary)\n\n## Action items\n\n" + actions.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n\n## Transcript\n\n\(transcriptText)\n"
    }
}
struct Archive: Codable {
    var version = 1
    var meetings: [Meeting]
}
struct SummaryResult: Codable {
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
