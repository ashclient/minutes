import SwiftUI
import AppKit
import Combine

@MainActor struct RecordingControls: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: MeetingPipeline
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 14 : 18) {
            HStack(spacing: 7) {
                Circle().fill(recorder.paused ? Color.orange : Color.red).frame(width: 6, height: 6)
                Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).font(.system(size: 12, weight: .medium, design: .monospaced))
                if recorder.paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            }
            if !compact { Spacer(minLength: 4) }
            control(recorder.microphoneMuted ? "mic.slash" : "mic", recorder.microphoneMuted ? "Unmute microphone" : "Mute microphone", active: recorder.microphoneMuted) { recorder.toggleMicrophone() }
            control(recorder.paused ? "play" : "pause", recorder.paused ? "Resume recording" : "Pause both audio sources", active: recorder.paused) { recorder.togglePause() }
            Button { pipeline.stop(store: store, recorder: recorder) } label: {
                HStack(spacing: 6) { Image(systemName: "stop.fill"); if !compact { Text("Finish meeting") } }.font(.system(size: 11, weight: .medium)).padding(.horizontal, compact ? 0 : 12).frame(minWidth: 30, minHeight: 30).foregroundStyle(.white).background(Color.red.opacity(0.85), in: Capsule())
            }
                .buttonStyle(.plain).help("Stop & make notes").accessibilityLabel("Stop & make notes")
        }.disabled(pipeline.working)
    }
    private func control(_ icon: String, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 6) { Image(systemName: icon); if !compact { Text(icon.contains("mic") ? (active ? "Unmute" : "Mute") : (active ? "Resume" : "Pause")) } }.font(.system(size: 12)).padding(.horizontal, compact ? 0 : 10).frame(minWidth: 30, minHeight: 30).foregroundStyle(active ? Color.orange : Color.primary).background(active ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule()) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

@MainActor final class FloatingRecorder {
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private weak var recorder: Recorder?
    private weak var store: Store?
    func configure(store: Store, recorder: Recorder, pipeline: MeetingPipeline) {
        guard panel == nil else { return }
        self.recorder = recorder; self.store = store
        let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 15.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: FloatingRecorderView(showMain: { [weak self] in self?.showMain() }).environmentObject(store).environmentObject(recorder).environmentObject(pipeline))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 352, y: screen.visibleFrame.minY + 24)) }
        self.panel = panel
        recorder.$recording.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        }
    }
    private func update() {
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" || ($0.title == "Minutes" && !($0 is NSPanel)) }
        if recorder?.recording == true && (!NSApp.isActive || main?.isMiniaturized == true || main?.isVisible != true) { panel?.orderFrontRegardless() }
        else { panel?.orderOut(nil) }
    }
    private func showMain() {
        if let id = recorder?.meetingID { store?.selectedID = id }
        let main = NSApp.windows.first { $0.title == "Minutes" && !($0 is NSPanel) }
        main?.deminiaturize(nil); main?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor private struct FloatingRecorderView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    let showMain: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text(store.meetings.first { $0.id == recorder.meetingID }?.title ?? "Recording").lineLimit(1)
                Spacer(minLength: 2)
                Button(action: showMain) { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Open meeting in Minutes").accessibilityLabel("Open meeting in Minutes")
            }.font(.system(size: 11, weight: .medium))
            RecordingControls(compact: true).frame(maxWidth: .infinity)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(width: 328, height: 88).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
    }
}
