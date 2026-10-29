import SwiftUI
import AppKit

@MainActor final class Store: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published var saveState = "Saved on this Mac"
    var job: Task<Void, Never>?
    @Published var busy = false
    @Published var progress = ""
    @Published var filter = "All meetings"
    @Published var query = ""
    let root: URL
    let audio: URL
    private var saveTask: Task<Void, Never>?
    private var loaded = false
    private var saveRevision = 0
    private lazy var persistence = ArchivePersistence(root: root)
    private var searchCache: [UUID: String] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes", isDirectory: true)
        audio = self.root.appendingPathComponent("Audio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            let file = self.root.appendingPathComponent("meetings.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1 else { throw AppFailure("This data was created by a newer version of Minutes.") }
                meetings = archive.meetings
                for i in meetings.indices where ["starting", "recording", "saving", "transcribing", "generating"].contains(meetings[i].pipelineStatus ?? "") {
                    meetings[i].pipelineStatus = "paused"
                    meetings[i].pipelineError = "This session was interrupted. Retry to finish from the saved recording or transcript."
                }
            }
            loaded = true
            selectedID = meetings.first(where: { !$0.trashed })?.id
        } catch {
            self.error = "Could not open your notes: \(error.localizedDescription). Your existing files have been left in place."
        }
    }
    var notebooks: [String] { Array(Set(meetings.filter { !$0.trashed }.map(\.notebook))).sorted() }
    var visible: [Meeting] {
        meetings.filter { m in
            (filter == "Trash" ? m.trashed : !m.trashed) &&
            (filter == "All meetings" || filter == "Trash" || (filter == "Favorites" ? m.favorite : m.notebook == filter)) &&
            (query.isEmpty || searchText(m).localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func searchText(_ meeting: Meeting) -> String {
        if let text = searchCache[meeting.id] { return text }
        let text = meeting.searchableText; searchCache[meeting.id] = text; return text
    }
    @discardableResult func create() -> UUID? {
        guard loaded else { error = "Resolve the data loading error before creating notes."; return nil }
        var m = Meeting(); m.notionSyncEnabled = false
        if !["All meetings", "Favorites", "Trash"].contains(filter) { m.notebook = filter }
        meetings.insert(m, at: 0); selectedID = m.id
        if filter == "Trash" || filter == "Favorites" { filter = "All meetings" }
        query = ""; persist(); return m.id
    }
    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard loaded, let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        let previous = meetings[i]
        var updated = previous; change(&updated)
        guard updated != previous else { return }
        if previous.notes != updated.notes || previous.summary != updated.summary || previous.title != updated.title || previous.transcript != updated.transcript || previous.actions != updated.actions || previous.eventStart != updated.eventStart || previous.eventEnd != updated.eventEnd { updated.notionNeedsSync = true }
        updated.updatedAt = Date(); meetings[i] = updated; searchCache[id] = nil; persist()
    }
    func updateTranscript(_ id: UUID, file: String, lines: [TranscriptLine]) {
        guard loaded, let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[i]
        let merged = TranscriptMerge.replacing(meeting.transcript, file: file, with: lines)
        guard meeting.transcript != merged else { return }
        meeting.transcript = merged; meeting.updatedAt = Date(); meeting.notionNeedsSync = true
        meetings[i] = meeting; searchCache[id] = nil; persist()
    }
    func persist() {
        guard loaded else { return }; saveRevision += 1
        if saveState != "Saving…" { saveState = "Saving…" }
        // Coalesce, rather than indefinitely debounce continuous live speech.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self else { return }; self.saveTask = nil
            let revision = self.saveRevision
            self.persistence.save(Archive(meetings: self.meetings)) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.saveRevision == revision else { return }
                    self.reportSave(error)
                }
            }
        }
    }
    private func reportSave(_ error: String?) {
        if let error { saveState = "Save failed"; self.error = "Could not save: " + error }
        else { saveState = "Saved on this Mac" }
    }
    func saveNow() {
        guard loaded else { return }
        saveTask?.cancel(); saveTask = nil; saveRevision += 1
        do { try persistence.flush(Archive(meetings: meetings)); reportSave(nil) }
        catch { reportSave(error.localizedDescription) }
    }
    func importText() {
        guard loaded else { error = "Resolve the data loading error before importing."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "json" {
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1 else { throw AppFailure("Unsupported backup version.") }
                // A portable backup contains text only; avoid broken or unsafe recording paths.
                for var m in archive.meetings { m.id = UUID(); m.audioFiles = []; meetings.append(m) }
            } else {
                guard let content = String(data: data, encoding: .utf8) else { throw AppFailure("Choose a UTF-8 text or Markdown file.") }
                var m = Meeting(); m.title = url.deletingPathExtension().lastPathComponent; m.notes = content
                meetings.insert(m, at: 0); selectedID = m.id
            }
            filter = "All meetings"; persist()
        } catch { self.error = error.localizedDescription }
    }
    func export(_ meeting: Meeting? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = meeting == nil ? "Minutes-backup.json" : "\(meeting!.title.replacingOccurrences(of: "/", with: "- ")).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let meeting { try meeting.markdown.write(to: url, atomically: true, encoding: .utf8) }
            else {
                var portable = meetings
                for i in portable.indices { portable[i].audioFiles = [] }
                let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
                try encoder.encode(Archive(meetings: portable)).write(to: url, options: .atomic)
            }
        } catch { self.error = error.localizedDescription }
    }
    func audioURL(_ file: String) -> URL? {
        guard !file.isEmpty, URL(fileURLWithPath: file).lastPathComponent == file, !file.contains("/"), !file.contains("\\") else { return nil }
        return audio.appendingPathComponent(file)
    }
    func deleteForever(_ id: UUID) {
        guard let m = meetings.first(where: { $0.id == id && $0.trashed }) else { return }
        for file in m.audioFiles { if let url = audioURL(file) { try? FileManager.default.removeItem(at: url) } }
        meetings.removeAll { $0.id == id }; searchCache[id] = nil; if selectedID == id { selectedID = nil }; persist()
    }
}
