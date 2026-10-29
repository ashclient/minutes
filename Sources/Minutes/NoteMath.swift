import Foundation

struct NotePart: Identifiable {
    let id: Int
    let text: String
    let equation: Bool
}
enum NoteMath {
    static func parts(_ markdown: String) -> [NotePart] {
        var result: [NotePart] = [], pending: [String] = []; var closing: String?
        func append(_ text: String, _ math: Bool) { result.append(NotePart(id: result.count, text: text, equation: math)) }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let delimiter = closing {
                if line == delimiter { if !pending.isEmpty { append(pending.joined(separator: "\n"), true) }; pending = []; closing = nil }
                else if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: "^[0-9]+[.)] +", options: .regularExpression) != nil {
                    if !pending.isEmpty { append(pending.joined(separator: "\n"), true) }
                    pending = []; closing = nil
                    if !line.isEmpty { append(raw, false) }
                } else { pending.append(raw) }; continue
            }
            if line == "]" || line == "\\]" { continue }
            if line == "$$" || line == "\\[" || line == "[" { closing = line == "$$" ? "$$" : line == "[" ? "]" : "\\]"; continue }
            if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 { append(String(line.dropFirst(2).dropLast(2)), true) }
            else if line.hasPrefix("\\["), line.hasSuffix("\\]"), line.count > 4 { append(String(line.dropFirst(2).dropLast(2)), true) }
            else if line.hasPrefix("\\frac") || line.hasPrefix("\\text{") || line.hasPrefix("\\sum") { append(line, true) }
            else { append(raw, false) }
        }
        // An incomplete streaming equation stays readable instead of disappearing.
        if !pending.isEmpty { append(pending.joined(separator: "\n"), true) }
        return result
    }
    static func readable(_ latex: String) -> String {
        var value = latex
        for _ in 0..<12 {
            let before = value
            value = value.replacingOccurrences(of: #"\\(?:text|mathrm|operatorname)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\\(?:dfrac|tfrac|frac)\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1) ÷ ($2)", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "√($1)", options: .regularExpression)
            if value == before { break }
        }
        for (a, b) in [("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\sum", "Σ"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"), ("\\alpha", "α"), ("\\beta", "β"), ("\\theta", "θ"), ("\\pi", "π"), ("\\left", ""), ("\\right", ""), ("\\$", "$"), ("\\%", "%"), ("\\,", " "), ("\\(", ""), ("\\)", "")] { value = value.replacingOccurrences(of: a, with: b) }
        for (a, b) in [("^2", "²"), ("^3", "³"), ("_{i}", "ᵢ"), ("_i", "ᵢ")] { value = value.replacingOccurrences(of: a, with: b) }
        return value
    }
}
