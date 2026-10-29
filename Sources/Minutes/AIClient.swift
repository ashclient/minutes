import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AIClient: Sendable {
    static let defaultModel = "openrouter/free"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    let apiKey: String
    var session: URLSession = .shared

    static func request(key: String, system: String, text: String) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Add your OpenRouter key to finish these notes.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Minutes", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": defaultModel, "stream": false, "max_tokens": 8192,
            "response_format": ["type": "json_object"],
            "provider": ["require_parameters": true],
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func decode(_ data: Data, status: Int) throws -> SummaryResult {
        guard status == 200 else {
            switch status {
            case 401, 403: throw AppFailure("OpenRouter rejected this key or request. Check the key and your account’s provider/privacy settings.")
            case 402: throw AppFailure("OpenRouter blocked this request because of account credit limits. Minutes only requests the free router; check your OpenRouter account.")
            case 429: throw AppFailure("OpenRouter’s free usage limit was reached. Your transcript is saved. Try again after your limit resets.")
            case 408, 502, 503, 504: throw AppFailure("No free model is available right now. Your transcript is saved; try again shortly.")
            default: throw AppFailure("OpenRouter returned HTTP \(status). Your recording and transcript are saved.")
            }
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]?
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AppFailure("OpenRouter returned an unreadable response. Retry; your transcript is saved.") }
        guard let choice = response.choices?.first, let content = choice.message.content, !content.isEmpty else { throw AppFailure("The free model returned no notes. Try again; your transcript is saved.") }
        guard choice.finish_reason != "length" else { throw AppFailure("The model’s answer was cut short. Try again; your current notes have not been replaced.") }
        return try SummaryParser.parse(content)
    }
    private func generate(system: String, text: String) async throws -> SummaryResult {
        let request = try Self.request(key: apiKey, system: system, text: text)
        // Retry a transient server or rate-limit response once, honoring a bounded Retry-After. Never retry auth failures.
        for attempt in 0...1 {
            try Task.checkCancellation()
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch { if Task.isCancelled { throw CancellationError() }; throw AppFailure("Could not reach OpenRouter. Check your connection, then retry. Your transcript is saved.") }
            guard let http = response as? HTTPURLResponse else { throw AppFailure("No response from OpenRouter.") }
            if attempt == 0, [429, 502, 503, 504].contains(http.statusCode) {
                let delay = min(30, max(2, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (http.statusCode == 429 ? 5 : 2)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); continue
            }
            return try Self.decode(data, status: http.statusCode)
        }
        throw AppFailure("OpenRouter is unavailable. Try again shortly.")
    }
    static func chunks(_ text: String, limit: Int = 10000) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        var chunks: [String] = []; var rest = text[...]
        while rest.count > limit {
            let end = rest.index(rest.startIndex, offsetBy: limit)
            // Prefer a paragraph boundary; keep every character, including whitespace.
            let candidate = rest[..<end]
            let boundary = candidate.lastIndex(of: "\n").map { rest.index(after: $0) } ?? end
            let split = boundary == rest.startIndex ? end : boundary
            chunks.append(String(rest[..<split])); rest = rest[split...]
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        return chunks
    }
    func summarize(_ source: String, length: NotesLength = .complete, format: StudyFormat = .outline, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void) async throws -> SummaryResult {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("No speech was found. You can listen to the saved recording.") }
        let system = NotesLength.basePrompt + "\n" + length.instruction + "\n" + format.instruction
        // Each worker drafts then verifies its own section; a slow draft no longer
        // blocks reviews of every other section. Bound total network requests to four.
        let parts = Self.chunks(source, limit: 18000)
        await progress("Writing and checking your notes…")
        let reviewed = try await OrderedBatch.map(Array(parts.enumerated()), concurrency: 4, progress: fraction) { item in
            let section = try await generate(system: system, text: "<source section=\"\(item.offset + 1)\" total=\"\(parts.count)\">\n\(item.element)\n</source>")
            let previous = item.offset > 0 ? String(parts[item.offset - 1].suffix(2000)) : ""
            let draft = try JSONEncoder().encode(section)
            return try await generate(system: system + "\n" + NotesLength.reviewPrompt,
                text: "PREVIOUS SECTION (context only, do not repeat):\n" + previous + "\nORIGINAL SOURCE FOR THIS SECTION:\n" + item.element + "\nDRAFT TO CHECK:\n" + String(decoding: draft, as: UTF8.self))
        }
        let combined = NotesLength.combine(reviewed)
        guard length != .complete else { return combined }
        let final = try await generate(system: system + "\nConsolidate these extracts for the ENTIRE lecture. The selected length instruction takes priority over the detail retained in the extracts. Apply its whole-document requirements; Auto should be concise and selective. Merge synonymous topics and remove duplication across sections. No invented assignments or examples.", text: combined.summary)
        return SummaryResult(title: combined.title, summary: StudyBudget.limit(final.summary, words: StudyBudget.maximum(length)), decisions: final.decisions, actions: final.actions)
    }
}
