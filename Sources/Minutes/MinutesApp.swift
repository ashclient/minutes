import SwiftUI
import AppKit

@main @MainActor struct MinutesApp: App {
    @StateObject private var store = Store()
    @StateObject private var recorder = Recorder()
    @StateObject private var pipeline = MeetingPipeline()
    @StateObject private var calendar = CalendarMeetings()
    init() { UserDefaults.standard.register(defaults: ["includeComputer": false, "notionAutoSync": true]) }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Minutes", id: "main") {
            WorkspaceView()
                .environmentObject(store).environmentObject(recorder).environmentObject(pipeline).environmentObject(calendar)
                .frame(minWidth: 850, minHeight: 560)
                .onAppear { delegate.store = store; delegate.recorder = recorder; delegate.pipeline = pipeline; delegate.floating.configure(store: store, recorder: recorder, pipeline: pipeline) }
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
    weak var pipeline: MeetingPipeline?
    private var quitting = false
    private var replied = false
    let floating = FloatingRecorder()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        store?.saveNow()
        guard recorder?.recording == true || store?.busy == true else { return .terminateNow }
        quitting = true
        if let store, let recorder { pipeline?.prepareForQuit(store: store, recorder: recorder) }
        Task { [self] in await recorder?.saveForQuit(); finishQuit(sender) }
        // A stalled OS service must not make Quit wait indefinitely.
        Task { [self] in try? await Task.sleep(nanoseconds: 4_000_000_000); finishQuit(sender) }
        return .terminateLater
    }
    private func finishQuit(_ app: NSApplication) { guard !replied else { return }; replied = true; store?.saveNow(); app.reply(toApplicationShouldTerminate: true) }
}
