import Foundation

struct NoteWorker: Identifiable, Equatable, Sendable {
    let id: Int
    var task: String
}
struct LiveNoteSection: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    var text: String
    var worker: Int?
    init(id: UUID = UUID(), title: String, text: String, worker: Int? = nil) {
        self.id = id; self.title = title; self.text = text; self.worker = worker
    }
    static func split(_ markdown: String) -> [Self] {
        var result: [Self] = [], lines: [String] = [], title = "Notes", math = false
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(Self(title: title, text: text)) }; lines = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "$$" { math.toggle() }
            if !math && (line.hasPrefix("## ") || line.hasPrefix("# ")) {
                flush(); title = String(line.drop(while: { $0 == "#" || $0 == " " }))
            }
            lines.append(line)
        }
        flush(); return result
    }
    static func normalized(_ value: String, title: String) -> String {
        var lines = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("#") == true { lines.removeFirst() }
        return "## " + title + "\n" + lines.map { $0.hasPrefix("## ") ? "#" + $0 : $0 }.joined(separator: "\n")
    }
}
// Deterministic bounded scheduling: one independent model session per job. A
// worker owns one section at a time, so concurrent edits cannot overwrite peers.
@MainActor enum NoteWorkerPool {
    static func map<Input: Sendable, Output: Sendable>(_ inputs: [Input], limit: Int,
        activity: @escaping @MainActor ([NoteWorker]) -> Void,
        completed: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
        label: @escaping @MainActor (Int) -> String,
        operation: @escaping @MainActor (Int, Int, Input) async throws -> Output) async throws -> [Output] {
        guard !inputs.isEmpty else { activity([]); return [] }
        let count = min(inputs.count, max(1, min(4, limit)))
        var jobs = count, finished = 0, active: [Int: String] = [:]
        var results = [Output?](repeating: nil, count: inputs.count)
        defer { activity([]) }
        return try await withThrowingTaskGroup(of: (Int, Int, Output).self) { group in
            func start(_ index: Int, worker: Int) {
                active[worker] = label(index)
                activity(active.keys.sorted().map { NoteWorker(id: $0, task: active[$0]!) })
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    return (index, worker, try await operation(worker, index, inputs[index]))
                }
            }
            for index in 0..<count { start(index, worker: index + 1) }
            while let (index, worker, output) = try await group.next() {
                try Task.checkCancellation(); results[index] = output; finished += 1
                active.removeValue(forKey: worker); completed(finished, inputs.count)
                if jobs < inputs.count { start(jobs, worker: worker); jobs += 1 }
                else { activity(active.keys.sorted().map { NoteWorker(id: $0, task: active[$0]!) }) }
            }
            return results.compactMap { $0 }
        }
    }
}
@MainActor final class CollaborativeDraft {
    private(set) var sections: [LiveNoteSection]
    let publish: @MainActor ([LiveNoteSection], String) -> Void
    init(text: String, publish: @escaping @MainActor ([LiveNoteSection], String) -> Void) {
        sections = LiveNoteSection.split(text); self.publish = publish
    }
    func update(index: Int, value: String? = nil, worker: Int?) {
        guard sections.indices.contains(index) else { return }
        if let value { sections[index].text = value }
        sections[index].worker = worker
        publish(sections, sections.map(\.text).joined(separator: "\n\n"))
    }
    var text: String { sections.map(\.text).joined(separator: "\n\n") }
}
enum NoteEvidence {
    static func excerpts(for topic: String, source: String, limit: Int = 2400) -> String {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.map(String.init))
        }
        let wanted = words(topic)
        // Use exact source excerpts, never invented material or model reasoning.
        let parts = AppleTextBudget.chunks(source, bytes: 1000)
        let ranked = parts.enumerated().sorted {
            let a = words($0.element).intersection(wanted).count
            let b = words($1.element).intersection(wanted).count
            return a == b ? $0.offset < $1.offset : a > b
        }
        var result = ""
        for entry in ranked {
            let next = result.isEmpty ? entry.element : result + "\n" + entry.element
            if next.utf8.count <= limit { result = next }
            if result.utf8.count >= limit - 1000 { break }
        }
        return result
    }
}
