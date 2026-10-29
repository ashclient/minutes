import SwiftUI
import AVFoundation

@MainActor final class MeetingPipeline: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var stage = ""
    @Published private(set) var message = ""
    @Published var finishID: UUID?
    @Published private(set) var progressFraction: Double?
    @Published var liveDraft = ""
    @Published var noteWorkers: [NoteWorker] = []
    @Published var noteSections: [LiveNoteSection] = []
    @Published var draftDecisionID: UUID?
    private var work: Task<Void, Never>?
    private var canCancel = false
    private let transcriptUpdates = TranscriptUpdates()
    var working: Bool { work != nil }
    var cancellable: Bool { working && canCancel }

    private func state(_ value: String, _ text: String, id: UUID, store: Store) {
        stage = value; message = text; progressFraction = value == "generating" ? 0 : nil
        store.progress = text
        store.update(id) { $0.pipelineStatus = value; $0.pipelineError = nil }
    }
    private func run(id: UUID, store: Store, cancel: Bool, operation: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        liveDraft = ""; noteWorkers = []; noteSections = []; activeID = id; canCancel = cancel; store.busy = true
        work = Task {
            defer { noteWorkers = []; for index in noteSections.indices { noteSections[index].worker = nil }; store.busy = false; store.saveNow(); work = nil; canCancel = false }
            do { try await operation() }
            catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if !liveDraft.isEmpty { draftDecisionID = id }
                stage = cancelled ? "paused" : "failed"
                message = cancelled ? "Paused. Your recording and completed transcript are saved." : error.localizedDescription
                store.update(id) { $0.pipelineStatus = stage; $0.pipelineError = message }
            }
        }
    }
    func showProgressPreview(id: UUID) {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0 == "--preview-progress" || $0 == "--preview-progress-background" }) else { return }
        activeID = id; stage = "generating"; message = "Writing your notes…"; progressFraction = 0.62
        liveDraft = "## Main concepts\n- **Recognition:** record the transaction when the stated conditions are met.\n- Combine related explanations into one useful topic.\n\n## Allocation\n- Divide the transaction price using relative standalone prices.\n- Keep formulas and essential conditions together."
        if ProcessInfo.processInfo.arguments.contains("--preview-progress") {
            progressFraction = nil
            noteSections = LiveNoteSection.split(liveDraft)
            for index in noteSections.indices { noteSections[index].worker = index + 1 }
            noteWorkers = noteSections.enumerated().map { NoteWorker(id: $0.offset + 1, task: "Editing “" + $0.element.title + "”") }
        }
        work = Task { try? await Task.sleep(nanoseconds: 20_000_000_000) }
    }
    func start(store: Store, recorder: Recorder) {
        guard !working, !recorder.recording else { return }
        let draft = store.meetings.first { $0.id == store.selectedID && !$0.trashed }
        guard let id = draft?.id ?? store.create() else { return }
        store.update(id) {
            if $0.title == "Untitled meeting" { $0.title = "Meeting · " + Date().formatted(date: .abbreviated, time: .shortened) }
            if $0.transcribedFiles == nil { $0.transcribedFiles = $0.transcript.isEmpty ? [] : $0.audioFiles }
        }
        var offset = 0.0
        recorder.onLiveText = { lines, file in
            var tagged = lines
            for i in tagged.indices { tagged[i].audioFile = file; tagged[i].seconds += offset }
            self.transcriptUpdates.submit(id: id, file: file, lines: tagged, store: store)
        }
        run(id: id, store: store, cancel: false) {
            self.state("starting", "Starting microphone…", id: id, store: store)
            var durations: [String: Double] = [:]
            for file in draft?.audioFiles ?? [] {
                if let url = store.audioURL(file), let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration.isFinite {
                    durations[Self.group(file)] = max(durations[Self.group(file)] ?? 0, duration)
                }
            }
            offset = durations.values.reduce(0, +)
            try await recorder.start(id: id, directory: store.audio, includeComputer: UserDefaults.standard.bool(forKey: "includeComputer"))
            store.update(id) { $0.audioFiles += recorder.files.filter { !$0.isEmpty } }
            self.state("recording", "Recording", id: id, store: store)
        }
    }
    func stop(store: Store, recorder: Recorder) {
        guard !working, let id = recorder.meetingID else { return }
        let requested = recorder.files
        run(id: id, store: store, cancel: false) {
            self.state("saving", "Saving recording…", id: id, store: store)
            _ = await recorder.stop()
            self.transcriptUpdates.flush(store: store)
            recorder.onLiveText = nil
            store.update(id) {
                $0.audioDiagnostics = recorder.diagnostics
                $0.audioFiles.removeAll { requested.contains($0) && !recorder.files.contains($0) }
                $0.transcribedFiles = Array(Set(($0.transcribedFiles ?? []) + recorder.completedFiles))
            }
            store.saveNow()
            // Do not silently summarize an incomplete capture.
            if let failure = recorder.failure { throw AppFailure(failure + " Your saved tracks are in Details. Retry to process what was captured.") }
            self.canCancel = true
            self.state("awaitingNotes", "Recording saved. Choose how much detail to keep.", id: id, store: store)
            self.finishID = id
        }
    }
    func finish(id: UUID, length: NotesLength, transcriptOnly: Bool = false, store: Store, recorder: Recorder) {
        guard !working, !recorder.recording else { return }
        store.selectedID = id
        store.update(id) { $0.notesLength = length }; finishID = nil
        run(id: id, store: store, cancel: true) { try await self.process(id: id, store: store, recorder: recorder, generateNotes: !transcriptOnly) }
    }
    func resume(id: UUID, store: Store, recorder: Recorder) {
        guard !working, !recorder.recording else { return }
        run(id: id, store: store, cancel: true) { try await self.process(id: id, store: store, recorder: recorder) }
    }
    func retranscribe(id: UUID, store: Store, recorder: Recorder) {
        guard !working, !recorder.recording else { return }
        store.update(id) { $0.transcribedFiles = [] }
        resume(id: id, store: store, recorder: recorder)
    }
    func resolveDraft(keep: Bool, store: Store) {
        guard let id = draftDecisionID else { return }
        if keep && !liveDraft.isEmpty { store.update(id) { $0.summary = liveDraft; $0.actions = []; $0.pipelineStatus = "ready"; $0.pipelineError = nil } }
        liveDraft = ""; noteSections = []; noteWorkers = []; draftDecisionID = nil; stage = "ready"; message = "Notes saved"; store.saveNow()
    }
    func cancel() { if canCancel { work?.cancel() } }
    func prepareForQuit(store: Store, recorder: Recorder) {
        work?.cancel()
        transcriptUpdates.flush(store: store)
        recorder.onLiveText = nil
        for id in Set([activeID, recorder.meetingID].compactMap { $0 }) {
            store.update(id) {
                if recorder.meetingID == id {
                    for file in recorder.files where !$0.audioFiles.contains(file) { $0.audioFiles.append(file) }
                }
                $0.pipelineStatus = "paused"
                $0.pipelineError = "Saved when you quit. Finish notes whenever you’re ready."
            }
        }
        store.saveNow()
    }

    private func process(id: UUID, store: Store, recorder: Recorder, generateNotes: Bool = true) async throws {
        guard let snapshot = store.meetings.first(where: { $0.id == id }), !snapshot.trashed else { return }
        let legacyTranscript = snapshot.transcribedFiles == nil && !snapshot.transcript.isEmpty
        let done = Set(snapshot.transcribedFiles ?? (legacyTranscript ? snapshot.audioFiles : []))
        let pending = snapshot.audioFiles.filter { !done.contains($0) }
        if !pending.isEmpty {
            state("transcribing", "Transcribing on your Mac…", id: id, store: store)
            let speech = SpeechTranscriber()
            var order: [String] = []; var durations: [String: Double] = [:]
            for file in snapshot.audioFiles {
                let group = Self.group(file)
                if !order.contains(group) { order.append(group) }
                if let url = store.audioURL(file), let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration.isFinite {
                    durations[group] = max(durations[group] ?? 0, duration)
                }
            }
            var offsets: [String: Double] = [:]; var time = 0.0
            for group in order { offsets[group] = time; time += durations[group] ?? 0 }
            for file in pending {
                try Task.checkCancellation()
                guard let url = store.audioURL(file) else { throw AppFailure("A recording path is invalid.") }
                let source = RecordingTrack.source(file)
                let persist: ([TranscriptLine]) -> Void = { lines in
                    var tagged = lines
                    for i in tagged.indices { tagged[i].audioFile = file }
                    store.update(id) { meeting in
                        if !tagged.isEmpty { meeting.transcript.removeAll { $0.audioFile == nil && $0.source != "Pasted" } }
                        meeting.transcript.removeAll { $0.audioFile == file }
                        meeting.transcript += tagged
                        meeting.transcript.sort { $0.seconds < $1.seconds }
                    }
                }
                let lines = try await speech.transcribe(url: url, source: source, timeOffset: offsets[Self.group(file)] ?? 0, progress: { text in
                    self.message = text; store.progress = text
                }, partial: persist)
                persist(lines)
                store.update(id) {
                    var completed = $0.transcribedFiles ?? []
                    if !completed.contains(file) { completed.append(file) }
                    $0.transcribedFiles = completed
                }
                store.saveNow()
            }
        }
        try Task.checkCancellation()
        guard let meeting = store.meetings.first(where: { $0.id == id }) else { return }
        guard !meeting.transcript.isEmpty || !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure("No speech was found. Listen in Details to check your recording, or paste a transcript there.")
        }
        if recorder.voicedDuration > 10, recorder.files.contains(where: { meeting.audioFiles.contains($0) }) {
            let wordCount = meeting.transcript.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
            if Double(wordCount) < recorder.voicedDuration * 0.5 {
                store.update(id) { $0.transcribedFiles = [] }
                throw AppFailure("The microphone received audio for \(Int(recorder.voicedDuration)) seconds, but Apple recognized only \(wordCount) words. The transcript is incomplete. Check the speech language and macOS Sound input, or paste a corrected transcript in Details. Your audio and notes are saved.")
            }
        }
        if !generateNotes {
            state("ready", "Recording and transcript saved", id: id, store: store)
            if meeting.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) { Task { await NotionSync.shared.sync(id: id, store: store) } }
            return
        }
        let selectedProvider = NotesAIProvider.selected
        let usingApple = selectedProvider == .apple
        let cloud = selectedProvider.cloud ?? .openRouter
        if !usingApple && !UserDefaults.standard.bool(forKey: cloud.enabledKey) {
            state("needsKey", "Recording and transcript saved. Connect AI if you’d like a summary.", id: id, store: store)
            if meeting.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) { Task { await NotionSync.shared.sync(id: id, store: store) } }
            return
        }
        let key = usingApple ? "" : try CloudKey.read(service: cloud.service)
        if !usingApple && key.isEmpty {
            state("needsKey", "Recording and transcript saved. Add your AI key for a summary.", id: id, store: store)
            if meeting.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) { Task { await NotionSync.shared.sync(id: id, store: store) } }
            return
        }
        state("generating", "Writing your notes…", id: id, store: store)
        let source = ["NOTE TITLE (context only, not evidence of lecture content):\n" + meeting.title, "USER NOTES:\n" + meeting.notes, "TRANSCRIPT:\n" + meeting.transcriptText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let result: SummaryResult
        if usingApple { result = try await AppleNotesAI.summarize(source, length: meeting.notesLength ?? .complete, format: meeting.studyFormat ?? .outline, fraction: { self.progressFraction = $0 }, progress: { text in self.message = text; store.progress = text }, partial: { if !Task.isCancelled && self.activeID == id && self.stage == "generating" { self.liveDraft = $0 } }, activity: { if !Task.isCancelled && self.activeID == id && self.stage == "generating" { self.noteWorkers = $0 } }, sections: { if !Task.isCancelled && self.activeID == id && self.stage == "generating" { self.noteSections = $0 } }) }
        else { result = try await AIClient(apiKey: key, provider: cloud, model: cloud.model).summarize(source, length: meeting.notesLength ?? .complete, format: meeting.studyFormat ?? .outline, fraction: { self.progressFraction = $0 == 0 ? nil : $0 }, progress: { text in self.progressFraction = nil; self.message = text; store.progress = text }, partial: { if !Task.isCancelled && self.activeID == id && self.stage == "generating" { self.liveDraft = $0 } }) }
        try Task.checkCancellation()
        store.update(id) { $0.apply(result, originalTitle: meeting.title) }
        liveDraft = ""; noteSections = []; noteWorkers = []
        stage = "ready"; message = "Notes ready"
        if meeting.shouldSync(automatic: UserDefaults.standard.bool(forKey: "notionAutoSync")) { Task { await NotionSync.shared.sync(id: id, store: store) } }
    }
    static func group(_ file: String) -> String {
        if file.hasSuffix("-mic.m4a") { return String(file.dropLast(8)) }
        if file.hasSuffix("-mic.caf") { return String(file.dropLast(8)) }
        if file.hasSuffix("-computer.m4a") { return String(file.dropLast(13)) }
        if file.hasSuffix("-computer.caf") { return String(file.dropLast(13)) }
        return file
    }
}
