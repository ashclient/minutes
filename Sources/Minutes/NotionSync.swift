import Foundation
import SwiftUI

private actor NotionThrottle {
    static let shared = NotionThrottle()
    private var next = Date.distantPast
    func wait() async throws {
        let now = Date(); let slot = max(now, next); next = slot.addingTimeInterval(0.36)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}
struct NotionHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "Notion: " + message }
}
struct NotionClient {
    let token: String
    var session: URLSession = .shared
    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        try await NotionThrottle.shared.wait()
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        request.httpMethod = method; request.timeoutInterval = 45
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NotionHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: object["message"] as? String ?? "Could not connect. Check your key and page access.")
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
        return NotionMarkdown.blocks(text)
    }
    static func pageParent(kind: String, id: String) -> [String: Any] {
        if kind == "workspace" { return ["workspace": true] }
        return kind == "page" ? ["type": "page_id", "page_id": id] : ["type": "data_source_id", "data_source_id": id]
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
        return [title: ["title": pageTitle(meeting)], date: ["date": time]]
    }
    static func dateMention(_ date: Date, allDay: Bool) -> String {
        guard allDay else { return ISO8601DateFormatter().string(from: date) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        return formatter.string(from: date)
    }
    static func pageTitle(_ meeting: Meeting) -> [[String: Any]] {
        var value = rich(String(meeting.title.prefix(200)))
        if let start = meeting.eventStart {
            value += rich(" ")
            value.append(["type": "mention", "mention": ["type": "date", "date": ["start": dateMention(start, allDay: meeting.eventAllDay == true)]]])
        }
        return value
    }
}

