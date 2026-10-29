import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct SettingsRoute: Identifiable { let tab: String; var id: String { tab } }

@MainActor struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var pipeline: MeetingPipeline
    @EnvironmentObject var calendar: CalendarMeetings
    @ObservedObject private var notion = NotionSync.shared
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("includeComputer") private var includeComputer = false
    @State private var sidebar = true
    @State private var showCalendar = false
    @State private var setup: SettingsRoute?
    @State private var detailsID: UUID?
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var recordingsOpen = false
    @State private var transcriptOpen = false
    @State private var syncDelay: Task<Void, Never>?
    @State private var showAllEvents = false
    @State private var pane = "Notes"
    @State private var regenerate = false
    @State private var transcribeAgain = false
    @State private var deletingID: UUID?
    private var meeting: Meeting? { store.meetings.first { $0.id == store.selectedID } }
    private var processingSelected: Bool { pipeline.working && pipeline.activeID == store.selectedID }
    private var recordingSelected: Bool { recorder.recording && recorder.meetingID == store.selectedID && pipeline.stage == "recording" }
    private var processingAvailable: Bool { !pipeline.working && !recorder.recording }
    private func protected(_ id: UUID) -> Bool { (recorder.recording && recorder.meetingID == id) || (pipeline.working && pipeline.activeID == id) }
    var body: some View {
        HStack(spacing: 0) {
            if sidebar { sidebarView.frame(width: 232); Divider() }
            VStack(spacing: 0) {
                header
                if showCalendar {
                    MeetingCalendarView { event in openEvent(event) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in ScrollView { if let meeting { document(meeting).id(meeting.id) } else { welcome } }.onChange(of: transcriptOpen) { _, open in if open { proxy.scrollTo("transcript-section", anchor: .top) } } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }.tint(Color.primary)
        .confirmationDialog("Keep the notes generated so far?", isPresented: Binding(get: { pipeline.draftDecisionID != nil }, set: { _ in })) {
            Button("Keep partial notes") { pipeline.resolveDraft(keep: true, store: store) }
            Button("Revert to previous notes") { pipeline.resolveDraft(keep: false, store: store) }
        } message: { Text("Your recording, transcript and custom notes are kept either way. Partial notes may not cover the whole lecture.") }
        .sheet(isPresented: Binding(get: { pipeline.finishID != nil }, set: { if !$0 { pipeline.finishID = nil } })) {
            if let id = pipeline.finishID { FinishNotesView(id: id).environmentObject(store).environmentObject(recorder).environmentObject(pipeline).interactiveDismissDisabled() }
        }
        .sheet(item: $setup, onDismiss: {
            if (UserDefaults.standard.bool(forKey: "openRouterEnabled") || (NotesAIProvider.selected == .apple && AppleAIAvailability.current.available)), let meeting, meeting.pipelineStatus == "needsKey", processingAvailable { pipeline.resume(id: meeting.id, store: store, recorder: recorder) }
        }) { route in AppSettingsView(initialTab: route.tab).environmentObject(calendar) }
        .sheet(isPresented: Binding(get: { detailsID != nil }, set: { if !$0 { detailsID = nil } })) {
            if let id = detailsID { DetailsView(id: id).environmentObject(store).environmentObject(recorder).environmentObject(pipeline) }
        }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit AI notes").font(.headline)
                TextEditor(text: $draft).font(.body).frame(minHeight: 300)
                HStack { Button("Cancel") { editingID = nil }; Spacer(); Button("Save") { if let id = editingID { store.update(id) { $0.summary = draft; $0.actions = [] }; if UserDefaults.standard.bool(forKey: "notionAutoSync") { Task { await notion.sync(id: id, store: store) } } }; editingID = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560)
        }
        .confirmationDialog("Replace the AI notes?", isPresented: $regenerate) { Button("Choose detail level…") { if let meeting { pipeline.finishID = meeting.id } } } message: { Text("Your own notes and transcript are kept.") }
        .confirmationDialog("Transcribe the recordings again?", isPresented: $transcribeAgain) { Button("Transcribe & make notes") { if let meeting { pipeline.retranscribe(id: meeting.id, store: store, recorder: recorder) } } } message: { Text("Apple will refresh the transcript from your saved audio.") }
        .confirmationDialog("Permanently delete this note and its recordings?", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) { Button("Delete permanently", role: .destructive) { if let id = deletingID { store.deleteForever(id) }; deletingID = nil } }
        .onChange(of: store.selectedID) { _, _ in showCalendar = false; pane = meeting?.summary.isEmpty == false ? "AI notes" : "Notes"; recordingsOpen = false }
        .onChange(of: meeting?.notes) { _, _ in
            syncDelay?.cancel()
            guard let note = meeting, !protected(note.id), note.notionPageID != nil, note.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) else { return }
            syncDelay = Task {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                await notion.sync(id: note.id, store: store)
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--preview-transcript") {
                try? await Task.sleep(nanoseconds: 400_000_000); transcriptOpen = true
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains(where: { $0 == "--preview-progress" || $0 == "--preview-progress-background" }), let id = store.selectedID {
                pipeline.showProgressPreview(id: id)
                if ProcessInfo.processInfo.arguments.contains("--preview-progress-background"), let other = store.meetings.first(where: { $0.id != id }) { store.selectedID = other.id }
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-calendar") { showCalendar = true }
            if ProcessInfo.processInfo.arguments.contains("--preview-finish") || ProcessInfo.processInfo.arguments.contains("--preview-delivery"), let id = store.selectedID { pipeline.finishID = id }
            if ProcessInfo.processInfo.arguments.contains("--preview-connections") || (ProcessInfo.processInfo.arguments.contains("--preview-notion") || ProcessInfo.processInfo.arguments.contains("--preview-notion-destination")) || ProcessInfo.processInfo.arguments.contains("--preview-google") { openSettings("Connections") }
            if ProcessInfo.processInfo.arguments.contains("--preview-settings") { openSettings("General") }
            if UserDefaults.standard.bool(forKey: "notionEnabled") {
                for note in store.meetings where !note.trashed && note.notionNeedsSync == true && note.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) && note.pipelineStatus != "awaitingNotes" && (note.notionPageID != nil || note.calendarEventKey != nil) {
                    Task { await notion.sync(id: note.id, store: store) }
                }
            }
        }
        .alert("Minutes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "waveform").font(.system(size: 16)); Text("Minutes").font(.system(size: 14, weight: .semibold)); Spacer(); Button { store.create() } label: { Image(systemName: "square.and.pencil") }.help("New note · ⌘N").accessibilityLabel("New note") }.buttonStyle(QuietButtonStyle()).padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 22)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass"); TextField("Search notes", text: $store.query).textFieldStyle(.plain) }.font(.system(size: 12)).foregroundStyle(.secondary).padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12)
            Button { showCalendar.toggle() } label: { HStack { Image(systemName: "calendar"); Text(showCalendar ? "Back to notes" : "Calendar"); Spacer() }.font(.system(size: 12)).padding(10).background(showCalendar ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(QuietButtonStyle()).padding(.horizontal, 12).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if calendar.authorized && store.query.isEmpty && store.filter != "Trash" {
                        HStack { sectionLabel("Upcoming"); Spacer(); Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(QuietButtonStyle()).help("Refresh events") }.padding(.horizontal, 9).padding(.top, 24).padding(.bottom, 5)
                        ForEach(Array(calendar.events.filter { $0.end > Date() }.prefix(showAllEvents ? calendar.events.count : 5))) { event in eventRow(event) }
                        if calendar.events.isEmpty { Text(calendar.message).font(.system(size: 11)).foregroundStyle(.secondary).padding(9) }
                        if calendar.events.count > 5 { Button(showAllEvents ? "Show less" : "View all events") { showAllEvents.toggle() }.font(.system(size: 11)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(9) }
                    } else if !calendar.authorized && store.query.isEmpty {
                        Button { openSettings("Connections") } label: { Label("Connect Google Calendar", systemImage: "calendar.badge.plus").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 16).padding(.horizontal, 8) }.buttonStyle(QuietButtonStyle())
                    }
                    HStack {
                        sectionLabel(store.filter == "Trash" ? "Trash" : store.filter == "Favorites" ? "Favorites" : "Your notes"); Spacer()
                        Menu { Button("All notes") { store.filter = "All meetings" }; Button("Favorites") { store.filter = "Favorites" }; Button("Trash") { store.filter = "Trash" } } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)) }.menuStyle(.borderlessButton).frame(width: 16)
                    }.padding(.horizontal, 9).padding(.top, 22).padding(.bottom, 7)
                    ForEach(store.visible) { note in noteRow(note) }
                    if store.visible.isEmpty { Text(store.query.isEmpty ? "No notes yet" : "No matching notes").font(.system(size: 12)).foregroundStyle(.tertiary).padding(10) }
                }.padding(.horizontal, 10).padding(.bottom, 20)
            }
            activityStatus
            Divider().opacity(0.5)
            HStack { Button { openSettings("Connections") } label: { Label("Connections", systemImage: "link").font(.system(size: 12)) }; Spacer(); Button { openSettings("General") } label: { Image(systemName: "gearshape").font(.system(size: 13)) }.help("Settings").accessibilityLabel("Settings") }.foregroundStyle(.secondary).buttonStyle(QuietButtonStyle()).padding(18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var activityStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pipeline.working, let id = pipeline.activeID, showCalendar || id != store.selectedID {
                Button { store.selectedID = id; showCalendar = false } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ActivityPulse(); Text("Working in background").font(.system(size: 11, weight: .medium)); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                        Text(store.meetings.first(where: { $0.id == id })?.title ?? "Meeting").font(.system(size: 11)).lineLimit(1)
                        ProcessingProgressView(message: pipeline.message, fraction: pipeline.progressFraction)
                    }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(QuietButtonStyle()).help("Open the meeting being processed. Switching notes keeps processing running.")
            } else if recorder.recording, let id = recorder.meetingID {
                Button { store.selectedID = id; showCalendar = false } label: {
                    HStack { Circle().fill(.red).frame(width: 6, height: 6); Text(recorder.paused ? "Recording paused" : "Recording"); Spacer(); RecordingClock(meters: recorder.meters) }.font(.system(size: 11)).padding(10)
                }.buttonStyle(QuietButtonStyle())
            } else if pipeline.stage == "failed" || pipeline.stage == "paused", let id = pipeline.activeID {
                Button { store.selectedID = id; showCalendar = false } label: { Label(pipeline.stage == "failed" ? "Notes need attention" : "Processing paused", systemImage: "exclamationmark.circle").font(.system(size: 11)).padding(8) }.buttonStyle(QuietButtonStyle())
            }
            if !notion.syncing.isEmpty { HStack { ActivityPulse(); Text("Syncing to Notion…").font(.system(size: 11)); Spacer(); ProgressView().controlSize(.mini) }.padding(.horizontal, 10) }
            if updater.available != nil { Button { openSettings("General") } label: { Label("Minutes update available", systemImage: "arrow.down.circle").font(.system(size: 11)).padding(8) }.buttonStyle(QuietButtonStyle()) }
            if calendar.monthLoading { HStack { ProgressView().controlSize(.mini); Text("Loading calendar…").font(.system(size: 11)) }.padding(.horizontal, 10) }
        }.padding(.horizontal, 10).padding(.bottom, pipeline.working || recorder.recording || !notion.syncing.isEmpty || calendar.monthLoading ? 10 : 0)
    }
    private func openEvent(_ event: CalendarMeeting) {
        showCalendar = false
        _ = store.open(event)
    }
    private func eventRow(_ event: CalendarMeeting) -> some View {
        Button { openEvent(event) } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 5, height: 23).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) { Text(event.title).lineLimit(1).foregroundStyle(.primary); Text(eventTime(event.start)).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle()).help(event.title + " · " + eventTime(event.start))
    }
    private func noteRow(_ note: Meeting) -> some View {
        Button { showCalendar = false; store.selectedID = note.id } label: {
            HStack(spacing: 9) {
                if protected(note.id) && recorder.recording { Circle().fill(Color.red).frame(width: 6, height: 6) }
                else { Image(systemName: note.calendarEventKey == nil ? "note.text" : "calendar").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text(note.title).font(.system(size: 12)).lineLimit(1); Spacer(minLength: 0)
                if note.favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(store.selectedID == note.id ? Color.primary.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle()).contextMenu {
            Button(note.favorite ? "Remove favorite" : "Favorite") { store.update(note.id) { $0.favorite.toggle() } }
            Button("Export notes…") { store.export(note) }
            if note.trashed { Button("Restore") { store.update(note.id) { $0.trashed = false } }; Button("Delete permanently…", role: .destructive) { deletingID = note.id }.disabled(protected(note.id)) }
            else { Button("Move to Trash") { store.update(note.id) { $0.trashed = true }; if store.selectedID == note.id { store.selectedID = nil } }.disabled(protected(note.id)) }
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { sidebar.toggle() } } label: { Image(systemName: "sidebar.left") }.help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
            Text(showCalendar ? "Calendar" : meeting?.eventCalendar ?? "Notes").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1); Spacer()
            if let meeting, !showCalendar {
                if let raw = meeting.notionURL, let url = URL(string: raw) { Link(destination: url) { Label("Open in Notion", systemImage: "arrow.up.right").font(.system(size: 11)) } }
                Menu {
                    Button("Export notes…") { store.export(meeting) }
                    Button(meeting.favorite ? "Remove favorite" : "Favorite") { store.update(meeting.id) { $0.favorite.toggle() } }
                    Button("Manage recordings…") { detailsID = meeting.id }
                    if !meeting.audioFiles.isEmpty { Button("Transcribe again…") { transcribeAgain = true }.disabled(!processingAvailable) }
                    Button("Sync to Notion") { sync(meeting.id) }
                    Divider(); Button("Move to Trash") { store.update(meeting.id) { $0.trashed = true }; store.selectedID = nil }.disabled(protected(meeting.id))
                } label: { Text("Note actions") }.menuStyle(.borderlessButton).frame(width: 100)
            }
            Menu { Button("Import audio…", action: importAudio); Button("Import notes or backup…") { store.importText() }; Button("Export backup…") { store.export() } } label: { Text("Files") }.menuStyle(.borderlessButton).frame(width: 65).help("Import & export")
        }.buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 53)
    }
    private func document(_ note: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if note.trashed { HStack { Text("This note is in Trash."); Spacer(); Button("Restore") { store.update(note.id) { $0.trashed = false } } }.font(.caption).padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Untitled meeting", text: Binding(get: { meeting?.title ?? "" }, set: { value in store.update(note.id) { $0.title = value } })).textFieldStyle(.plain).font(.system(size: 28, weight: .semibold))
                HStack(spacing: 8) {
                    Image(systemName: note.eventStart == nil ? "note.text" : "calendar")
                    Text((note.eventStart ?? note.createdAt).formatted(date: .abbreviated, time: .shortened))
                    Text("·"); Text(store.saveState)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if recordingSelected { Label("Recording this meeting. You can keep writing below.", systemImage: "record.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
            if processingSelected { Text(pipeline.message).font(.system(size: 12)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 10) {
                Text("Your notes").font(.system(size: 13, weight: .semibold))
                ZStack(alignment: .topLeading) {
                    if note.notes.isEmpty { Text("Write questions, reminders, or anything you want to keep…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: Binding(get: { meeting?.notes ?? "" }, set: { value in store.update(note.id) { $0.notes = value } })).font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden).frame(minHeight: note.summary.isEmpty ? 220 : 130)
                }
            }
            if pipeline.activeID == note.id && !pipeline.liveDraft.isEmpty {
                Divider()
                Label("Live draft · still being organized", systemImage: "pencil.line").font(.caption).foregroundStyle(.secondary)
                StreamingNotesView(text: pipeline.liveDraft, running: pipeline.working)
            }
            if !note.summary.isEmpty && !(pipeline.activeID == note.id && !pipeline.liveDraft.isEmpty) {
                Divider()
                HStack {
                    Text("Meeting notes").font(.system(size: 14, weight: .semibold)); Spacer()
                    Button("Regenerate…") { regenerate = true }.disabled(!processingAvailable)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.finishedNotes, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { draft = note.finishedNotes; editingID = note.id } label: { Label("Edit", systemImage: "pencil") }.disabled(processingSelected)
                }.buttonStyle(QuietButtonStyle()).font(.system(size: 11)).foregroundStyle(.secondary)
                NoteDocument(text: note.finishedNotes).equatable()
            }
            if !note.audioFiles.isEmpty || !note.transcript.isEmpty || recordingSelected { sourceCard(note) }
            if !protected(note.id) { recovery(note) }
            if let error = note.notionError { HStack(alignment: .top) { Text(error).font(.caption).foregroundStyle(.secondary); Spacer(); if error.hasPrefix("Notion edits detected.") {
                    Button("Preserve edits & add copy") { store.update(note.id) { $0.notionBlockIDs = []; $0.notionBlockID = nil; $0.notionSyncedAt = nil }; sync(note.id) }.font(.caption)
                } else { Button("Retry Notion") { sync(note.id) }.font(.caption) } } }
            if note.notionSyncEnabled == false { Text("Notion sync is off for this meeting.").font(.system(size: 10)).foregroundStyle(.tertiary) }
            else if notion.syncing.contains(note.id) { Label("Saving to Notion…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
            else if let date = note.notionSyncedAt { Text("Saved to Notion · " + date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 48).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
    }
    private func sourceCard(_ note: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                if !note.audioFiles.isEmpty {
                    Button { recordingsOpen.toggle(); if recordingsOpen { transcriptOpen = false } } label: {
                        HStack(spacing: 7) { Image(systemName: recordingsOpen ? "chevron.down" : "chevron.right").font(.system(size: 9)); Image(systemName: "waveform"); Text("Recordings"); Text("\(note.audioFiles.count)").foregroundStyle(.tertiary) }
                    }.accessibilityLabel(recordingsOpen ? "Hide recordings" : "Show recordings")
                }
                if !note.transcript.isEmpty || recordingSelected {
                    Button { transcriptOpen.toggle(); if transcriptOpen { recordingsOpen = false } } label: {
                        HStack(spacing: 7) { Image(systemName: transcriptOpen ? "chevron.down" : "chevron.right").font(.system(size: 9)); Image(systemName: "text.alignleft"); Text("Transcript") }
                    }.accessibilityLabel(transcriptOpen ? "Hide transcript" : "Show transcript")
                }
                Spacer(minLength: 0)
            }.buttonStyle(QuietButtonStyle()).font(.system(size: 12, weight: .medium)).padding(.vertical, 12)
            if recordingsOpen {
                Divider()
                ForEach(Array(note.audioFiles.enumerated()), id: \.element) { index, file in
                    if recordingSelected || (processingSelected && note.pipelineStatus == "saving") {
                        HStack { Label(RecordingTrack.source(file), systemImage: "waveform"); Spacer(); Text("Recording in progress").foregroundStyle(.secondary) }.font(.caption).padding(.vertical, 10)
                    } else if let url = store.audioURL(file) {
                        RecordingPlayer(url: url, name: RecordingTrack.source(file) == "Recording" ? "Recording \(index + 1)" : RecordingTrack.source(file)).id(file)
                    }
                }
            }
            if transcriptOpen { Divider(); TranscriptListView(lines: note.transcript).padding(.bottom, 14) }
        }.padding(.horizontal, 14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).id("transcript-section")
    }
    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 8)
            Text("Start with a meeting.").font(.system(size: 26, weight: .medium))
            Text("Choose a Google Calendar event, write or record, then finish.\nMinutes saves the notes to its linked Notion page.").multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 12) { Button(calendar.authorized ? "Refresh Google meetings" : "Connect Google Calendar") { if calendar.authorized { calendar.refresh() } else { openSettings("Connections") } }; Button("Blank note") { store.create() } }.controlSize(.large).padding(.top, 12)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.top, 140)
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if recorder.recording && !pipeline.working {
                if recorder.meetingID != store.selectedID { Button { store.selectedID = recorder.meetingID } label: { HStack { Image(systemName: "arrow.turn.up.left"); Text("Return to recording"); Spacer(); Text(store.meetings.first { $0.id == recorder.meetingID }?.title ?? "").lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary) }.buttonStyle(QuietButtonStyle()) }
                RecordingSourceMeters(meters: recorder.meters, muted: recorder.microphoneMuted, computer: recorder.computerEnabled, input: recorder.inputName, status: recorder.computerStatus)
                RecordingControls()
                if let failure = recorder.failure { Text(failure).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            } else if pipeline.working {
                HStack(spacing: 16) { ProcessingProgressView(message: pipeline.message, fraction: pipeline.progressFraction); if pipeline.activeID != store.selectedID { Button("View note") { store.selectedID = pipeline.activeID }.font(.caption) }; if pipeline.cancellable { Button("Cancel") { pipeline.cancel() }.font(.caption) } }
            } else {
                HStack(spacing: 12) {
                    Menu { Toggle("Include computer audio", isOn: $includeComputer); Divider(); Button("Import audio…", action: importAudio); Button("Import notes…") { store.importText() } } label: { Label(includeComputer ? "Mic + computer" : "Microphone", systemImage: includeComputer ? "speaker.wave.2" : "mic").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    Spacer()
                    Button { pipeline.start(store: store, recorder: recorder) } label: { Label("Record this meeting", systemImage: "mic.fill").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(Color(nsColor: .textBackgroundColor)).background(Color.primary, in: Capsule()) }.buttonStyle(QuietButtonStyle()).keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }.padding(16).frame(maxWidth: 740).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07))).padding(.horizontal, 28).padding(.bottom, 20)
    }
    private func sourceMeter(_ name: String, icon: String, level: Float, help: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(name); HStack(spacing: 2) { ForEach(0..<12) { i in Capsule().fill(Double(level) > Double(i) / 12 ? Color.green.opacity(0.8) : Color.primary.opacity(0.1)).frame(width: 3, height: 9) } } }.font(.system(size: 10)).foregroundStyle(.secondary).help(help)
    }
    @ViewBuilder private func recovery(_ note: Meeting) -> some View {
        if note.pipelineStatus == "needsKey" { HStack { Text("Transcript saved. Connect AI for a summary.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Connect AI") { openSettings("General") }.font(.caption) } }
        else if ["failed", "paused", "awaitingNotes"].contains(note.pipelineStatus ?? "") { VStack(alignment: .leading, spacing: 10) { Text(note.pipelineError ?? (note.pipelineStatus == "awaitingNotes" ? "Recording saved. Choose how much detail to keep." : "Your recording is saved.")).font(.callout).foregroundStyle(.secondary); Button("Finish notes") { pipeline.finishID = note.id }.disabled(!processingAvailable) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }
        else if note.summary.isEmpty && (!note.audioFiles.isEmpty || !note.transcript.isEmpty || !note.notes.isEmpty) { Button("Make AI notes") { pipeline.finishID = note.id }.disabled(!processingAvailable) }
    }
    private func emptyPane(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 14)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.vertical, 18) }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary) }
    private func eventTime(_ date: Date) -> String { Calendar.current.isDateInToday(date) ? "Today · " + date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    private func openSettings(_ tab: String) { setup = SettingsRoute(tab: tab) }
    private func sync(_ id: UUID) { if UserDefaults.standard.bool(forKey: "notionEnabled") { store.update(id) { $0.notionSyncEnabled = true }; Task { await notion.sync(id: id, store: store) } } else { openSettings("Connections") } }
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
