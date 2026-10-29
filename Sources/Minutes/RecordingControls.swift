import SwiftUI
import AppKit
import Combine

@MainActor struct RecordingControls: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: MeetingPipeline
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 8 : 18) {
            HStack(spacing: 7) {
                Circle().fill(recorder.paused ? Color.orange : Color.red).frame(width: 6, height: 6)
                Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).font(.system(size: 12, weight: .medium, design: .monospaced))
                if recorder.paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            }
            if !compact { Spacer(minLength: 4) }
            control(recorder.microphoneMuted ? "mic.slash" : "mic", recorder.microphoneMuted ? "Unmute microphone" : "Mute microphone", active: recorder.microphoneMuted) { recorder.toggleMicrophone() }
            control(recorder.paused ? "play" : "pause", recorder.paused ? "Resume recording" : "Pause both audio sources", active: recorder.paused) { recorder.togglePause() }
            Button { pipeline.stop(store: store, recorder: recorder) } label: {
                HStack(spacing: 6) { Image(systemName: "stop.fill"); if !compact { Text("Finish meeting") } }.font(.system(size: 11, weight: .medium)).padding(.horizontal, compact ? 0 : 12).frame(minWidth: compact ? 26 : 30, minHeight: compact ? 26 : 30).foregroundStyle(.white).background(Color.red.opacity(0.85), in: Capsule())
            }
                .buttonStyle(.plain).help("Stop & make notes").accessibilityLabel("Stop & make notes")
        }.disabled(pipeline.working)
    }
    private func control(_ icon: String, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 6) { Image(systemName: icon); if !compact { Text(icon.contains("mic") ? (active ? "Unmute" : "Mute") : (active ? "Resume" : "Pause")) } }.font(.system(size: 12)).padding(.horizontal, compact ? 0 : 10).frame(minWidth: compact ? 26 : 30, minHeight: compact ? 26 : 30).foregroundStyle(active ? Color.orange : Color.primary).background(active ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule()) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

@MainActor final class FloatingRecorder {
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private weak var recorder: Recorder?
    private weak var store: Store?
    private var collapsed = false
    func configure(store: Store, recorder: Recorder, pipeline: MeetingPipeline) {
        guard panel == nil else { return }
        self.recorder = recorder; self.store = store
        let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 15.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let previewCollapsed = ProcessInfo.processInfo.arguments.contains("--preview-recorder-collapsed")
        panel.contentView = NSHostingView(rootView: FloatingRecorderView(showMain: { [weak self] in self?.showMain() }, resize: { [weak self] collapsed in self?.resize(collapsed) }, initiallyCollapsed: previewCollapsed).environmentObject(store).environmentObject(recorder).environmentObject(pipeline))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 352, y: screen.visibleFrame.minY + 24)) }
        self.panel = panel
        if ProcessInfo.processInfo.arguments.contains("--preview-recorder") || previewCollapsed { resize(previewCollapsed); panel.orderFrontRegardless(); return }
        recorder.$recording.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        pipeline.$finishID.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in self?.showMain() }.store(in: &subscriptions)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        }
    }
    private func resize(_ collapsed: Bool) {
        guard let panel else { return }; self.collapsed = collapsed
        let size = NSSize(width: collapsed ? 244 : 280, height: collapsed ? 44 : 76)
        let old = panel.frame
        var frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size.height))
        }
        panel.setFrame(frame, display: true, animate: false)
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
@MainActor struct AudioWaveform: View {
    let level: Double
    let paused: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused || level < 0.005)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<9, id: \.self) { index in
                    let signal = paused ? 0 : min(1, sqrt(max(0, level)) * 2)
                    let motion = 0.35 + 0.65 * abs(sin(time * 7 + Double(index) * 0.9))
                    Capsule().fill(paused ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.75)).frame(width: 2, height: 3 + 19 * signal * motion)
                }
            }.frame(width: 34, height: 24)
        }.accessibilityLabel(paused ? "Recording paused" : "Live audio level")
    }
}
private struct RecorderDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
            for x in [3.0, 7.0] { for y in [8.0, 12.0, 16.0] { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill() } }
        }
    }
}
@MainActor struct FloatingRecorderView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    let showMain: () -> Void
    let resize: (Bool) -> Void
    @State private var collapsed = false
    init(showMain: @escaping () -> Void, resize: @escaping (Bool) -> Void, initiallyCollapsed: Bool = false) {
        self.showMain = showMain; self.resize = resize; _collapsed = State(initialValue: initiallyCollapsed)
    }
    var body: some View {
        VStack(spacing: 5) {
            if !collapsed {
                HStack(spacing: 6) {
                    RecorderDragHandle().frame(width: 12, height: 24).help("Drag to move recorder")
                    AudioWaveform(level: Double(max(recorder.microphoneMuted ? 0 : recorder.level, recorder.computerLevel)), paused: recorder.paused)
                    Text(store.meetings.first { $0.id == recorder.meetingID }?.title ?? "Recording").lineLimit(1).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    Button(action: showMain) { Image(systemName: "arrow.up.right") }.help("Open meeting in Minutes")
                    collapseButton
                }.buttonStyle(.plain).font(.system(size: 10))
            }
            HStack(spacing: 5) {
                if collapsed { RecorderDragHandle().frame(width: 12, height: 24).help("Drag to move recorder"); AudioWaveform(level: Double(max(recorder.microphoneMuted ? 0 : recorder.level, recorder.computerLevel)), paused: recorder.paused).frame(width: 24).clipped() }
                RecordingControls(compact: true)
                if collapsed { collapseButton }
            }
        }.padding(.horizontal, 10).padding(.vertical, 7).frame(width: collapsed ? 244 : 280, height: collapsed ? 44 : 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: collapsed ? 22 : 13)).overlay(RoundedRectangle(cornerRadius: collapsed ? 22 : 13).stroke(Color.primary.opacity(0.1)))
    }
    private var collapseButton: some View {
        Button { collapsed.toggle(); resize(collapsed) } label: { Image(systemName: collapsed ? "chevron.up" : "chevron.down").font(.system(size: 10)).frame(width: 18, height: 22) }.buttonStyle(.plain).help(collapsed ? "Expand recorder" : "Collapse recorder").accessibilityLabel(collapsed ? "Expand recorder" : "Collapse recorder")
    }
}
