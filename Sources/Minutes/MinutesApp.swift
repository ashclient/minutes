import SwiftUI
import AppKit

@main @MainActor struct MinutesApp: App {
    @StateObject private var store = Store()
    @StateObject private var recorder = Recorder()
    @StateObject private var pipeline = MeetingPipeline()
    @StateObject private var calendar = CalendarMeetings()
    init() { UserDefaults.standard.register(defaults: ["includeComputer": true, "notionAutoSync": true]) }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Minutes", id: "main") {
            WorkspaceView()
                .environmentObject(store).environmentObject(recorder).environmentObject(pipeline).environmentObject(calendar)
                .frame(minWidth: 850, minHeight: 560)
                .onAppear { delegate.store = store; delegate.recorder = recorder; delegate.floating.configure(store: store, recorder: recorder, pipeline: pipeline) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New note") { store.create() }.keyboardShortcut("n")
                Button("Import notes or backup…") { store.importText() }.keyboardShortcut("o")
                Button("Export text backup…") { store.export() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Minutes guide") { NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Guide.html")) }
            }
        }
        Settings { AppSettingsView(initialTab: "General").environmentObject(calendar) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    weak var recorder: Recorder?
    let floating = FloatingRecorder()
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
