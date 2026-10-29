import Foundation

// Structural checks detect incomplete output, not factual correctness. No word
// clipping is used to make a model response pass a length setting.
enum NoteQuality {
    static func complete(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("{"), !value.hasPrefix("```"),
              value.components(separatedBy: "$$").count % 2 == 1,
              value.components(separatedBy: "**").count % 2 == 1,
              value.filter({ $0 == "{" }).count == value.filter({ $0 == "}" }).count else { return false }
        let lines = value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var previous = ""
        for line in lines {
            if line.hasPrefix("#"), !previous.isEmpty, unfinished(previous) { return false }
            previous = line
        }
        guard let last = lines.last, !unfinished(last) else { return false }
        return lines.contains { !$0.hasPrefix("#") && !$0.hasPrefix("$$") && $0.split(whereSeparator: \.isWhitespace).count >= 3 }
    }
    private static func unfinished(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasSuffix(":") || line.hasSuffix(",") || line == "-" || line.hasSuffix("=") || line.hasSuffix("→") { return true }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.dropFirst(2).dropLast(2).contains("**") == false { return true }
        return false
    }
    static func hasQualitativeEquation(_ text: String) -> Bool {
        // Verbal labels such as "trigger" or "feasibility" must stay prose,
        // rather than being dressed up as a fabricated quantitative equation.
        let parts = NoteMath.parts(text).filter(\.equation)
        return parts.contains { part in
            let value = part.text.lowercased()
            let qualitative = ["feasibility", "specificity", "recognition trigger", "receives the benefit", "unfulfilled promised"].contains { value.contains($0) }
            return qualitative && value.contains("=") && value.rangeOfCharacter(from: .decimalDigits) == nil
        }
    }
    static func cacheable(_ text: String, tag: String) -> Bool {
        if tag.hasPrefix("sanity-v8") || tag.hasPrefix("patch-v8") { return false }
        if tag.hasPrefix("plan-v8") {
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["topics"] is [[String: Any]]
        }
        return complete(text) && !hasQualitativeEquation(text)
    }
    static func acceptableEdit(_ candidate: String, original: String) -> Bool {
        guard complete(candidate), !hasQualitativeEquation(candidate) else { return false }
        // A compact edit may remove duplication, but never silently reduce a
        // substantial complete topic to a fragment or an almost empty outline.
        return StudyBudget.words(candidate) >= min(20, max(4, StudyBudget.words(original) / 2))
    }
}
struct LectureEvidence: Sendable, Identifiable {
    let id: Int
    let title: String
    let text: String
    let sourceIndex: Int
}
struct LectureTopic: Sendable {
    let title: String
    var ids: [Int]
}
enum EvidenceLedger {
    static func cards(_ text: String, sourceIndex: Int, start: Int) -> [LectureEvidence] {
        LiveNoteSection.split(text).enumerated().map { offset, section in
            LectureEvidence(id: start + offset, title: section.title, text: section.text, sourceIndex: sourceIndex)
        }
    }
    static func plan(_ response: String, evidence: [LectureEvidence]) -> [LectureTopic] {
        struct Envelope: Decodable { struct Topic: Decodable { let title: String; let ids: [Int] }; let topics: [Topic] }
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end { text = String(text[start...end]) }
        let decoded = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
        let valid = Set(evidence.map(\.id)); var used = Set<Int>(), result: [LectureTopic] = []
        for topic in decoded?.topics ?? [] {
            let ids = topic.ids.filter { valid.contains($0) && used.insert($0).inserted }
            let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ids.isEmpty { result.append(LectureTopic(title: title.isEmpty ? "Lecture concepts" : title, ids: ids)) }
        }
        // Missing or malformed planner output cannot remove evidence. Merge
        // exact topic names, and explicitly retain every unassigned card.
        for item in evidence where !used.contains(item.id) {
            if let index = result.firstIndex(where: { $0.title.caseInsensitiveCompare(item.title) == .orderedSame }) { result[index].ids.append(item.id) }
            else { result.append(LectureTopic(title: item.title, ids: [item.id])) }
            used.insert(item.id)
        }
        return result
    }
    static func batches(_ cards: [LectureEvidence], bytes: Int = 2400) -> [String] {
        var result: [String] = [], current = ""
        for card in cards {
            for piece in AppleTextBudget.chunks(card.text, bytes: bytes) {
                let next = current.isEmpty ? piece : current + "\n\n" + piece
                if next.utf8.count > bytes { if !current.isEmpty { result.append(current) }; current = piece }
                else { current = next }
            }
        }
        if !current.isEmpty { result.append(current) }; return result
    }
}

struct NoteReviewIssue: Sendable {
    let quote: String
    let reason: String
}
enum NoteSanityReview {
    static func issues(_ response: String, original: String) -> [NoteReviewIssue] {
        struct Report: Decodable { struct Issue: Decodable { let quote: String; let reason: String }; let issues: [Issue] }
        guard let data = response.data(using: .utf8), let report = try? JSONDecoder().decode(Report.self, from: data) else { return [] }
        var seen = Set<String>()
        return report.issues.compactMap { item in
            let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard quote.count >= 4, quote.utf8.count <= 600, !reason.isEmpty,
                  original.contains(quote), seen.insert(quote).inserted,
                  original.count < 80 || quote.count <= original.count * 3 / 4 else { return nil }
            return NoteReviewIssue(quote: quote, reason: String(reason.prefix(240)))
        }.prefix(2).map { $0 }
    }
    static func patched(_ response: String, issue: NoteReviewIssue, original: String) -> String? {
        struct Patch: Decodable { let replacement: String }
        guard let data = response.data(using: .utf8), let patch = try? JSONDecoder().decode(Patch.self, from: data),
              !patch.replacement.contains("\n## "), patch.replacement.utf8.count <= 1200,
              original.components(separatedBy: issue.quote).count == 2,
              let range = original.range(of: issue.quote) else { return nil }
        var value = original; value.replaceSubrange(range, with: patch.replacement)
        guard NoteQuality.acceptableEdit(value, original: original) else { return nil }
        return value
    }
}
