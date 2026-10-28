import Foundation
import SwiftUI

struct NotionClient {
    let token: String
    var session: URLSession = .shared
    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        request.httpMethod = method; request.timeoutInterval = 45
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AppFailure("Notion: " + (object["message"] as? String ?? "Could not connect. Check your key and page access."))
        }
        return object
    }
    static func identifier(_ input: String) throws -> String {
        // A Notion URL may contain a different UUID in its query (the view ID).
        let value = URL(string: input).flatMap { $0.scheme == nil ? nil : $0.path } ?? input
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).last, let range = Range(match.range, in: value) else { throw AppFailure("Paste a Notion page or database link.") }
        let plain = String(value[range]).replacingOccurrences(of: "-", with: "")
        guard let id = UUID(uuidString: String(plain.prefix(8)) + "-" + String(plain.dropFirst(8).prefix(4)) + "-" + String(plain.dropFirst(12).prefix(4)) + "-" + String(plain.dropFirst(16).prefix(4)) + "-" + String(plain.suffix(12))) else { throw AppFailure("That Notion ID is invalid.") }
        return id.uuidString.lowercased()
    }
    static func rich(_ text: String) -> [[String: Any]] {
        // Bound UTF-16 units as well as Swift graphemes for Notion's string limit.
        var parts: [String] = []; var current = ""; var units = 0
        for scalar in text.unicodeScalars {
            let size = scalar.value > 0xffff ? 2 : 1
            if units + size > 1800 { parts.append(current); current = ""; units = 0 }
            current.unicodeScalars.append(scalar); units += size
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { ["type": "text", "text": ["content": $0]] }
    }
    static func block(_ text: String, type: String = "paragraph") -> [String: Any] { ["object": "block", "type": type, type: ["rich_text": rich(text)]] }
    static func content(_ meeting: Meeting, transcript: Bool) -> [[String: Any]] {
        var text = ""
        if let start = meeting.eventStart { text += start.formatted(date: .complete, time: .shortened) + "\n\n" }
        if !meeting.notes.isEmpty { text += "## My notes\n" + meeting.notes + "\n\n" }
        if !meeting.summary.isEmpty { text += "## Meeting notes\n" + meeting.finishedNotes }
        if transcript && !meeting.transcript.isEmpty { text += "\n\n## Transcript\n" + meeting.transcriptText }
        if text.isEmpty { text = "Ready for this meeting. Notes will appear here after recording." }
        var blocks = text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { line -> [String: Any] in
            if line.hasPrefix("#") { return block(String(line.drop(while: { $0 == "#" || $0 == " " })), type: "heading_2") }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return block(String(line.dropFirst(2)), type: "bulleted_list_item") }
            return block(line)
        }
        if blocks.count > 95 { blocks = AIClient.chunks(text, limit: 12000).map { block($0) } }
        return blocks
    }
    func createDatabase(parent: String) async throws -> (source: String, url: String) {
        let result = try await call("databases", method: "POST", body: ["parent": ["type": "page_id", "page_id": parent], "title": Self.rich("Minutes"), "initial_data_source": ["properties": ["Name": ["title": [:]], "Date": ["date": [:]]]]])
        guard let sources = result["data_sources"] as? [[String: Any]], let id = sources.first?["id"] as? String else { throw AppFailure("Notion created the database but did not return its data source. Paste the database link to connect it.") }
        return (id, result["url"] as? String ?? "")
    }
    func resolveDatabase(_ id: String) async throws -> (source: String, title: String, date: String, url: String) {
        let result = try await call("databases/" + id)
        guard let sources = result["data_sources"] as? [[String: Any]], let source = sources.first?["id"] as? String else { throw AppFailure("Choose a Notion database with a Name and Date property.") }
        let schema = try await call("data_sources/" + source)
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        guard let title = properties.first(where: { $0.value["type"] as? String == "title" })?.key,
              let date = properties.sorted(by: { $0.key < $1.key }).first(where: { $0.value["type"] as? String == "date" })?.key else { throw AppFailure("Add a Date property to this database, then connect again.") }
        return (source, title, date, result["url"] as? String ?? "")
    }
    static func properties(_ meeting: Meeting, title: String, date: String) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var time = ["start": formatter.string(from: meeting.eventStart ?? meeting.createdAt)]
        if let end = meeting.eventEnd { time["end"] = formatter.string(from: end) }
        return [title: ["title": rich(String(meeting.title.prefix(200)))], date: ["date": time]]
    }
}

@MainActor final class NotionSync: ObservableObject {
    static let shared = NotionSync()
    @Published private(set) var syncing: Set<UUID> = []
    private var queued: Set<UUID> = []
    func sync(id: UUID, store: Store) async {
        guard UserDefaults.standard.bool(forKey: "notionEnabled") else { return }
        if syncing.contains(id) { queued.insert(id); return }
        syncing.insert(id)
        defer {
            syncing.remove(id)
            if queued.remove(id) != nil { Task { await self.sync(id: id, store: store) } }
        }
        do {
            guard var meeting = store.meetings.first(where: { $0.id == id && !$0.trashed }) else { return }
            let client = NotionClient(token: try CloudKey.read(service: "notion"))
            let defaults = UserDefaults.standard
            guard let source = defaults.string(forKey: "notionSource"), !source.isEmpty else { throw AppFailure("Connect a Notion destination in Connections.") }
            let properties = NotionClient.properties(meeting, title: defaults.string(forKey: "notionTitleProperty") ?? "Name", date: defaults.string(forKey: "notionDateProperty") ?? "Date")
            if meeting.notionPageID == nil {
                let response = try await client.call("pages", method: "POST", body: ["parent": ["type": "data_source_id", "data_source_id": source], "properties": properties])
                guard let page = response["id"] as? String else { throw AppFailure("Notion did not return a page ID.") }
                meeting.notionPageID = page
                store.update(id) { $0.notionPageID = page; $0.notionURL = response["url"] as? String }
                store.saveNow() // Retain the page ID even if content upload is interrupted.
            } else {
                _ = try await client.call("pages/" + meeting.notionPageID!, method: "PATCH", body: ["properties": properties])
            }
            let children = NotionClient.content(meeting, transcript: defaults.bool(forKey: "notionIncludeTranscript"))
            let section: [String: Any] = ["object": "block", "type": "toggle", "toggle": ["rich_text": NotionClient.rich("Minutes notes"), "children": children]]
            let body: [String: Any] = ["children": [section]]
            guard children.count <= 100, try JSONSerialization.data(withJSONObject: body).count < 480000 else { throw AppFailure("This note is too large for a single Notion sync. Turn off Include transcript, or export it as Markdown.") }
            let appended = try await client.call("blocks/" + meeting.notionPageID! + "/children", method: "PATCH", body: body)
            guard let result = (appended["results"] as? [[String: Any]])?.first, let block = result["id"] as? String else { throw AppFailure("Notion did not confirm the notes section.") }
            let old = meeting.notionBlockID
            store.update(id) { $0.notionBlockID = block; $0.notionSyncedAt = Date(); $0.notionError = nil }; store.saveNow()
            if let old { _ = try await client.call("blocks/" + old, method: "PATCH", body: ["archived": true]) }
        } catch { store.update(id) { $0.notionError = error.localizedDescription } }
    }
}
