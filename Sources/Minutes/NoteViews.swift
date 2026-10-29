import SwiftUI
import AppKit

struct NoteDocument: View, Equatable {
    let text: String
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(NoteMath.parts(text)) { part in
                let line = NoteMath.readable(part.text)
                if part.equation {
                    Text(NoteMath.readable(line)).font(.system(size: 14, design: .serif)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)).textSelection(.enabled)
                } else if line.hasPrefix("#") {
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
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var pipeline: MeetingPipeline
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
                            Button { if let url = store.audioURL(file) { do { try player.play(url) } catch { store.error = error.localizedDescription } } } label: { Label(RecordingTrack.source(file) == "Computer" ? "Computer audio" : "Recording \(index + 1)", systemImage: "play.circle") }.disabled(recorder.recording && recorder.meetingID == id)
                            Spacer()
                            Button("Remove") { removeFile = file }.font(.caption).foregroundStyle(.secondary).disabled((recorder.recording && recorder.meetingID == id) || (pipeline.working && pipeline.activeID == id))
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
