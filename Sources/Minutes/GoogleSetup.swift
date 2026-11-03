import SwiftUI
import AppKit

@MainActor struct GoogleSetup: View {
    @EnvironmentObject var calendar: CalendarMeetings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Connect Google Calendar").font(.title3).fontWeight(.semibold); Spacer(); Button("Cancel") { calendar.cancelSignIn(); dismiss() } }
            Divider()
            Text("Your meetings, in Minutes").font(.system(size: 21, weight: .semibold))
            Text("Sign in with the Google account you use for your calendar. Choose which calendars appear after connecting.").foregroundStyle(.secondary)
            Label("Read-only access to events and your calendar list", systemImage: "calendar")
            Label("Minutes won’t create or change events", systemImage: "lock")
            if calendar.configured {
                Button(calendar.signingIn ? "Waiting for Google…" : "Sign in with Google") {
                    Task { await calendar.connect(); if calendar.authorized { dismiss() } }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(calendar.signingIn)
            } else {
                Text("Google sign-in has not been enabled by the publisher for this build. Existing custom connections still work.").foregroundStyle(.secondary)
            }
            if !calendar.message.isEmpty { Text(calendar.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            HStack(spacing: 16) {
                Link("Privacy policy", destination: URL(string: "https://ashclient.github.io/minutes/privacy.html")!)
                Link("Terms of Service", destination: URL(string: "https://ashclient.github.io/minutes/terms.html")!)
            }.font(.caption)
            DisclosureGroup("Advanced · custom app registration") {
                Text("For developers or self-hosted builds only. Regular sign-in uses Minutes’ hosted sign-in service.").font(.caption).foregroundStyle(.secondary)
                Button("Import a Desktop client…", action: importClient).disabled(calendar.signingIn)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 490, height: 460)
        .onDisappear { if calendar.signingIn { calendar.cancelSignIn() } }
    }
    private func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try calendar.importClient(Data(contentsOf: url)) }
        catch { calendar.message = error.localizedDescription }
    }
}
