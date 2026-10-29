import SwiftUI
import AVFoundation

@MainActor final class MeetingPipeline: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var stage = ""
    @Published private(set) var message = ""
    private var work: Task<Void, Never>?
    private var canCancel = false
    var working: Bool { work != nil }
    var cancellable: Bool { working && canCancel }

    private func state(_ value: String, _ text: String, id: UUID, store: Store) {
        stage = value; message = text
        store.progress = text
        store.update(id) { $0.pipelineStatus = value; $0.pipelineError = nil }
    }
    private func run(id: UUID, store: Store, cancel: Bool, operation: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        activeID = id; canCancel = cancel; store.busy = true
        work = Task {
            defer { store.busy = false; store.saveNow(); work = nil; canCancel = false }
            do { try await operation() }
            catch {
                let cancelled = Task.isCancelled || error is CancellationError
                stage = cancelled ? "paused" : "failed"
                message = cancelled ? "Paused. Your recording and completed transcript are saved." : error.localizedDescription
                store.update(id) { $0.pipelineStatus = stage; $0.pipelineError = message }
            }
        }
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
            store.update(id) { meeting in
                meeting.transcript.removeAll { $0.audioFile == file }
                meeting.transcript += tagged
                meeting.transcript.sort { $0.seconds < $1.seconds }
            }
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
            try await self.process(id: id, store: store, recorder: recorder)
        }
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
    func cancel() { if canCancel { work?.cancel() } }
    func prepareForQuit(store: Store, recorder: Recorder) {
        work?.cancel()
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

    private func process(id: UUID, store: Store, recorder: Recorder) async throws {
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
        guard UserDefaults.standard.bool(forKey: "openRouterEnabled") else {
            state("needsKey", "Recording and transcript saved. Connect AI if you’d like a summary.", id: id, store: store)
            if UserDefaults.standard.bool(forKey: "notionAutoSync") { Task { await NotionSync.shared.sync(id: id, store: store) } }
            return
        }
        let key = try CloudKey.read()
        guard !key.isEmpty else {
            state("needsKey", "Recording and transcript saved. Add your AI key for a summary.", id: id, store: store)
            if UserDefaults.standard.bool(forKey: "notionAutoSync") { Task { await NotionSync.shared.sync(id: id, store: store) } }
            return
        }
        state("generating", "Writing your notes…", id: id, store: store)
        let source = ["USER NOTES:\n" + meeting.notes, "TRANSCRIPT:\n" + meeting.transcriptText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let result = try await AIClient(apiKey: key).summarize(source, progress: { text in self.message = text; store.progress = text })
        try Task.checkCancellation()
        store.update(id) { $0.apply(result, originalTitle: meeting.title) }
        stage = "ready"; message = "Notes ready"
        if UserDefaults.standard.bool(forKey: "notionAutoSync") { Task { await NotionSync.shared.sync(id: id, store: store) } }
    }
    static func group(_ file: String) -> String {
        if file.hasSuffix("-mic.m4a") { return String(file.dropLast(8)) }
        if file.hasSuffix("-mic.caf") { return String(file.dropLast(8)) }
        if file.hasSuffix("-computer.m4a") { return String(file.dropLast(13)) }
        if file.hasSuffix("-computer.caf") { return String(file.dropLast(13)) }
        return file
    }
}
