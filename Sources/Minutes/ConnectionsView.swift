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
    @State private var googleSetup = false
    @State private var connectionExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Connections").font(.title3).fontWeight(.semibold); Spacer(); Button("Done") { dismiss() } }
            Label("Google Calendar", systemImage: "calendar").font(.system(size: 14, weight: .semibold))
            Text("Connect the Google account you use in Notion Calendar. Click a meeting in the sidebar to open its note.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(calendar.signingIn ? "Waiting for Google…" : calendar.authorized ? "Reconnect Google" : "Connect Google") { Task { await calendar.connect() } }.disabled(calendar.signingIn || !calendar.configured)
                if calendar.signingIn { Button("Cancel") { calendar.cancelSignIn() } }
                if calendar.authorized { Button("Refresh") { calendar.refresh() }.disabled(calendar.refreshing); Button("Disconnect") { calendar.disconnect() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            Text(calendar.message).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(calendar.configured ? "Google app setup" : "Set up Google sign-in once", isExpanded: $googleSetup) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This private build needs a Google Desktop OAuth client. Enable the Google Calendar API in your Google Cloud project, configure the consent screen with your account as a test user, then create a Desktop app OAuth client and download its JSON file.").font(.caption).foregroundStyle(.secondary)
                    Link("Google OAuth clients ↗", destination: URL(string: "https://console.cloud.google.com/auth/clients")!).font(.caption)
                    Button("Import Google client JSON…") { importGoogleClient() }
                    Text("Sign-in opens your browser. Calendar access is read-only. Credentials and tokens stay in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption)
            if calendar.authorized {
                DisclosureGroup("Choose Google calendars", isExpanded: $showCalendars) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendar.calendars, id: \.id) { item in
                            Toggle(item.title, isOn: Binding(get: { !(UserDefaults.standard.stringArray(forKey: "hiddenGoogleCalendars") ?? []).contains(item.id) }, set: { value in
                                var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenGoogleCalendars") ?? [])
                                if value { hidden.remove(item.id) } else { hidden.insert(item.id) }
                                UserDefaults.standard.set(Array(hidden), forKey: "hiddenGoogleCalendars"); calendar.refresh()
                            }))
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            Divider().padding(.vertical, 4)
            Label("Notion", systemImage: "square.stack").font(.system(size: 14, weight: .semibold))
            Text("Choose a Notion page to keep your meeting notes in. Clicking a calendar event creates one child page named after that event, with a date mention. Finishing the meeting updates that same page.").font(.callout).foregroundStyle(.secondary)
            if notionEnabled { Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            DisclosureGroup(notionEnabled ? "Change connection" : "Set up Notion", isExpanded: Binding(get: { !notionEnabled || connectionExpanded }, set: { connectionExpanded = $0 })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Create an internal connection in Notion with read, insert, and update access. Copy its secret below.").font(.caption).foregroundStyle(.secondary)
                    Link("Create a Notion connection ↗", destination: URL(string: "https://www.notion.so/profile/integrations")!).font(.caption)
                    SecureField(notionEnabled ? "New secret (leave blank to keep saved key)" : "Notion connection secret", text: $token).textFieldStyle(.roundedBorder)
                    Text("2. Open the parent page or database in Notion → ••• → Connections → add your connection. Copy its link below.").font(.caption).foregroundStyle(.secondary)
                    Picker("Destination", selection: $existing) { Text("A Notion parent page").tag(false); Text("Use an existing database").tag(true) }.font(.caption)
                    TextField(existing ? "Notion database link" : "Notion parent page link", text: $destination).textFieldStyle(.roundedBorder)
                    Button(working ? "Connecting…" : notionEnabled ? "Update connection" : "Connect Notion") { Task { await connectNotion() } }.disabled(working || destination.isEmpty || (!notionEnabled && token.isEmpty))
                }.padding(.top, 10)
            }
            if notionEnabled {
                Toggle("Sync automatically after making notes", isOn: $autoSync).font(.callout)
                Toggle("Include the transcript in Notion", isOn: $includeTranscript).font(.callout)
                Text("Minutes updates its own meeting-notes section. Keep edits you make directly in Notion outside that section.").font(.caption).foregroundStyle(.secondary)
                HStack { if let raw = UserDefaults.standard.string(forKey: "notionDatabaseURL"), let url = URL(string: raw) { Link("Open database ↗", destination: url) }; Spacer(); Button("Disconnect Notion") { do { try CloudKey.save("", service: "notion"); notionEnabled = false } catch { message = error.localizedDescription; self.error = true } } }.font(.caption)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(error ? Color.red : Color.secondary) }
            Text("Once connected: choose an event → write or record → finish the meeting. Open in Notion takes you to its saved page.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !calendar.configured { googleSetup = true } }
    }
    private func importGoogleClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try calendar.importClient(Data(contentsOf: url)); googleSetup = false }
        catch { calendar.message = error.localizedDescription }
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
                _ = try await client.call("pages/" + id)
                defaults.set(id, forKey: "notionParentPage")
            }
            defaults.set(existing ? "database" : "page", forKey: "notionDestinationKind")
            if !key.isEmpty { try CloudKey.save(key, service: "notion") }
            defaults.set(destination, forKey: "notionDestination"); notionEnabled = true; token = ""
            message = "Connected. Click an upcoming meeting to create its linked page."
        } catch { message = error.localizedDescription; self.error = true }
    }
}
