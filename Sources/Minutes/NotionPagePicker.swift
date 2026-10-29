import SwiftUI

@MainActor struct NotionPagePicker: View {
    @Binding var selection: NotionPageChoice?
    @State private var query = ""
    @State private var pages: [NotionPageChoice] = []
    @State private var cursor: String?
    @State private var message = ""
    @State private var loading = false
    @State private var manual = false
    @State private var link = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search your Notion pages", text: $query).textFieldStyle(.roundedBorder)
            if let selection { Label(selection.title, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(pages) { page in
                        Button { selection = page } label: { HStack { Image(systemName: "doc.text"); Text(page.title).lineLimit(1); Spacer(); if selection?.id == page.id { Image(systemName: "checkmark") } }.font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(selection?.id == page.id ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain)
                    }
                    if cursor != nil { Button("Show more pages") { Task { await search(more: true) } }.font(.caption).disabled(loading) }
                }
            }.frame(height: 135)
            if loading { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Or paste a page link", isExpanded: $manual) {
                HStack { TextField("Notion page link", text: $link).textFieldStyle(.roundedBorder); Button("Use page") { Task { await useLink() } }.disabled(loading || link.isEmpty) }.padding(.top, 6)
            }.font(.caption)
            Text("Minutes adds a separate section. Your existing content and page title stay intact.").font(.caption).foregroundStyle(.secondary)
        }.task(id: query) {
            do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation() } catch { return }
            await search()
        }
    }
    private func search(more: Bool = false) async {
        if ProcessInfo.processInfo.arguments.contains("--preview-delivery") {
            pages = [NotionPageChoice(id: "sample-a", title: "Accounting · class notes", url: "https://www.notion.so/sample-a"), NotionPageChoice(id: "sample-b", title: "Business · exam review", url: "https://www.notion.so/sample-b")]; loading = false; return
        }
        loading = true; message = ""; defer { if !Task.isCancelled { loading = false } }
        do {
            let key = try CloudKey.read(service: "notion")
            var body: [String: Any] = ["filter": ["property": "object", "value": "page"], "page_size": 50]
            if !query.isEmpty { body["query"] = query }; if more, let cursor { body["start_cursor"] = cursor }
            let result = try await NotionClient(token: key).call("search", method: "POST", body: body)
            try Task.checkCancellation()
            let found = (result["results"] as? [[String: Any]] ?? []).compactMap(NotionPageChoice.parse)
            pages = more ? pages + found.filter { row in !pages.contains { $0.id == row.id } } : found
            cursor = result["next_cursor"] as? String
            if pages.isEmpty { message = "No matching pages. Try another search or paste a link." }
        } catch is CancellationError { } catch { message = error.localizedDescription }
    }
    private func useLink() async {
        loading = true; message = ""; defer { loading = false }
        do {
            let id = try NotionClient.identifier(link)
            let object = try await NotionClient(token: CloudKey.read(service: "notion")).call("pages/" + id)
            guard let page = NotionPageChoice.parse(object) else { throw AppFailure("That page is unavailable.") }
            selection = page
        } catch { message = error.localizedDescription }
    }
}
