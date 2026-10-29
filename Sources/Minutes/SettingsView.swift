import SwiftUI
import AppKit

@MainActor struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("openRouterEnabled") private var enabled = false
    @AppStorage("nvidiaEnabled") private var nvidiaEnabled = false
    @State private var saving = false
    @State private var validationTask: Task<Void, Never>?
    private var cloud: CloudAIProvider { provider == "nvidia" ? .nvidia : .openRouter }
    private var cloudEnabled: Bool { cloud == .nvidia ? nvidiaEnabled : enabled }
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
            providerButton("OpenRouter", detail: "Automatic free cloud model", selected: provider == "openrouter") { provider = "openrouter" }.disabled(saving)
            providerButton("NVIDIA API", detail: "Nemotron 3.5 Lightning · cloud", selected: provider == "nvidia") { provider = "nvidia" }.disabled(saving)
            providerButton("Apple Intelligence", detail: "Experimental · on this Mac · no API key", selected: provider == "apple") { if apple.available { provider = "apple" } }.disabled(!apple.available || saving)
            HStack(alignment: .top) { Text(apple.message).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Check again") { apple = AppleAIAvailability.current }.font(.caption) }
            if provider == "apple" {
                Text("Uses Apple’s Foundation Models framework, the system model behind Apple Intelligence. It does not automate Siri. Longer recordings are summarized in sections; experimental summaries may be less detailed.").font(.callout).foregroundStyle(.secondary)
            } else {
            Text("Add your " + cloud.title + " API key once. The model is selected for you.").font(.callout).foregroundStyle(.secondary)
            HStack {
                SecureField(cloudEnabled ? "Replace " + cloud.title + " key" : cloud.title + " API key", text: $key).textFieldStyle(.roundedBorder).disabled(saving)
                Button(saving ? "Checking…" : cloudEnabled ? "Update" : "Connect") { validationTask = Task { await check(save: true) } }.disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Link("Get a " + cloud.title + " key", destination: cloud.keyURL)
                Spacer()
                if cloudEnabled {
                    Button("Test connection") { validationTask = Task { await check(save: false) } }.disabled(saving)
                    Label("Key saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }.font(.caption)
            Text(cloud == .nvidia ? "Default: Nemotron 3.5 Lightning. Your transcript and typed notes are sent directly to NVIDIA; audio stays on your Mac. NVIDIA account limits and endpoint availability apply." : "Default: automatic free model. Your transcript and typed notes are sent to OpenRouter and its selected provider; audio stays on your Mac. Free limits and availability apply.").font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            UpdateSettings()
            Divider()
            Toggle("Include computer audio", isOn: $computerAudio).font(.callout)
            Text("For online calls. Use headphones to avoid recording voices twice.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("More", isExpanded: $more) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Speech language", selection: $language) { Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB"); Text("Spanish").tag("es-ES"); Text("French").tag("fr-FR"); Text("German").tag("de-DE") }
                    Text("Speech language support depends on your Mac. You may need to enable Dictation in macOS Keyboard settings.").font(.caption).foregroundStyle(.secondary)
                    if provider != "apple" && cloudEnabled {
                        Button("Remove " + cloud.title + " key") {
                            do { try CloudKey.save("", service: cloud.service); if cloud == .nvidia { nvidiaEnabled = false } else { enabled = false }; message = cloud.title + " key removed." }
                            catch { message = error.localizedDescription }
                        }.disabled(saving)
                    }
                    Button("Open recordings folder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes/Audio")) }
                }.padding(.top, 10)
            }.font(.callout)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--preview-settings-nvidia") { provider = "nvidia" } }
        .onChange(of: provider) { _, _ in key = ""; message = "" }
        .onDisappear { validationTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in apple = AppleAIAvailability.current }
    }
    private func providerButton(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary) }.padding(13).background(Color.primary.opacity(selected ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()) }.buttonStyle(SurfaceButtonStyle(radius: 10))
    }
    private func check(save: Bool) async {
        let target = cloud
        let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true; message = ""; defer { saving = false }
        do {
            let candidate = entered.isEmpty ? try CloudKey.read(service: target.service) : entered
            // NVIDIA is validated before its key is persisted or enabled. A
            // manual test is available for either cloud provider's saved key.
            if target == .nvidia || !save { try await AIClient(apiKey: candidate, provider: target).checkConnection() }
            try Task.checkCancellation()
            if save {
                try CloudKey.save(candidate, service: target.service)
                if target == .nvidia { nvidiaEnabled = true } else { enabled = true }
                key = ""; message = target.title + " key saved in macOS Keychain."
            } else { message = target.title + " connection is working." }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
