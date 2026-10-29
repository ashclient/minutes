import SwiftUI

// Grapheme-aware edits retain the untouched suffix while animating only the
// changed range. Deletions remain briefly visible beside their actual location.
struct DraftReveal {
    private(set) var visible = ""
    private(set) var removedPreview = ""
    private(set) var editingPart: Int?
    private var characters: [Character] = []
    private var insert: [Character] = []
    private var start = 0, remainingRemoval = 0, inserted = 0, hold = 0
    private var target = ""
    mutating func update(_ value: String, immediate: Bool = false) {
        if immediate {
            target = value; visible = value; characters = Array(value); insert = []; remainingRemoval = 0
            removedPreview = ""; editingPart = nil; return
        }
        guard value != target else { return }
        target = value
        let wasDeleting = remainingRemoval > 0 || !removedPreview.isEmpty
        let next = Array(value), old = characters
        var prefix = 0
        while prefix < min(old.count, next.count), old[prefix] == next[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, next.count) - prefix, old[old.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
        start = prefix; remainingRemoval = old.count - prefix - suffix; inserted = 0
        insert = Array(next[prefix..<(next.count - suffix)])
        removedPreview = remainingRemoval > 0 ? String(old[prefix..<(old.count - suffix)].prefix(180)) : ""
        hold = remainingRemoval > 0 && !wasDeleting ? 2 : 0
        editingPart = max(0, NoteMath.parts(String(old.prefix(prefix))).count - 1)
    }
    mutating func tick() {
        if hold > 0 { hold -= 1; return }
        if remainingRemoval > 0 {
            let count = max(1, (remainingRemoval + 5) / 6)
            characters.removeSubrange((start + remainingRemoval - count)..<(start + remainingRemoval)); remainingRemoval -= count
        } else if inserted < insert.count {
            let count = min(insert.count - inserted, max(1, (insert.count - inserted + 7) / 8))
            characters.insert(contentsOf: insert[inserted..<(inserted + count)], at: start + inserted); inserted += count
        } else { removedPreview = ""; editingPart = nil; return }
        visible = String(characters)
    }
}
struct StreamingNotesView: View {
    let text: String
    let running: Bool
    var initiallyVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = DraftReveal()
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            let parts = NoteMath.parts(reveal.visible)
            ForEach(parts) { part in
                VStack(alignment: .leading, spacing: 3) {
                    if reveal.editingPart == part.id && !reveal.removedPreview.isEmpty { deletion }
                    NoteDocument(text: part.equation ? "$$\n" + part.text + "\n$$" : part.text).equatable()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(reveal.editingPart == part.id ? Color.accentColor.opacity(0.04) : Color.clear)
            }
            if (parts.isEmpty || (reveal.editingPart ?? 0) >= parts.count) && !reveal.removedPreview.isEmpty { deletion }
        }
        .onAppear { reveal.update(text, immediate: initiallyVisible || reduceMotion || !running) }
        .onChange(of: text) { _, value in reveal.update(value, immediate: reduceMotion || !running) }
        .onChange(of: running) { _, active in if !active { reveal.update(text, immediate: true) } }
        .task(id: "\(running)-\(reduceMotion)") {
            if reduceMotion || !running { reveal.update(text, immediate: true); return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 33_000_000) } catch { return }
                reveal.tick()
            }
        }
    }
    private var deletion: some View {
        Text(reveal.removedPreview).strikethrough().font(.system(size: 12)).foregroundStyle(.red.opacity(0.8))
            .lineLimit(3).padding(4).background(Color.red.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Removing: " + reveal.removedPreview)
    }
}
struct NoteWorkersView: View {
    let workers: [NoteWorker]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(workers) { worker in
                HStack(spacing: 6) {
                    Circle().fill(Self.color(worker.id)).frame(width: 6, height: 6)
                    Text("Agent \(worker.id)").fontWeight(.medium)
                    Text(worker.task).foregroundStyle(.secondary).lineLimit(1)
                }.font(.caption)
            }
        }.accessibilityElement(children: .combine)
    }
    static func color(_ id: Int) -> Color { [Color.blue, .purple, .teal, .orange][max(0, id - 1) % 4] }
}
struct CollaborativeNotesView: View {
    let sections: [LiveNoteSection]
    let running: Bool
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if let worker = section.worker {
                        Label("Agent \(worker) · working on this topic", systemImage: "pencil.tip")
                            .font(.caption).foregroundStyle(NoteWorkersView.color(worker))
                    }
                    StreamingNotesView(text: section.text, running: running, initiallyVisible: true)
                }.padding(.leading, 10)
                .overlay(alignment: .leading) {
                    if let worker = section.worker { RoundedRectangle(cornerRadius: 1).fill(NoteWorkersView.color(worker).opacity(0.6)).frame(width: 2) }
                }
            }
        }
    }
}
