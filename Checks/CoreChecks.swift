import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Runs with Command Line Tools alone. No XCTest, credentials, or network needed.
@main struct CoreChecks {
    static func expectFailure(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection, but operation succeeded") } catch { }
    }
    static func main() throws {
        let key = "fixture-key-not-a-secret"
        let request = try AIClient.request(key: key, system: "Return JSON", text: "We agreed to send the agenda.")
        precondition(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] as? String == "openrouter/free")
        precondition(body["stream"] as? Bool == false)
        precondition((body["response_format"] as? [String: String])?["type"] == "json_object")
        precondition((body["provider"] as? [String: Bool])?["require_parameters"] == true)
        precondition(body["audio"] == nil && body["tools"] == nil && body["models"] == nil)
        expectFailure { _ = try AIClient.request(key: " ", system: "", text: "") }
        let result = SummaryResult(title: "Agenda planning", summary: "Reviewed the agenda.", decisions: ["Meet on Friday"], actions: ["Send the agenda", "Send the agenda"])
        let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        let decoded = try AIClient.decode(envelope, status: 200)
        precondition(decoded.title == "Agenda planning")
        for code in [401, 402, 403, 429, 502, 503, 504] { expectFailure { _ = try AIClient.decode(envelope, status: code) } }
        let truncated = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "length"]]])
        expectFailure { _ = try AIClient.decode(truncated, status: 200) }
        expectFailure { _ = try AIClient.decode(Data("{\"choices\":[]}".utf8), status: 200) }
        expectFailure { _ = try SummaryParser.parse("{\"summary\":\" \"}") }
        for source in [String(repeating: "café 中文 🎙️", count: 80), "\n\na\n\nb\n", "abc\r\ndef\n", ""] {
            let chunks = AIClient.chunks(source, limit: 17)
            precondition(chunks.joined() == source)
            precondition(chunks.allSatisfy { !$0.isEmpty && $0.count <= 17 })
        }
        precondition(AIClient.chunks("x", limit: 0).isEmpty)
        var meeting = Meeting(); meeting.title = "Meeting · Today"
        meeting.apply(result, originalTitle: meeting.title)
        precondition(meeting.title == "Agenda planning" && meeting.actions.count == 1 && meeting.pipelineStatus == "ready")
        meeting.title = "My custom title"
        meeting.apply(result, originalTitle: "Meeting · Today")
        precondition(meeting.title == "My custom title")
        meeting.transcript = [TranscriptLine(seconds: 42, source: "Microphone", audioFile: "audio.m4a", text: "Keep these words.")]
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Archive(meetings: [meeting]))) as! [String: Any]
        var entries = legacy["meetings"] as! [[String: Any]]
        for field in ["transcribedFiles", "pipelineStatus", "pipelineError"] { entries[0].removeValue(forKey: field) }
        var transcript = entries[0]["transcript"] as! [[String: Any]]; transcript[0].removeValue(forKey: "audioFile")
        entries[0]["transcript"] = transcript; legacy["meetings"] = entries
        let restored = try JSONDecoder().decode(Archive.self, from: JSONSerialization.data(withJSONObject: legacy)).meetings[0]
        precondition(restored.title == "My custom title" && restored.transcript[0].text == "Keep these words.")
        precondition(restored.transcribedFiles == nil && restored.pipelineStatus == nil && restored.transcript[0].audioFile == nil)
        print("Minutes core checks passed: default request, response errors, Unicode chunks, safe titles, and older notes.")
    }
}
