import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var pipeline: MeetingPipeline
    @EnvironmentObject var calendar: CalendarMeetings
    @ObservedObject private var notion = NotionSync.shared
    @AppStorage("includeComputer") private var includeComputer = true
    @State private var sidebar = true
    @State private var setup = false
    @State private var settingsTab = "General"
    @State private var detailsID: UUID?
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var recordingsOpen = false
    @State private var showAllEvents = false
    @State private var pane = "Notes"
    @State private var regenerate = false
    @State private var transcribeAgain = false
    private var meeting: Meeting? { store.meetings.first { $0.id == store.selectedID } }
    private var processingSelected: Bool { pipeline.working && pipeline.activeID == store.selectedID }
    private var recordingSelected: Bool { recorder.recording && recorder.meetingID == store.selectedID }
    private var processingAvailable: Bool { !pipeline.working && !recorder.recording }
    private func protected(_ id: UUID) -> Bool { (recorder.recording && recorder.meetingID == id) || (pipeline.working && pipeline.activeID == id) }
    var body: some View {
        HStack(spacing: 0) {
            if sidebar { sidebarView.frame(width: 232); Divider() }
            VStack(spacing: 0) {
                header
                ScrollView { if let meeting { document(meeting).id(meeting.id) } else { welcome } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }.background(Color(nsColor: .textBackgroundColor))
        }.tint(Color.primary)
        .sheet(isPresented: $setup, onDismiss: {
            if UserDefaults.standard.bool(forKey: "openRouterEnabled"), let meeting, meeting.pipelineStatus == "needsKey", processingAvailable { pipeline.resume(id: meeting.id, store: store, recorder: recorder) }
        }) { AppSettingsView(initialTab: settingsTab).environmentObject(calendar) }
        .sheet(isPresented: Binding(get: { detailsID != nil }, set: { if !$0 { detailsID = nil } })) {
            if let id = detailsID { DetailsView(id: id).environmentObject(store).environmentObject(recorder).environmentObject(pipeline) }
        }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit AI notes").font(.headline)
                TextEditor(text: $draft).font(.body).frame(minHeight: 300)
                HStack { Button("Cancel") { editingID = nil }; Spacer(); Button("Save") { if let id = editingID { store.update(id) { $0.summary = draft; $0.actions = [] } }; editingID = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560)
        }
        .confirmationDialog("Replace the AI notes?", isPresented: $regenerate) { Button("Generate again") { if let meeting { pipeline.resume(id: meeting.id, store: store, recorder: recorder) } } } message: { Text("Your own notes and transcript are kept.") }
        .confirmationDialog("Transcribe the recordings again?", isPresented: $transcribeAgain) { Button("Transcribe & make notes") { if let meeting { pipeline.retranscribe(id: meeting.id, store: store, recorder: recorder) } } } message: { Text("Apple will refresh the transcript from your saved audio.") }
        .onChange(of: store.selectedID) { _, _ in pane = meeting?.summary.isEmpty == false ? "AI notes" : "Notes"; recordingsOpen = false }
        .onAppear { pane = meeting?.summary.isEmpty == false ? "AI notes" : "Notes" }
        .alert("Minutes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "waveform").font(.system(size: 16)); Text("Minutes").font(.system(size: 14, weight: .semibold)); Spacer(); Button { store.create() } label: { Image(systemName: "square.and.pencil") }.help("New note · ⌘N").accessibilityLabel("New note") }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 22)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass"); TextField("Search notes", text: $store.query).textFieldStyle(.plain) }.font(.system(size: 12)).foregroundStyle(.secondary).padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if calendar.authorized && store.query.isEmpty && store.filter != "Trash" {
                        HStack { sectionLabel("Upcoming"); Spacer(); Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(.plain).help("Refresh events") }.padding(.horizontal, 9).padding(.top, 24).padding(.bottom, 5)
                        ForEach(Array(calendar.events.prefix(showAllEvents ? 50 : 5))) { event in eventRow(event) }
                        if calendar.events.isEmpty { Text(calendar.message).font(.system(size: 11)).foregroundStyle(.secondary).padding(9) }
                        if calendar.events.count > 5 { Button(showAllEvents ? "Show less" : "View all events") { showAllEvents.toggle() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary).padding(9) }
                    } else if !calendar.authorized && store.query.isEmpty {
                        Button { openSettings("Connections") } label: { Label("Connect your calendar", systemImage: "calendar.badge.plus").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 16).padding(.horizontal, 8) }.buttonStyle(.plain)
                    }
                    HStack {
                        sectionLabel(store.filter == "Trash" ? "Trash" : store.filter == "Favorites" ? "Favorites" : "Your notes"); Spacer()
                        Menu { Button("All notes") { store.filter = "All meetings" }; Button("Favorites") { store.filter = "Favorites" }; Button("Trash") { store.filter = "Trash" } } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)) }.menuStyle(.borderlessButton).frame(width: 16)
                    }.padding(.horizontal, 9).padding(.top, 22).padding(.bottom, 7)
                    ForEach(store.visible) { note in noteRow(note) }
                    if store.visible.isEmpty { Text(store.query.isEmpty ? "No notes yet" : "No matching notes").font(.system(size: 12)).foregroundStyle(.tertiary).padding(10) }
                }.padding(.horizontal, 10).padding(.bottom, 20)
            }
            Divider().opacity(0.5)
            HStack { Button { openSettings("Connections") } label: { Label("Connections", systemImage: "link").font(.system(size: 12)) }; Spacer(); Button { openSettings("General") } label: { Image(systemName: "gearshape").font(.system(size: 13)) }.help("Settings").accessibilityLabel("Settings") }.foregroundStyle(.secondary).buttonStyle(.plain).padding(18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func eventRow(_ event: CalendarMeeting) -> some View {
        Button { if let id = store.open(event) { pane = "Notes"; Task { await notion.sync(id: id, store: store) } } } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 5, height: 23).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) { Text(event.title).lineLimit(1).foregroundStyle(.primary); Text(eventTime(event.start)).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).help(event.title + " · " + eventTime(event.start))
    }
    private func noteRow(_ note: Meeting) -> some View {
        Button { store.selectedID = note.id } label: {
            HStack(spacing: 9) {
                if protected(note.id) && recorder.recording { Circle().fill(Color.red).frame(width: 6, height: 6) }
                else { Image(systemName: note.calendarEventKey == nil ? "note.text" : "calendar").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text(note.title).font(.system(size: 12)).lineLimit(1); Spacer(minLength: 0)
                if note.favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(store.selectedID == note.id ? Color.primary.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu {
            Button(note.favorite ? "Remove favorite" : "Favorite") { store.update(note.id) { $0.favorite.toggle() } }
            Button("Export notes…") { store.export(note) }
            if note.trashed { Button("Restore") { store.update(note.id) { $0.trashed = false } } }
            else { Button("Move to Trash") { store.update(note.id) { $0.trashed = true }; if store.selectedID == note.id { store.selectedID = nil } }.disabled(protected(note.id)) }
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { sidebar.toggle() } } label: { Image(systemName: "sidebar.left") }.help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
            Text(meeting?.eventCalendar ?? "Notes").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1); Spacer()
            if let meeting {
                if let raw = meeting.notionURL, let url = URL(string: raw) { Link(destination: url) { Label("Open in Notion", systemImage: "arrow.up.right").font(.system(size: 11)) } }
                Menu {
                    Button("Export notes…") { store.export(meeting) }
                    Button(meeting.favorite ? "Remove favorite" : "Favorite") { store.update(meeting.id) { $0.favorite.toggle() } }
                    Button("Details & transcript…") { detailsID = meeting.id }
                    if !meeting.audioFiles.isEmpty { Button("Transcribe again…") { transcribeAgain = true }.disabled(!processingAvailable) }
                    if !meeting.summary.isEmpty { Button("Generate again…") { regenerate = true }.disabled(!processingAvailable) }
                    Button("Sync to Notion") { sync(meeting.id) }
                    Divider(); Button("Move to Trash") { store.update(meeting.id) { $0.trashed = true }; store.selectedID = nil }.disabled(protected(meeting.id))
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            Menu { Button("Import audio…", action: importAudio); Button("Import notes or backup…") { store.importText() }; Button("Export backup…") { store.export() } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 16).help("Import & export")
        }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 53)
    }
    private func document(_ note: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if note.trashed { HStack { Text("This note is in Trash."); Spacer(); Button("Restore") { store.update(note.id) { $0.trashed = false } } }.font(.caption).padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Untitled meeting", text: Binding(get: { meeting?.title ?? "" }, set: { value in store.update(note.id) { $0.title = value } })).textFieldStyle(.plain).font(.system(size: 30, weight: .semibold))
                HStack(spacing: 8) { if note.eventStart != nil { Image(systemName: "calendar").font(.system(size: 11)) }; Text((note.eventStart ?? note.createdAt).formatted(date: .abbreviated, time: .shortened)); Text("·"); Text(store.saveState); Spacer() }.font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !note.audioFiles.isEmpty { recordings(note) }
            HStack(spacing: 24) {
                ForEach(["Notes", "AI notes", "Transcript"], id: \.self) { label in
                    Button { pane = label } label: { VStack(spacing: 10) { Text(label).font(.system(size: 12, weight: pane == label ? .medium : .regular)).foregroundStyle(pane == label ? Color.primary : Color.secondary); Capsule().fill(pane == label ? Color.primary : .clear).frame(height: 2) }.fixedSize(horizontal: true, vertical: false) }.buttonStyle(.plain)
                }; Spacer()
                if pane == "AI notes" && !note.summary.isEmpty {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.finishedNotes, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy notes")
                    Button { draft = note.finishedNotes; editingID = note.id } label: { Image(systemName: "pencil") }.help("Edit AI notes").disabled(processingSelected)
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary).overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).offset(y: 1) }
            if pane == "Notes" {
                ZStack(alignment: .topLeading) {
                    if note.notes.isEmpty { Text("Write anything you’d like to remember…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: Binding(get: { meeting?.notes ?? "" }, set: { value in store.update(note.id) { $0.notes = value } })).font(.system(size: 14)).lineSpacing(7).scrollContentBackground(.hidden).frame(minHeight: 340)
                }
            } else if pane == "AI notes" {
                if !note.summary.isEmpty { NoteDocument(text: note.finishedNotes) }
                else { emptyPane(recordingSelected ? "Notes come together after the meeting." : "Turn your conversation into clear notes.", detail: "Your transcript and anything you write are included.") }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if note.transcript.isEmpty { emptyPane(recordingSelected ? "Listening to your conversation…" : "Your transcript will appear here.", detail: recordingSelected ? "Microphone and computer audio are labeled separately." : "Start a recording, import audio, or paste a transcript in Details.") }
                    ForEach(note.transcript) { line in VStack(alignment: .leading, spacing: 7) { HStack(spacing: 6) { Text(line.source).fontWeight(.medium); Text(line.timestamp).monospacedDigit().foregroundStyle(.tertiary) }.font(.system(size: 11)).foregroundStyle(.secondary); Text(line.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            if !protected(note.id) { recovery(note) }
            if let error = note.notionError { HStack(alignment: .top) { Text(error).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Retry sync") { sync(note.id) }.font(.caption) } }
            if notion.syncing.contains(note.id) { Label("Syncing to Notion…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 48).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
    }
    private func recordings(_ note: Meeting) -> some View {
        DisclosureGroup(isExpanded: $recordingsOpen) {
            VStack(spacing: 0) {
                ForEach(Array(note.audioFiles.enumerated()), id: \.element) { index, file in
                    if recordingSelected || (processingSelected && note.pipelineStatus == "saving") { HStack { Label(RecordingTrack.source(file), systemImage: "waveform"); Spacer(); Text("Recording in progress").foregroundStyle(.secondary) }.font(.caption).padding(.vertical, 10) }
                    else if let url = store.audioURL(file) { RecordingPlayer(url: url, name: RecordingTrack.source(file) == "Recording" ? "Recording \(index + 1)" : RecordingTrack.source(file)).id(file) }
                }
            }.padding(.top, 8)
        } label: { HStack(spacing: 8) { Image(systemName: "waveform"); Text(recordingSelected ? "Recording this meeting" : "Recordings"); Spacer(); Text("\(note.audioFiles.count) \(note.audioFiles.count == 1 ? "track" : "tracks")").foregroundStyle(.tertiary) }.font(.system(size: 12)) }.padding(.horizontal, 14).padding(.vertical, 12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 8)
            Text("Room for every conversation.").font(.system(size: 26, weight: .medium))
            Text("Pick a meeting on the left, or start with a blank note.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 12) { Button("New note") { store.create() }; Button("Import audio…", action: importAudio) }.controlSize(.large).padding(.top, 12)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.top, 140)
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if recorder.recording {
                if recorder.meetingID != store.selectedID { Button { store.selectedID = recorder.meetingID } label: { HStack { Image(systemName: "arrow.turn.up.left"); Text("Return to recording"); Spacer(); Text(store.meetings.first { $0.id == recorder.meetingID }?.title ?? "").lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary) }.buttonStyle(.plain) }
                HStack(spacing: 18) { sourceMeter("Mic", icon: recorder.microphoneMuted ? "mic.slash" : "mic", level: recorder.level, help: recorder.inputName); if recorder.computerEnabled { sourceMeter("Computer", icon: "speaker.wave.2", level: recorder.computerLevel, help: recorder.computerStatus) }; Spacer(minLength: 0) }
                RecordingControls()
                if let failure = recorder.failure { Text(failure).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            } else if pipeline.working {
                HStack { ProgressView().controlSize(.small); Text(pipeline.message).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); if pipeline.activeID != store.selectedID { Button("View note") { store.selectedID = pipeline.activeID }.font(.caption) }; if pipeline.cancellable { Button("Cancel") { pipeline.cancel() }.font(.caption) } }
            } else {
                HStack(spacing: 12) {
                    Menu { Toggle("Include computer audio", isOn: $includeComputer); Divider(); Button("Import audio…", action: importAudio); Button("Import notes…") { store.importText() } } label: { Label(includeComputer ? "Mic + computer" : "Microphone", systemImage: includeComputer ? "speaker.wave.2" : "mic").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    Spacer()
                    Button { pipeline.start(store: store, recorder: recorder) } label: { Label(meeting?.audioFiles.isEmpty == false ? "New recording" : "Record meeting", systemImage: "mic.fill").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(Color(nsColor: .textBackgroundColor)).background(Color.primary, in: Capsule()) }.buttonStyle(.plain).keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }.padding(16).frame(maxWidth: 740).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07))).padding(.horizontal, 28).padding(.bottom, 20)
    }
    private func sourceMeter(_ name: String, icon: String, level: Float, help: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(name); HStack(spacing: 2) { ForEach(0..<12) { i in Capsule().fill(Double(level) > Double(i) / 12 ? Color.green.opacity(0.8) : Color.primary.opacity(0.1)).frame(width: 3, height: 9) } } }.font(.system(size: 10)).foregroundStyle(.secondary).help(help)
    }
    @ViewBuilder private func recovery(_ note: Meeting) -> some View {
        if note.pipelineStatus == "needsKey" { HStack { Text("Transcript saved. Connect AI for a summary.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Connect AI") { openSettings("General") }.font(.caption) } }
        else if ["failed", "paused"].contains(note.pipelineStatus ?? "") { VStack(alignment: .leading, spacing: 10) { Text(note.pipelineError ?? "Your recording is saved.").font(.callout).foregroundStyle(.secondary); Button("Retry") { pipeline.resume(id: note.id, store: store, recorder: recorder) }.disabled(!processingAvailable) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }
        else if note.summary.isEmpty && (!note.audioFiles.isEmpty || !note.transcript.isEmpty || !note.notes.isEmpty) { Button("Make AI notes") { pipeline.resume(id: note.id, store: store, recorder: recorder) }.disabled(!processingAvailable) }
    }
    private func emptyPane(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 14)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.vertical, 18) }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary) }
    private func eventTime(_ date: Date) -> String { Calendar.current.isDateInToday(date) ? "Today · " + date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    private func openSettings(_ tab: String) { settingsTab = tab; setup = true }
    private func sync(_ id: UUID) { if UserDefaults.standard.bool(forKey: "notionEnabled") { Task { await notion.sync(id: id, store: store) } } else { openSettings("Connections") } }
    private func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = UUID().uuidString + "." + url.pathExtension; let destination = store.audio.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
            guard let id = store.create() else { try? FileManager.default.removeItem(at: destination); return }
            store.update(id) { $0.title = url.deletingPathExtension().lastPathComponent; $0.audioFiles = [name]; $0.transcribedFiles = [] }
            if processingAvailable { pipeline.resume(id: id, store: store, recorder: recorder) }
        } catch { store.error = error.localizedDescription }
    }
}
