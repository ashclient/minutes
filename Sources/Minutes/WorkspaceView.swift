import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.22, green: 0.36, blue: 0.29)
private let canvas = Color(nsColor: .windowBackgroundColor)

@MainActor struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var pipeline: MeetingPipeline
    @AppStorage("openRouterEnabled") private var connected = false
    @State private var history = false
    @State private var setup = false
    @State private var details = false
    @State private var editing = false
    @State private var draft = ""
    @State private var regenerate = false
    @State private var transcribeAgain = false
    @State private var pane = "My notes"
    @FocusState private var writing: Bool
    private var meeting: Meeting? { store.meetings.first { $0.id == store.selectedID && !$0.trashed } }
    private var locked: Bool { recorder.recording || pipeline.working }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                    Text("Minutes").font(.system(size: 15, weight: .semibold))
                }.foregroundStyle(.primary)
                Spacer()
                Button { store.create(); pane = "My notes" } label: { Label("New note", systemImage: "square.and.pencil") }.disabled(locked)
                Button { history = true } label: { Label("History", systemImage: "clock") }.disabled(locked)
                Button { setup = true } label: { Image(systemName: "gearshape") }.help("Settings").disabled(locked)
                Menu {
                    Button("Import audio…", action: importAudio)
                    Button("Import text or backup…") { store.importText() }
                    Button("Export text backup…") { store.export() }
                    if let meeting {
                        Divider()
                        if !meeting.audioFiles.isEmpty { Button("Transcribe again…") { transcribeAgain = true } }
                        Button("Export notes…") { store.export(meeting) }
                        Button("Move to Trash") { store.update(meeting.id) { $0.trashed = true }; store.selectedID = nil }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).disabled(locked)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let meeting {
                        TextField("Meeting title", text: Binding(get: { self.meeting?.title ?? "" }, set: { value in store.update(meeting.id) { $0.title = value } }))
                            .font(.system(size: 25, weight: .semibold)).textFieldStyle(.plain)
                        Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        HStack(spacing: 22) {
                            ForEach(["My notes", "AI notes", "Transcript"], id: \.self) { label in
                                Button { writing = false; pane = label } label: {
                                    VStack(spacing: 9) {
                                        Text(label).font(.system(size: 12, weight: pane == label ? .semibold : .regular)).foregroundStyle(pane == label ? Color.primary : Color.secondary)
                                        Capsule().fill(pane == label ? accent : Color.clear).frame(height: 2)
                                    }.fixedSize(horizontal: true, vertical: false)
                                }.buttonStyle(.plain)
                            }
                            Spacer()
                        }.padding(.top, 8)
                        Divider().padding(.top, -18)
                        if pane == "My notes" {
                            Text("Your thoughts, questions, and things worth remembering.").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { self.meeting?.notes ?? "" }, set: { value in store.update(meeting.id) { $0.notes = value } }))
                                .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden)
                                .padding(14).frame(minHeight: 300).focused($writing).disabled(pipeline.working)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                            HStack { Image(systemName: "checkmark"); Text(store.saveState); Spacer(); Text("Included in AI notes") }.font(.system(size: 10)).foregroundStyle(.tertiary)
                        } else if pane == "Transcript" {
                            Text(recorder.recording ? recorder.liveStatus : "Transcribed on your Mac").font(.caption).foregroundStyle(.secondary)
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 14) {
                                        if meeting.transcript.isEmpty { Text(recorder.recording ? "Listening…" : "Record or import audio to get a transcript.").foregroundStyle(.secondary) }
                                        ForEach(meeting.transcript) { line in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("\(line.timestamp) · \(line.source)").font(.caption).foregroundStyle(.secondary)
                                                Text(line.text).font(.callout).textSelection(.enabled)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Color.clear.frame(height: 1).id("transcriptEnd")
                                    }
                                }.frame(height: 280)
                                .onChange(of: meeting.transcript.last?.text) { _, _ in if recorder.recording { proxy.scrollTo("transcriptEnd", anchor: .bottom) } }
                            }
                            Button("Details & recordings") { details = true }.font(.caption).buttonStyle(.plain).disabled(locked)
                        } else {
                        if !meeting.summary.isEmpty {
                            NoteDocument(text: meeting.finishedNotes).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            HStack(spacing: 16) {
                                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(meeting.finishedNotes, forType: .string) }
                                Button("Edit") { draft = meeting.finishedNotes; editing = true }.disabled(locked)
                                Button("Details") { details = true }.disabled(locked)
                                Spacer()
                                if !locked { Menu { Button("Generate again…") { regenerate = true } } label: { Image(systemName: "arrow.clockwise") }.menuStyle(.borderlessButton).frame(width: 18).help("Generate again") }
                            }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 4)
                        } else if recorder.recording {
                            Text("Keep talking. We’ll take it from here.").foregroundStyle(.secondary).font(.callout)
                        } else if pipeline.working {
                            Text("Your recording is saved on this Mac.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(meeting.transcript.isEmpty ? "Your notes will appear here." : "Your transcript is saved. Finish it into clear notes below.").font(.callout).foregroundStyle(.secondary)
                            Button("Details") { details = true }.font(.caption).buttonStyle(.plain)
                            if !meeting.notes.isEmpty { NoteDocument(text: meeting.notes) }
                        }
                        }
                        if !locked { recovery(meeting) }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "note.text").font(.system(size: 28, weight: .light)).foregroundStyle(accent).padding(.bottom, 10)
                            Text("A place for the conversation.").font(.system(size: 26, weight: .semibold))
                            Button("Or start with a note") { store.create(); pane = "My notes" }.buttonStyle(.plain).foregroundStyle(accent)
                            Text("Write a few thoughts or start a recording.\nYour notes and transcript come together when you’re done.").font(.callout).foregroundStyle(.secondary)
                        }.padding(.top, 45).padding(.bottom, 30)
                    }
                }.padding(.horizontal, 30).padding(.vertical, 28).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
            }
            Divider()
            bottomBar
        }
        .background(canvas).tint(accent)
        .sheet(isPresented: $history) { HistoryView().environmentObject(store) }
        .sheet(isPresented: $setup, onDismiss: {
            if connected, let meeting, meeting.pipelineStatus == "needsKey", !locked { pipeline.resume(id: meeting.id, store: store, recorder: recorder) }
        }) { SettingsView() }
        .sheet(isPresented: $details) { if let meeting { DetailsView(id: meeting.id).environmentObject(store) } }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit notes").font(.headline)
                TextEditor(text: $draft).font(.body).frame(minHeight: 260)
                HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save") { if let meeting { store.update(meeting.id) { $0.summary = draft; $0.actions = [] } }; editing = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 520)
        }
        .confirmationDialog("Replace the generated notes?", isPresented: $regenerate) {
            Button("Generate again") { if let meeting { pipeline.resume(id: meeting.id, store: store, recorder: recorder) } }
        } message: { Text("This replaces your current generated notes and next steps. The transcript is kept.") }
        .confirmationDialog("Transcribe the saved recording again?", isPresented: $transcribeAgain) {
            Button("Transcribe & regenerate notes") { if let meeting { pipeline.retranscribe(id: meeting.id, store: store, recorder: recorder) } }
        } message: { Text("This refreshes the transcript and AI notes. Your own notes and audio are kept.") }
        .onChange(of: store.selectedID) { _, _ in pane = meeting?.summary.isEmpty == false ? "AI notes" : "My notes" }
        .onChange(of: meeting?.pipelineStatus) { _, status in if status == "ready", !writing { pane = "AI notes" } }
        .alert("Minutes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }

    }
    @ViewBuilder private func recovery(_ meeting: Meeting) -> some View {
        if meeting.pipelineStatus == "needsKey" {
            HStack { Text("Connect AI to finish these notes.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Connect") { setup = true } }
        } else if ["failed", "paused"].contains(meeting.pipelineStatus ?? "") {
            VStack(alignment: .leading, spacing: 10) {
                Text(meeting.pipelineError ?? "Your recording is saved.").font(.callout).foregroundStyle(.secondary)
                Button("Retry") { pipeline.resume(id: meeting.id, store: store, recorder: recorder) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if meeting.summary.isEmpty, !meeting.audioFiles.isEmpty || !meeting.transcript.isEmpty || !meeting.notes.isEmpty {
            Button("Make notes") { pipeline.resume(id: meeting.id, store: store, recorder: recorder) }
        }
    }
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if pipeline.working {
                ProgressView().controlSize(.small)
                Text(pipeline.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if pipeline.cancellable { Button("Cancel") { pipeline.cancel() }.font(.caption) }
            } else if recorder.recording {
                Circle().fill(.red).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit().font(.system(size: 13, weight: .medium))
                    Text(recorder.inputName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: Double(recorder.level)).tint(accent).frame(width: 65).help("Microphone input level")
                if let failure = recorder.failure { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Stop & make notes", systemImage: "stop.fill") { pipeline.stop(store: store, recorder: recorder) }.buttonStyle(.borderedProminent)
            } else {
                if !connected { Button("Connect AI") { setup = true }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary) }
                else { Text(store.saveState == "Save failed" ? "Save failed" : "Ready").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(meeting == nil || (meeting?.audioFiles.isEmpty == true && meeting?.summary.isEmpty == true) ? "Record" : "New recording", systemImage: "mic.fill") { pipeline.start(store: store, recorder: recorder) }.buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }.padding(.horizontal, 24).padding(.vertical, 17).background(Color(nsColor: .textBackgroundColor))
    }
    private func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = UUID().uuidString + "." + url.pathExtension
            let destination = store.audio.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
            guard let id = store.create() else { try? FileManager.default.removeItem(at: destination); return }
            store.update(id) { $0.title = "Meeting · " + Date().formatted(date: .abbreviated, time: .shortened); $0.audioFiles = [name]; $0.transcribedFiles = [] }
            pipeline.resume(id: id, store: store, recorder: recorder)
        } catch { store.error = error.localizedDescription }
    }
}

struct NoteDocument: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(line.drop(while: { $0 == "#" || $0 == " " })).font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) { Text("•").foregroundStyle(.secondary); Text(.init(String(line.dropFirst(2)))).frame(maxWidth: .infinity, alignment: .leading) }
                } else if !line.isEmpty { Text(.init(line)).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
    }
}

