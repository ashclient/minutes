import Foundation

// Convert presentation into native Notion blocks; never send Markdown as one quote.
enum NotionMarkdown {
    static func rich(_ text: String) -> [[String: Any]] {
        let pattern = #"\\\((.+?)\\\)|\$\$(.+?)\$\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return plainRich(text) }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        if matches.isEmpty { return plainRich(NoteMath.readable(text)) }
        var output: [[String: Any]] = []; var cursor = 0
        for match in matches {
            output += plainRich(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let expression = source.substring(with: range)
            if expression.count <= 1000 { output.append(["type": "equation", "equation": ["expression": expression]]) }
            else { output += plainRich(NoteMath.readable(expression)) }
            cursor = match.range.location + match.range.length
        }
        output += plainRich(source.substring(from: cursor)); return output
    }
    private static func plainRich(_ text: String) -> [[String: Any]] {
        guard let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return NotionClient.rich(text) }
        var result: [[String: Any]] = []
        for run in value.runs {
            let content = String(value[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let annotations: [String: Any] = ["bold": intent.contains(.stronglyEmphasized), "italic": intent.contains(.emphasized), "code": intent.contains(.code), "strikethrough": intent.contains(.strikethrough)]
            for var item in NotionClient.rich(content) {
                item["annotations"] = annotations
                if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { var t = item["text"] as! [String: Any]; t["link"] = ["url": link.absoluteString]; item["text"] = t }
                result.append(item)
            }
        }
        return result
    }
    static func blocks(_ markdown: String) -> [[String: Any]] {
        let lines = NoteMath.parts(markdown)
        var result: [[String: Any]] = [], code: [String] = []
        var fenced = false
        var indentation = 0
        var depths: [Int] = []
        func emit(_ block: [String: Any]) { result.append(block); depths.append(indentation) }
        func append(_ text: String, type: String = "paragraph", checked: Bool? = nil, literal: Bool = false) {
            let spans = literal ? NotionClient.rich(text) : rich(text)
            // Respect the rich_text array limit without discarding any text.
            let groups = stride(from: 0, to: max(1, spans.count), by: 80)
            for start in groups {
                var payload: [String: Any] = ["rich_text": Array(spans.dropFirst(start).prefix(80))]
                let kind = start == 0 ? type : "paragraph"
                if kind == "to_do" { payload["checked"] = checked ?? false }
                if kind == "code" { payload["language"] = "plain text" }
                emit(["object": "block", "type": kind, kind: payload])
            }
        }
        for part in lines {
            let raw = part.text
            indentation = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if part.equation && !fenced {
                if part.text.count <= 1000 { emit(["object": "block", "type": "equation", "equation": ["expression": part.text]]) }
                else { append(NoteMath.readable(part.text)) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { if fenced { append(code.joined(separator: "\n"), type: "code", literal: true); code = [] }; fenced.toggle(); continue }
            if fenced { code.append(raw); continue }
            if line.isEmpty { continue }
            if ["---", "***", "___"].contains(line) { emit(["object": "block", "type": "divider", "divider": [:]]); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") { append(String(line.dropFirst(hashes + 1)), type: "heading_" + String(min(hashes, 3))); continue }
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4, !line.dropFirst(2).dropLast(2).contains("**") { append(String(line.dropFirst(2).dropLast(2)), type: "heading_3"); continue }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { append(String(line.dropFirst(6)), type: "to_do", checked: !line.hasPrefix("- [ ]")); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { append(String(line.dropFirst(2)), type: "bulleted_list_item"); continue }
            if let match = line.range(of: "^[0-9]+[.)] +", options: .regularExpression) { append(String(line[match.upperBound...]), type: "numbered_list_item"); continue }
            if line.hasPrefix("> ") { append(String(line.dropFirst(2)), type: "quote"); continue }
            append(line)
        }
        if !code.isEmpty { append(code.joined(separator: "\n"), type: "code", literal: true) }
        return nested(result, depths: depths)
    }
    private static func nested(_ blocks: [[String: Any]], depths: [Int]) -> [[String: Any]] {
        var roots: [NotionListNode] = [], stack: [(Int, NotionListNode)] = []
        for (index, block) in blocks.enumerated() {
            let depth = depths[index]
            let node = NotionListNode(block)
            while let last = stack.last, last.0 >= depth { stack.removeLast() }
            if let parent = stack.last?.1, parent.children.count < 80 { parent.children.append(node) }
            else { roots.append(node) }
            let type = block["type"] as? String ?? ""
            if ["bulleted_list_item", "numbered_list_item", "to_do"].contains(type), stack.count < 2 { stack.append((depth, node)) }
            else if depth == 0 { stack = [] }
        }
        return roots.map { $0.object }
    }
}
private final class NotionListNode {
    let block: [String: Any]
    var children: [NotionListNode] = []
    init(_ block: [String: Any]) { self.block = block }
    var object: [String: Any] {
        var result = block
        if !children.isEmpty, let type = block["type"] as? String, var payload = block[type] as? [String: Any] {
            payload["children"] = children.map { $0.object }; result[type] = payload
        }
        return result
    }
}

