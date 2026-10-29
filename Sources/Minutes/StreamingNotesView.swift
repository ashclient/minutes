import SwiftUI

// The target is always actual generated text. Smooth only its presentation;
// never delay saving, cancellation or the finished result.
struct DraftReveal {
    private(set) var visible = ""
    private var pending: Substring = ""
    private var target = ""
    mutating func update(_ value: String, immediate: Bool = false) {
        if immediate { target = value; visible = value; pending = ""; return }
        guard value != target else { return }
        target = value
        if value.hasPrefix(visible) { pending = value.dropFirst(visible.count) }
        else {
            // Topic consolidation can revise earlier text; replace that revision
            // once, without replaying the entire document letter by letter.
            visible = value; pending = ""
        }
    }
    mutating func tick() {
        guard !pending.isEmpty else { return }
        let count = min(pending.count, max(1, (pending.count + 11) / 12))
        let end = pending.index(pending.startIndex, offsetBy: count)
        visible.append(contentsOf: pending[..<end]); pending = pending[end...]
    }
}
struct StreamingNotesView: View {
    let text: String
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = DraftReveal()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteDocument(text: reveal.visible).equatable()
            if running { RoundedRectangle(cornerRadius: 1).fill(Color.secondary).frame(width: 2, height: 13).accessibilityHidden(true) }
        }
        .onAppear { reveal.update(text, immediate: reduceMotion || !running) }
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
}