@MainActor struct HistoryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var trash = false
    @State private var deleting: UUID?
    private var meetings: [Meeting] { store.meetings.filter { $0.trashed == trash && (query.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(query)) }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text(trash ? "Trash" : "History").font(.headline); Spacer(); Button(trash ? "History" : "Trash") { trash.toggle() }.buttonStyle(.plain).font(.caption); Button("Done") { dismiss() } }
            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
            if meetings.isEmpty { Spacer(); Text("No notes here yet.").foregroundStyle(.secondary); Spacer() }
            else {
                List(meetings) { meeting in
                    Button {
                        if trash { store.update(meeting.id) { $0.trashed = false } }
                        store.selectedID = meeting.id; dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title).fontWeight(.medium).lineLimit(1)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu {
                        if trash { Button("Delete permanently", role: .destructive) { deleting = meeting.id } }
                        else { Button("Move to Trash") { store.update(meeting.id) { $0.trashed = true } } }
                    }
                }.listStyle(.plain)
            }
        }.padding(22).frame(width: 390, height: 440)
        .confirmationDialog("Delete this meeting and its recordings permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("Delete", role: .destructive) { if let deleting { store.deleteForever(deleting) }; deleting = nil } }
    }
}

@MainActor struct DetailsView: View {
    let id: UUID
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var pasted = ""
    @State private var paste = false
    @State private var removeFile: String?
    @State private var player = AVAudioPlayerHolder()
    private var meeting: Meeting? { store.meetings.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Details").font(.headline); Spacer(); Button("Done") { dismiss() } }
            if let meeting {
                if let info = meeting.audioDiagnostics {
                    DisclosureGroup("Recording information") { Text(info).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                }
                if !meeting.audioFiles.isEmpty {
                    HStack { Text("Recordings").font(.subheadline).fontWeight(.medium); Spacer(); Button("Stop playback") { player.stop() }.font(.caption) }
                    ForEach(Array(meeting.audioFiles.enumerated()), id: \.element) { index, file in
                        HStack {
                            Button { if let url = store.audioURL(file) { do { try player.play(url) } catch { store.error = error.localizedDescription } } } label: { Label(file.hasSuffix("-computer.m4a") ? "Computer audio" : "Recording \(index + 1)", systemImage: "play.circle") }
                            Spacer()
                            Button("Remove") { removeFile = file }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack { Text("Transcript").font(.subheadline).fontWeight(.medium); Spacer(); Button("Paste text") { paste.toggle() }.font(.caption) }
                if paste {
                    TextEditor(text: $pasted).frame(height: 90).border(Color.secondary.opacity(0.2))
                    Button("Add transcript") { store.update(id) { $0.transcript.append(TranscriptLine(seconds: 0, source: "Pasted", text: pasted)) }; paste = false; pasted = "" }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if meeting.transcript.isEmpty { Text("No transcript yet.").foregroundStyle(.secondary) }
                        ForEach(meeting.transcript) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(line.timestamp) · \(line.source)").font(.caption).foregroundStyle(.secondary)
                                Text(line.text).font(.callout).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !meeting.notes.isEmpty { Divider(); Text("Original notes").font(.headline); Text(meeting.notes).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24).frame(width: 520, height: 470)
        .onDisappear { player.stop() }
        .confirmationDialog("Remove this recording from your Mac?", isPresented: Binding(get: { removeFile != nil }, set: { if !$0 { removeFile = nil } })) {
            Button("Remove recording", role: .destructive) {
                guard let file = removeFile, let url = store.audioURL(file) else { return }
                do {
                    player.stop()
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    store.update(id) { $0.audioFiles.removeAll { $0 == file }; $0.transcribedFiles?.removeAll { $0 == file } }
                    removeFile = nil
                } catch { store.error = error.localizedDescription }
            }
        } message: { Text("The transcript and finished notes are kept.") }
    }
}