@MainActor final class NotionSync: ObservableObject {
    static let shared = NotionSync()
    @Published private(set) var syncing: Set<UUID> = []
    private var queued: Set<UUID> = []
    func sync(id: UUID, store: Store, client suppliedClient: NotionClient? = nil) async {
        guard UserDefaults.standard.bool(forKey: "notionEnabled") else { return }
        if syncing.contains(id) { queued.insert(id); return }
        syncing.insert(id)
        defer {
            syncing.remove(id)
            if queued.remove(id) != nil { Task { await self.sync(id: id, store: store, client: suppliedClient) } }
        }
        let deliveryRevision = store.meetings.first { $0.id == id }?.notionDeliveryRevision
        func currentDelivery() -> Bool {
            guard let current = store.meetings.first(where: { $0.id == id && !$0.trashed }) else { return false }
            return current.notionDeliveryRevision == deliveryRevision && current.notionSyncEnabled != false
        }
        do {
            guard var meeting = store.meetings.first(where: { $0.id == id && !$0.trashed }), currentDelivery() else { return }
            let client: NotionClient
            if let suppliedClient { client = suppliedClient } else { client = NotionClient(token: try CloudKey.read(service: "notion")) }
            // Check owned content before writing any page properties or replacements.
            // Unmanaged blocks on an existing page are never inspected or replaced.
            if let syncedAt = meeting.notionSyncedAt {
                let owned = Set((meeting.notionBlockIDs ?? []) + [meeting.notionBlockID].compactMap { $0 })
                for blockID in owned {
                    guard currentDelivery() else { return }
                    do {
                        if try await editedInNotion(blockID, since: syncedAt, client: client) {
                            throw AppFailure("Notion edits detected. Your Notion changes were kept. Choose Preserve edits & add copy to append the latest local notes.")
                        }
                    } catch let error as NotionHTTPError where error.status == 404 { continue }
                }
            }
            guard currentDelivery() else { return }
            let defaults = UserDefaults.standard
            let kind = meeting.notionParentKind ?? (meeting.notionPageID == nil ? defaults.string(forKey: "notionDestinationKind") ?? "page" : "database")
            let pageParent = kind != "database"
            let parentID = meeting.notionParentID ?? defaults.string(forKey: pageParent ? "notionParentPage" : "notionSource") ?? ""
            guard kind == "workspace" || !parentID.isEmpty else { throw AppFailure("Choose where meeting pages go in Connections.") }
            let properties: [String: Any] = pageParent ? ["title": ["title": NotionClient.pageTitle(meeting)]] : NotionClient.properties(meeting, title: defaults.string(forKey: "notionTitleProperty") ?? "Name", date: defaults.string(forKey: "notionDateProperty") ?? "Date")
            if meeting.notionPageID == nil {
                let parent = NotionClient.pageParent(kind: kind, id: parentID)
                let response = try await client.call("pages", method: "POST", body: ["parent": parent, "properties": properties])
                guard currentDelivery() else { return }
                guard let page = response["id"] as? String else { throw AppFailure("Notion did not return a page ID.") }
                meeting.notionPageID = page
                store.update(id) { $0.notionPageID = page; $0.notionURL = response["url"] as? String; $0.notionParentKind = kind; $0.notionParentID = parentID }
                store.saveNow() // Retain the page ID even if content upload is interrupted.
            } else if kind != "existing" {
                _ = try await client.call("pages/" + meeting.notionPageID!, method: "PATCH", body: ["properties": properties])
            }
            guard currentDelivery() else { return }
            var children = NotionClient.content(meeting, transcript: defaults.bool(forKey: "notionIncludeTranscript"))
            if kind == "existing" { children.insert(NotionClient.block(meeting.title, type: "heading_2"), at: 0) }
            // Write native blocks directly on the page, in bounded batches.
            // Track owned IDs after each response so retries can clean up partial uploads.
            let oldIDs = Array(Set((meeting.notionBlockIDs ?? []) + [meeting.notionBlockID].compactMap { $0 }))
            var newIDs: [String] = []
            for start in stride(from: 0, to: children.count, by: 40) {
                guard currentDelivery() else { return }
                let batch = Array(children[start..<min(start + 40, children.count)])
                let body: [String: Any] = ["children": batch]
                guard try JSONSerialization.data(withJSONObject: body).count < 480000 else { throw AppFailure("A notes section is too large for Notion. Your local notes are saved.") }
                let appended = try await client.call("blocks/" + meeting.notionPageID! + "/children", method: "PATCH", body: body)
                guard currentDelivery() else { return }
                let ids = (appended["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                guard ids.count == batch.count else { throw AppFailure("Notion did not confirm every notes block. Retry to finish syncing.") }
                newIDs += ids
                store.update(id) { $0.notionBlockIDs = oldIDs + newIDs }; store.saveNow()
            }
            // Only archive blocks previously written by Minutes. Keep other edits.
            for old in oldIDs {
                guard currentDelivery() else { return }
                do { _ = try await client.call("blocks/" + old, method: "PATCH", body: ["archived": true]) }
                catch let error as NotionHTTPError where error.status == 404 { /* Already removed in Notion. */ }
                guard currentDelivery() else { return }
                store.update(id) { $0.notionBlockIDs?.removeAll { $0 == old }; if $0.notionBlockID == old { $0.notionBlockID = nil } }; store.saveNow()
            }
            store.update(id) {
                $0.notionBlockID = nil; $0.notionBlockIDs = newIDs; $0.notionSyncedAt = Date(); $0.notionError = nil
                $0.notionNeedsSync = $0.notes != meeting.notes || $0.summary != meeting.summary || $0.title != meeting.title || $0.transcript != meeting.transcript || $0.eventStart != meeting.eventStart || $0.eventEnd != meeting.eventEnd
            }; store.saveNow()
        } catch { if currentDelivery() { store.update(id) { $0.notionError = error.localizedDescription } } }
    }
    private func editedInNotion(_ id: String, since date: Date, client: NotionClient, depth: Int = 0) async throws -> Bool {
        if depth > 8 { return true }
        let block = try await client.call("blocks/" + id)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        if let raw = block["last_edited_time"] as? String,
           let edited = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw), edited > date { return true }
        if block["has_children"] as? Bool == true {
            var cursor: String?
            repeat {
                let suffix = cursor.map { "?start_cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
                let page = try await client.call("blocks/" + id + "/children" + suffix)
                for child in page["results"] as? [[String: Any]] ?? [] {
                    guard let childID = child["id"] as? String else { return true }
                    if try await editedInNotion(childID, since: date, client: client, depth: depth + 1) { return true }
                }
                cursor = page["has_more"] as? Bool == true ? page["next_cursor"] as? String : nil
            } while cursor != nil
        }
        return false
    }

}
