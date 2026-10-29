import SwiftUI
import AppKit

@MainActor struct GoogleSetup: View {
    @EnvironmentObject var calendar: CalendarMeetings
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Connect Google Calendar").font(.title3).fontWeight(.semibold); Spacer(); Text("\(step + 1) of 3").font(.caption).foregroundStyle(.secondary); Button("Cancel") { calendar.cancelSignIn(); dismiss() } }
            Divider()
            if step == 0 {
                Text("Set up Google once").font(.system(size: 19, weight: .semibold))
                Text("This private build needs a Google app registration before Google can show its sign-in screen. This step is required by Google.").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Text("1. Enable Google Calendar API in a Google Cloud project.")
                    Text("2. Set up consent and add your Google account as a test user.")
                    Text("3. Create a Desktop app client and download its JSON file.")
                }.font(.system(size: 13))
                Link("Open Google setup ↗", destination: URL(string: "https://console.cloud.google.com/auth/clients")!).buttonStyle(.bordered)
                Link("Google’s setup guide ↗", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app#prerequisites")!).font(.caption)
                Spacer()
                HStack { Button("I already have the file…", action: importClient); Spacer(); Button("Next") { step = 1 }.buttonStyle(.borderedProminent) }
            } else if step == 1 {
                Text("Choose the Google setup file").font(.system(size: 19, weight: .semibold))
                Text("Select the JSON file you downloaded from Google. Minutes will remember it, so you only do this once.").font(.callout).foregroundStyle(.secondary)
                Button("Choose JSON file…", action: importClient).buttonStyle(.borderedProminent)
                Spacer()
                Button("Back") { step = 0 }
            } else {
                Text("Sign in to your calendar").font(.system(size: 19, weight: .semibold))
                Text("Your browser will open. Choose the same Google account you use in Notion Calendar and allow calendar reading.").font(.callout).foregroundStyle(.secondary)
                Button(calendar.signingIn ? "Waiting for Google…" : "Sign in with Google") { Task { await calendar.connect(); if calendar.authorized { dismiss() } } }.buttonStyle(.borderedProminent).disabled(calendar.signingIn)
                Text("Minutes requests read-only access. It won’t change your events.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose another setup file…", action: importClient).font(.caption)
            }
            if !calendar.message.isEmpty { Text(calendar.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(24).frame(width: 490, height: 450)
        .onAppear { if calendar.configured { step = 2 } }
        .onDisappear { if calendar.signingIn { calendar.cancelSignIn() } }
    }
    private func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try calendar.importClient(Data(contentsOf: url)); step = 2 }
        catch { calendar.message = error.localizedDescription }
    }
}
