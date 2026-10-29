import Foundation

enum TranscriptMerge {
    private static func ordered(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        zip(lines, lines.dropFirst()).allSatisfy { $0.0.seconds <= $0.1.seconds } ? lines : lines.sorted { $0.seconds < $1.seconds }
    }
    static func replacing(_ existing: [TranscriptLine], file: String, with incoming: [TranscriptLine]) -> [TranscriptLine] {
        let remaining = existing.filter { $0.audioFile != file }
        let others = ordered(remaining)
        let incoming = ordered(incoming)
        var result: [TranscriptLine] = []; result.reserveCapacity(others.count + incoming.count)
        var a = 0, b = 0
        while a < others.count && b < incoming.count {
            if others[a].seconds <= incoming[b].seconds { result.append(others[a]); a += 1 }
            else { result.append(incoming[b]); b += 1 }
        }
        result.append(contentsOf: others.dropFirst(a)); result.append(contentsOf: incoming.dropFirst(b))
        return result
    }
}
@MainActor final class TranscriptUpdates {
    private var pending: [String: (UUID, [TranscriptLine])] = [:]
    private var scheduled: Task<Void, Never>?
    func submit(id: UUID, file: String, lines: [TranscriptLine], store: Store) {
        pending[file] = (id, lines)
        guard scheduled == nil else { return }
        scheduled = Task { [weak self, weak store] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, let store else { return }; self.flush(store: store)
        }
    }
    func flush(store: Store) {
        scheduled?.cancel(); scheduled = nil
        let updates = pending; pending.removeAll(keepingCapacity: true)
        for (file, value) in updates { store.updateTranscript(value.0, file: file, lines: value.1) }
    }
}
