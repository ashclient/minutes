import SwiftUI
import AppKit

@MainActor struct AppSettingsView: View {
    let initialTab: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "General"
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.system(size: 15, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 15)
            Picker("Settings", selection: $tab) { Text("General").tag("General"); Text("Connections").tag("Connections") }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView { if tab == "General" { SettingsView() } else { ConnectionsView() } }
        }.frame(width: 540, height: 560).onAppear { tab = initialTab }
    }
}
@MainActor struct ConnectionsView: View {
    @EnvironmentObject var calendar: CalendarMeetings
    @AppStorage("notionEnabled") private var notionEnabled = false
    @AppStorage("notionAutoSync") private var autoSync = true
    @AppStorage("notionIncludeTranscript") private var includeTranscript = false
    @State private var google = false
    @State private var notion = false
    @State private var calendars = false
    @State private var syncOptions = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Two connections. One meeting page.").font(.system(size: 17, weight: .semibold))
            Text("Google supplies your upcoming meetings. Notion keeps the finished notes. Both are optional.").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 15) {
                HStack { Label("Google Calendar", systemImage: "calendar").font(.system(size: 14, weight: .medium)); Spacer(); if calendar.authorized { Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) } }
                Text(calendar.authorized ? calendar.message : "See your meetings in the sidebar.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    // Always actionable: missing app credentials open setup instead of disabling it.
                    Button(calendar.authorized ? "Manage Google connection" : "Connect Google") { google = true }.buttonStyle(.bordered)
                    if calendar.authorized { Button("Refresh") { calendar.refresh() }.disabled(calendar.refreshing); Spacer(); Button("Disconnect") { calendar.disconnect() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.font(.caption)
                if calendar.authorized {
                    DisclosureGroup("Choose calendars", isExpanded: $calendars) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(calendar.calendars, id: \.id) { item in
                                Toggle(item.title, isOn: Binding(get: { !(UserDefaults.standard.stringArray(forKey: "hiddenGoogleCalendars") ?? []).contains(item.id) }, set: { value in
                                    var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenGoogleCalendars") ?? [])
                                    if value { hidden.remove(item.id) } else { hidden.insert(item.id) }
                                    UserDefaults.standard.set(Array(hidden), forKey: "hiddenGoogleCalendars"); calendar.refresh()
                                }))
                            }
                        }.padding(.top, 10)
                    }.font(.caption)
                }
            }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 15) {
                HStack { Label("Notion", systemImage: "doc.text").font(.system(size: 14, weight: .medium)); Spacer(); if notionEnabled { Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) } }
                Text(notionEnabled ? "Meetings save to " + (UserDefaults.standard.string(forKey: "notionDestinationTitle") ?? "your selected Notion destination") + "." : "Give each meeting its own Notion page.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Button(notionEnabled ? "Change Notion page" : "Connect Notion") { notion = true }.buttonStyle(.bordered); Spacer(); if notionEnabled { Button("Disconnect") { do { try CloudKey.save("", service: "notion"); notionEnabled = false } catch { self.error = error.localizedDescription } }.buttonStyle(.plain).foregroundStyle(.secondary) } }.font(.caption)
                if notionEnabled {
                    DisclosureGroup("Sync options", isExpanded: $syncOptions) {
                        VStack(alignment: .leading, spacing: 10) { Toggle("Save notes automatically", isOn: $autoSync); Toggle("Include transcript", isOn: $includeTranscript); Text("Keep edits made directly in Notion outside the section managed by Minutes.").font(.caption).foregroundStyle(.secondary) }.padding(.top, 9)
                    }.font(.caption)
                }
            }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $google) { GoogleSetup().environmentObject(calendar) }
        .sheet(isPresented: $notion) { NotionSetup() }
    }
}
