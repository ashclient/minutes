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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("AI notes").font(.title3).fontWeight(.semibold); Spacer(); Button("Done") { dismiss() } }
            Text("Add an OpenRouter key once. Minutes handles the model and the rest.").font(.callout).foregroundStyle(.secondary)
            HStack { SecureField(enabled ? "Replace API key" : "OpenRouter API key", text: $key).textFieldStyle(.roundedBorder); Button(enabled ? "Update" : "Connect") { save() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            HStack {
                Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                Spacer()
                if enabled { Label("Key saved", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }.font(.caption)
            Text("Default: automatic free model. After you stop recording, your Mac transcribes locally, then sends the text to OpenRouter and its selected provider. Audio stays on your Mac. Free limits and availability apply.").font(.caption).foregroundStyle(.secondary)
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
        }.padding(24).frame(width: 440)
    }
    private func save() {
        do { try CloudKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; enabled = true; message = "Key saved in macOS Keychain."; dismiss() }
        catch { message = error.localizedDescription }
    }
}
