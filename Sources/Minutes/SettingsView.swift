import SwiftUI
import AppKit

@MainActor struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("openRouterEnabled") private var enabled = false
    @AppStorage("speechLocale") private var language = "en-US"
    @AppStorage("includeComputer") private var computerAudio = false
    @State private var key = ""
    @State private var message = ""
    @State private var more = false
    @AppStorage("notesAIProvider") private var provider = "openrouter"
    @State private var apple = AppleAIAvailability.current
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who should write your meeting notes?").font(.system(size: 17, weight: .semibold))
            providerButton("OpenRouter", detail: "Automatic free cloud model", selected: provider == "openrouter") { provider = "openrouter" }
            providerButton("Apple Intelligence", detail: "Experimental · on this Mac · no API key", selected: provider == "apple") { if apple.available { provider = "apple" } }.disabled(!apple.available)
            HStack(alignment: .top) { Text(apple.message).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Check again") { apple = AppleAIAvailability.current }.font(.caption) }
            if provider == "apple" {
                Text("Uses Apple’s Foundation Models framework, the system model behind Apple Intelligence. It does not automate Siri. Longer recordings are summarized in sections; experimental summaries may be less detailed.").font(.callout).foregroundStyle(.secondary)
            } else {
            Text("Add an OpenRouter key once. Minutes handles the model and the rest.").font(.callout).foregroundStyle(.secondary)
            HStack { SecureField(enabled ? "Replace API key" : "OpenRouter API key", text: $key).textFieldStyle(.roundedBorder); Button(enabled ? "Update" : "Connect") { save() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            HStack {
                Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                Spacer()
                if enabled { Label("Key saved", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }.font(.caption)
            Text("Default: automatic free model. After you stop recording, your Mac transcribes locally, then sends the text to OpenRouter and its selected provider. Audio stays on your Mac. Free limits and availability apply.").font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Toggle("Include computer audio", isOn: $computerAudio).font(.callout)
            Text("For online calls. Use headphones to avoid recording voices twice.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("More", isExpanded: $more) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Speech language", selection: $language) { Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB"); Text("Spanish").tag("es-ES"); Text("French").tag("fr-FR"); Text("German").tag("de-DE") }
                    Text("Speech language support depends on your Mac. You may need to enable Dictation in macOS Keyboard settings.").font(.caption).foregroundStyle(.secondary)
                    if enabled {
                        Button("Disconnect AI") { do { try CloudKey.save(""); enabled = false; message = "Disconnected. You can still record and transcribe." } catch { message = error.localizedDescription } }
                    }
                    Button("Open recordings folder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes/Audio")) }
                }.padding(.top, 10)
            }.font(.callout)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in apple = AppleAIAvailability.current }
    }
    private func providerButton(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary) }.padding(13).background(Color.primary.opacity(selected ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    private func save() {
        do { try CloudKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; enabled = true; message = "Key saved in macOS Keychain."; dismiss() }
        catch { message = error.localizedDescription }
    }
}
