import SwiftUI
import AppKit

@main @MainActor struct MinutesApp: App {
    @StateObject private var store = Store()
    @StateObject private var recorder = Recorder()
    @StateObject private var pipeline = MeetingPipeline()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Minutes", id: "main") {
            WorkspaceView()
                .environmentObject(store).environmentObject(recorder).environmentObject(pipeline)
                .frame(minWidth: 480, minHeight: 400)
                .onAppear { delegate.store = store; delegate.recorder = recorder }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 640, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New note") { store.create() }.keyboardShortcut("n").disabled(store.busy || recorder.recording)
                Button("Import notes or backup…") { store.importText() }.keyboardShortcut("o").disabled(store.busy || recorder.recording)
                Button("Export text backup…") { store.export() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Minutes guide") { NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Guide.html")) }
            }
        }
        Settings { SettingsView() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    weak var recorder: Recorder?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder?.recording == true {
            let alert = NSAlert(); alert.messageText = "A meeting is recording"; alert.informativeText = "Stop and save the recording before quitting."; alert.addButton(withTitle: "Keep recording"); alert.runModal(); return .terminateCancel
        }
        if store?.busy == true {
            let alert = NSAlert(); alert.messageText = "Work is still in progress"; alert.informativeText = "Wait for it to finish, or cancel it in the meeting before quitting."; alert.addButton(withTitle: "Return to Minutes"); alert.runModal(); return .terminateCancel
        }
        store?.saveNow(); return .terminateNow
    }
}
