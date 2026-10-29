import SwiftUI
import AppKit

struct NotionPageChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String
    static func parse(_ json: [String: Any]) -> Self? {
        guard json["object"] as? String == "page", let id = json["id"] as? String, json["archived"] as? Bool != true, json["in_trash"] as? Bool != true else { return nil }
        let properties = json["properties"] as? [String: [String: Any]] ?? [:]
        let rich = properties.values.first(where: { $0["type"] as? String == "title" })?["title"] as? [[String: Any]] ?? []
        let name = rich.map { $0["plain_text"] as? String ?? ($0["text"] as? [String: String])?["content"] ?? "" }.joined()
        return Self(id: id, title: name.isEmpty ? "Untitled page" : name, url: json["url"] as? String ?? "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: ""))
    }
}
@MainActor struct NotionSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var destination = "workspace"
    @State private var canCreatePrivate = false
    @State private var token = ""
    @State private var verifiedKey = ""
    @State private var query = ""
    @State private var pages: [NotionPageChoice] = []
    @State private var selected: String?
    @State private var manual = false
    @State private var manualURL = ""
    @State private var working = false
    @State private var message = ""
    @State private var cursor: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Connect Notion").font(.title3).fontWeight(.semibold); Spacer(); Text("\(step + 1) of 2").font(.caption).foregroundStyle(.secondary); Button("Cancel") { dismiss() } }
            Divider()
            if step == 0 {
                Text("Create a personal token").font(.system(size: 19, weight: .semibold))
                Text("In Notion, create a token named Minutes. Choose your workspace and enable Notion API, then paste the token here.").font(.callout).foregroundStyle(.secondary)
                Link("Open Notion’s token page ↗", destination: URL(string: "https://www.notion.so/developers/tokens")!).buttonStyle(.bordered)
                SecureField("Paste Notion token", text: $token).textFieldStyle(.roundedBorder)
                Text("It is saved in this Mac’s Keychain. A personal token uses your existing page access, so you don’t need to share each page with a bot.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Using an internal connection instead?") {
                    Text("Its token also works. In Notion, open the page you want to use → ••• → Connections → add that connection before continuing.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.caption)
                Spacer(minLength: 0)
                HStack { Spacer(); Button(working ? "Checking…" : "Continue") { Task { await verify() } }.buttonStyle(.borderedProminent).disabled(working) }
            } else {
                Text("Where should new pages appear?").font(.system(size: 19, weight: .semibold))
                Picker("Destination", selection: $destination) {
                    Text("Private · top level").tag("workspace").disabled(!canCreatePrivate)
                    Text("Inside a page").tag("page")
                }.pickerStyle(.segmented).labelsHidden()
                Text(destination == "workspace" ? "Each new meeting becomes its own page under Private, alongside your other notes. No parent page needed." : "Each meeting gets a separate subpage inside your selected page.").font(.callout).foregroundStyle(.secondary)
                if !canCreatePrivate { Text("Top-level pages require a personal access token. Use Back to replace your internal connection token.").font(.caption).foregroundStyle(.secondary) }
                if destination == "page" {
                TextField("Find a Notion page", text: $query).textFieldStyle(.roundedBorder)
                List(pages) { page in
                    Button { selected = page.id } label: { HStack { Image(systemName: "doc").foregroundStyle(.secondary); Text(page.title).lineLimit(1); Spacer(); if selected == page.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }.padding(.vertical, 5).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.listStyle(.inset).frame(minHeight: 120)
                .task(id: query) {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    await loadPages()
                }
                if cursor != nil { Button("Show more pages") { Task { await loadPages(more: true) } }.font(.caption).disabled(working) }
                DisclosureGroup("My page isn’t listed", isExpanded: $manual) {
                    VStack(alignment: .leading, spacing: 7) { Text("Copy its link from Notion and paste it below. Internal connections must be added to that page first.").font(.caption).foregroundStyle(.secondary); TextField("Notion page link", text: $manualURL).textFieldStyle(.roundedBorder) }.padding(.top, 6)
                }.font(.caption)
                } else { Spacer(minLength: 16); Label("New meeting → New private page", systemImage: "doc.badge.plus").font(.callout); Spacer(minLength: 0) }
                HStack { Button("Back") { step = 0 }; Spacer(); Button(working ? "Connecting…" : destination == "workspace" ? "Use Private pages" : "Save meetings here") { Task { await finish() } }.buttonStyle(.borderedProminent).disabled(working) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(24).frame(minHeight: 500, alignment: .topLeading) }.frame(width: 490, height: 550)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--preview-notion-destination") { step = 1; canCreatePrivate = true; destination = "workspace"; return }
            if UserDefaults.standard.bool(forKey: "notionEnabled"), let saved = try? CloudKey.read(service: "notion"), !saved.isEmpty { verifiedKey = saved; step = 1; Task { await checkOwner() } }
        }
    }
    private func verify() async {
        working = true; message = ""; defer { working = false }
        do {
            let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entered.isEmpty ? try CloudKey.read(service: "notion") : entered
            guard !key.isEmpty else { throw AppFailure("Open Notion’s token page, create a token with Notion API access, then paste it above.") }
            verifiedKey = key
            try await readOwner()
            step = 1
        } catch { message = error.localizedDescription }
    }
    private func readOwner() async throws {
        let me = try await NotionClient(token: verifiedKey).call("users/me")
        let bot = me["bot"] as? [String: Any]
        let owner = bot?["owner"] as? [String: Any]
        canCreatePrivate = owner?["type"] as? String == "user"
        destination = canCreatePrivate ? "workspace" : "page"
    }
    private func checkOwner() async { do { try await readOwner() } catch { message = error.localizedDescription } }
    private func loadPages(more: Bool = false) async {
        working = true; message = ""; defer { working = false }
        do {
            var body: [String: Any] = ["filter": ["property": "object", "value": "page"], "page_size": 50, "sort": ["direction": "descending", "timestamp": "last_edited_time"]]
            if !query.isEmpty { body["query"] = query }
            if more, let cursor { body["start_cursor"] = cursor }
            let response = try await NotionClient(token: verifiedKey).call("search", method: "POST", body: body)
            try Task.checkCancellation()
            let found = (response["results"] as? [[String: Any]] ?? []).compactMap(NotionPageChoice.parse)
            pages = more ? pages + found.filter { row in !pages.contains(where: { $0.id == row.id }) } : found
            cursor = response["next_cursor"] as? String
            if pages.isEmpty { message = "No pages found. Try another search, or paste a page link below." }
        } catch is CancellationError { } catch { message = error.localizedDescription }
    }
    private func finish() async {
        working = true; message = ""; defer { working = false }
        do {
            guard !verifiedKey.isEmpty else { throw AppFailure("Add your personal token first.") }
            if destination == "workspace" {
                guard canCreatePrivate else { throw AppFailure("Use a personal access token for top-level private pages.") }
                try CloudKey.save(verifiedKey, service: "notion")
                let defaults = UserDefaults.standard
                defaults.set("workspace", forKey: "notionDestinationKind"); defaults.set("Private", forKey: "notionDestinationTitle"); defaults.set("", forKey: "notionParentPage"); defaults.set(true, forKey: "notionEnabled")
                dismiss(); return
            }
            let choice = pages.first { $0.id == selected }
            let id: String
            if manual && !manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { id = try NotionClient.identifier(manualURL) }
            else { guard let choice else { throw AppFailure("Choose a parent page, then click Save meetings here.") }; id = choice.id }
            let object = try await NotionClient(token: verifiedKey).call("pages/" + id)
            guard let page = NotionPageChoice.parse(object) else { throw AppFailure("That Notion page is unavailable. Choose another page.") }
            try CloudKey.save(verifiedKey, service: "notion")
            let defaults = UserDefaults.standard
            defaults.set(id, forKey: "notionParentPage"); defaults.set("page", forKey: "notionDestinationKind")
            defaults.set(page.url, forKey: "notionDestination"); defaults.set(page.title, forKey: "notionDestinationTitle"); defaults.set(true, forKey: "notionEnabled")
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
