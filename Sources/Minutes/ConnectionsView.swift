import SwiftUI
import AppKit

@MainActor struct AppSettingsView: View {
    let initialTab: String
    @State private var tab = "General"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) { Text("General").tag("General"); Text("Connections").tag("Connections") }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.top, 20)
            ScrollView { if tab == "General" { SettingsView() } else { ConnectionsView() } }.frame(maxHeight: 650)
        }.frame(width: 540).onAppear { tab = initialTab }
    }
}
@MainActor struct ConnectionsView: View {
    @EnvironmentObject var calendar: CalendarMeetings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notionEnabled") private var notionEnabled = false
    @AppStorage("notionAutoSync") private var autoSync = true
    @AppStorage("notionIncludeTranscript") private var includeTranscript = false
    @State private var token = ""
    @State private var destination = UserDefaults.standard.string(forKey: "notionDestination") ?? ""
    @State private var existing = UserDefaults.standard.string(forKey: "notionSource") != nil
    @State private var working = false
    @State private var message = ""
    @State private var error = false
    @State private var showCalendars = false
    @State private var connectionExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Connections").font(.title3).fontWeight(.semibold); Spacer(); Button("Done") { dismiss() } }
            Label("Calendar", systemImage: "calendar").font(.system(size: 14, weight: .semibold))
            Text("See upcoming meetings and open a note with the event’s name. Uses the calendars already synced to macOS Calendar, including Google and iCloud.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(calendar.authorized ? "Refresh events" : "Connect calendar") { Task { if calendar.authorized { calendar.refresh() } else { await calendar.connect() } } }
                if calendar.authorized { Button("Disconnect") { calendar.disconnect() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Button("Calendar accounts…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts")!) }.font(.caption)
            }
            Text(calendar.message).font(.caption).foregroundStyle(.secondary)
            if calendar.authorized {
                DisclosureGroup("Choose calendars", isExpanded: $showCalendars) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendar.calendars, id: \.id) { item in
                            Toggle(item.title, isOn: Binding(get: { !(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []).contains(item.id) }, set: { value in
                                var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
                                if value { hidden.remove(item.id) } else { hidden.insert(item.id) }
                                UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars"); calendar.refresh()
                            }))
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            Divider().padding(.vertical, 4)
            Label("Notion", systemImage: "square.stack").font(.system(size: 14, weight: .semibold))
            Text("Each meeting you open can have a dated Notion page. Minutes syncs your notes and summary after recording.").font(.callout).foregroundStyle(.secondary)
            if notionEnabled { Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            DisclosureGroup(notionEnabled ? "Change connection" : "Set up Notion", isExpanded: Binding(get: { !notionEnabled || connectionExpanded }, set: { connectionExpanded = $0 })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Create an internal connection in Notion with read, insert, and update access. Copy its secret below.").font(.caption).foregroundStyle(.secondary)
                    Link("Create a Notion connection ↗", destination: URL(string: "https://www.notion.so/profile/integrations")!).font(.caption)
                    SecureField(notionEnabled ? "New secret (leave blank to keep saved key)" : "Notion connection secret", text: $token).textFieldStyle(.roundedBorder)
                    Text("2. Open the parent page or database in Notion → ••• → Connections → add your connection. Copy its link below.").font(.caption).foregroundStyle(.secondary)
                    Picker("Destination", selection: $existing) { Text("Create a Minutes database in a page").tag(false); Text("Use an existing database").tag(true) }.font(.caption)
                    TextField(existing ? "Notion database link" : "Parent Notion page link", text: $destination).textFieldStyle(.roundedBorder)
                    Button(working ? "Connecting…" : notionEnabled ? "Update connection" : "Connect Notion") { Task { await connectNotion() } }.disabled(working || destination.isEmpty || (!notionEnabled && token.isEmpty))
                }.padding(.top, 10)
            }
            if notionEnabled {
                Toggle("Sync automatically after making notes", isOn: $autoSync).font(.callout)
                Toggle("Include the transcript in Notion", isOn: $includeTranscript).font(.callout)
                Text("Minutes replaces its own “Minutes notes” section on sync. Keep edits you make in Notion outside that section.").font(.caption).foregroundStyle(.secondary)
                HStack { if let raw = UserDefaults.standard.string(forKey: "notionDatabaseURL"), let url = URL(string: raw) { Link("Open database ↗", destination: url) }; Spacer(); Button("Disconnect Notion") { do { try CloudKey.save("", service: "notion"); notionEnabled = false } catch { message = error.localizedDescription; self.error = true } } }.font(.caption)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(error ? Color.red : Color.secondary) }
            Text("To see the dated pages in Notion Calendar, add the Minutes database there. Notion’s own upcoming-events sidebar and native AI meeting-note links are controlled by Notion.").font(.caption).foregroundStyle(.secondary)
            Link("How to add a database to Notion Calendar ↗", destination: URL(string: "https://www.notion.com/help/use-notion-calendar-with-notion")!).font(.caption)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func connectNotion() async {
        working = true; message = ""; error = false
        defer { working = false }
        do {
            let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = NotionClient(token: key.isEmpty ? try CloudKey.read(service: "notion") : key)
            let id = try NotionClient.identifier(destination)
            let defaults = UserDefaults.standard
            if existing {
                let resolved = try await client.resolveDatabase(id)
                defaults.set(resolved.source, forKey: "notionSource"); defaults.set(resolved.title, forKey: "notionTitleProperty"); defaults.set(resolved.date, forKey: "notionDateProperty"); defaults.set(resolved.url, forKey: "notionDatabaseURL")
            } else {
                let created = try await client.createDatabase(parent: id)
                defaults.set(created.source, forKey: "notionSource"); defaults.set("Name", forKey: "notionTitleProperty"); defaults.set("Date", forKey: "notionDateProperty"); defaults.set(created.url, forKey: "notionDatabaseURL")
                destination = created.url; existing = true
            }
            if !key.isEmpty { try CloudKey.save(key, service: "notion") }
            defaults.set(destination, forKey: "notionDestination"); notionEnabled = true; token = ""
            message = "Connected. Click an upcoming meeting to create its linked page."
        } catch { message = error.localizedDescription; self.error = true }
    }
}
