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
            (query.isEmpty || m.searchableText.localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    @discardableResult func create() -> UUID? {
        guard loaded else { error = "Resolve the data loading error before creating notes."; return nil }
        var m = Meeting()
        if !["All meetings", "Favorites", "Trash"].contains(filter) { m.notebook = filter }
        meetings.insert(m, at: 0); selectedID = m.id
        if filter == "Trash" || filter == "Favorites" { filter = "All meetings" }
        query = ""; persist(); return m.id
    }
    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard loaded, let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        let previous = meetings[i]
        change(&meetings[i])
        if previous.notes != meetings[i].notes || previous.summary != meetings[i].summary || previous.title != meetings[i].title || previous.transcript != meetings[i].transcript || previous.actions != meetings[i].actions || previous.eventStart != meetings[i].eventStart || previous.eventEnd != meetings[i].eventEnd { meetings[i].notionNeedsSync = true }
        meetings[i].updatedAt = Date(); persist()
    }
    func persist() {
        guard loaded else { return }
        saveState = "Saving…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        guard loaded else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Archive(meetings: meetings))
            let target = root.appendingPathComponent("meetings.json")
            if FileManager.default.fileExists(atPath: target.path) {
                let previous = try Data(contentsOf: target)
                try previous.write(to: root.appendingPathComponent("meetings.previous.json"), options: .atomic)
            }
            try data.write(to: target, options: .atomic)
            saveState = "Saved on this Mac"
        } catch { saveState = "Save failed"; self.error = "Could not save: \(error.localizedDescription)" }
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
        meetings.removeAll { $0.id == id }; if selectedID == id { selectedID = nil }; persist()
    }
}
