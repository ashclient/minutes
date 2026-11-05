import SwiftUI
import AppKit

// The stored format remains Markdown, so typed notes use the same Notion export
// path as generated notes. Editing uses attributed text rather than a second,
// independently positioned SwiftUI placeholder.
enum NotesEditorFormat {
    static let heading = NSAttributedString.Key("MinutesHeading")
    static let code = NSAttributedString.Key("MinutesCode")
    static let bodySize: CGFloat = 16
    static var paragraph: NSParagraphStyle {
        let value = NSMutableParagraphStyle(); value.lineSpacing = 4; value.paragraphSpacing = 7
        return value
    }
    static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
            var line = original
            var level = 0
            if let match = line.range(of: "^#{1,3} +", options: .regularExpression) {
                level = line[match].filter { $0 == "#" }.count; line.removeSubrange(match)
            }
            if let range = line.range(of: "^(\\s*)[-*] ", options: .regularExpression) {
                line.replaceSubrange(range, with: String(line[range].prefix(while: { $0.isWhitespace })) + "• ")
            }
            let part = NSMutableAttributedString(string: line, attributes: attributes)
            // Strip only paired inline markers. Unmatched syntax and formulas
            // remain literal, so partially written notes never lose characters.
            for (pattern, trait) in [("\\*\\*(.+?)\\*\\*", "bold"), ("(?<!\\*)\\*([^*]+)\\*(?!\\*)", "italic"), ("`([^`]+)`", "code")] {
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: part.string, range: NSRange(location: 0, length: part.length)).reversed() {
                    let content = part.attributedSubstring(from: match.range(at: 1)).mutableCopy() as! NSMutableAttributedString
                    let all = NSRange(location: 0, length: content.length)
                    if trait == "code" { content.addAttributes([code: true, .font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)], range: all) }
                    else {
                        content.enumerateAttribute(.font, in: all) { font, range, _ in
                            let base = font as? NSFont ?? NSFont.systemFont(ofSize: bodySize)
                            content.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: trait == "bold" ? .boldFontMask : .italicFontMask), range: range)
                        }
                    }
                    part.replaceCharacters(in: match.range, with: content)
                }
            }
            if level > 0 {
                part.addAttributes([heading: level, .font: NSFont.systemFont(ofSize: level == 1 ? 26 : level == 2 ? 22 : 18, weight: .semibold)], range: NSRange(location: 0, length: part.length))
            }
            result.append(part)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        return result
    }
    static func markdown(_ value: NSAttributedString) -> String {
        let text = value.string as NSString
        var lines: [String] = [], start = 0
        while start < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
            var end = NSMaxRange(paragraph)
            while end > start && [10, 13].contains(Int(text.character(at: end - 1))) { end -= 1 }
            let range = NSRange(location: start, length: end - start)
            let level = range.length > 0 ? (value.attribute(heading, at: start, effectiveRange: nil) as? Int ?? 0) : 0
            var contentRange = range
            var line = ""
            let plain = text.substring(with: range)
            if let bullet = plain.range(of: "^(\\s*)• ", options: .regularExpression) {
                let prefix = String(plain[bullet])
                line = String(prefix.prefix(while: { $0.isWhitespace })) + "- "
                contentRange.location += prefix.utf16.count; contentRange.length -= prefix.utf16.count
            }
            var open = ""
            value.enumerateAttributes(in: contentRange) { attrs, run, _ in
                let raw = text.substring(with: run)
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: bodySize)
                let traits = NSFontManager.shared.traits(of: font)
                let marker = level > 0 ? "" : attrs[code] as? Bool == true ? "`" : (traits.contains(.boldFontMask) ? "**" : "") + (traits.contains(.italicFontMask) ? "*" : "")
                if marker != open { line += String(open.reversed()) + marker; open = marker }
                line += raw
            }
            line += String(open.reversed())
            if level > 0 { line = String(repeating: "#", count: min(3, level)) + " " + line }
            lines.append(line); start = NSMaxRange(paragraph)
        }
        if text.length > 0 && text.character(at: text.length - 1) == 10 { lines.append("") }
        return lines.joined(separator: "\n")
    }
}

@MainActor final class NotesTextView: NSTextView, NSPopoverDelegate {
    var placeholder = "Write notes, press Space for AI, or / for formatting…"
    var heightChanged: ((CGFloat) -> Void)?
    var showFormatting: (() -> Void)?
    var aiMeeting: Meeting?
    var aiBusy = false
    private var aiPanel: NSPopover?
    func openAITools() {
        guard aiPanel == nil, let window, isEditable else { return }
        let range = selectedRange()
        let request = NotesAISelection(editor: self, range: range)
        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.delegate = self
        let host = NSHostingController(rootView: InlineNotesTools(request: request, meeting: aiMeeting, appleBusy: aiBusy) { [weak panel] in panel?.performClose(nil) })
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        let screen = firstRect(forCharacterRange: request.range, actualRange: nil)
        let anchor = convert(window.convertFromScreen(screen), from: nil).intersection(visibleRect)
        aiPanel = panel
        panel.show(relativeTo: anchor.isEmpty ? NSRect(x: visibleRect.minX + 8, y: visibleRect.minY + 8, width: 1, height: 20) : anchor, of: self, preferredEdge: .maxY)
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview-editor-ai") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
                let report: [String: Any] = ["shown": panel?.isShown ?? false, "width": panel?.contentSize.width ?? 0, "height": panel?.contentSize.height ?? 0, "selection": request.range.length]
                if let data = try? JSONSerialization.data(withJSONObject: report) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/Minutes-inline-check.json"))
                }
            }
        }
    }
    func closeAITools() { aiPanel?.performClose(nil); aiPanel = nil }
    func popoverDidClose(_ notification: Notification) { aiPanel = nil }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRange().length > 0 { openAITools() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            var attrs = typingAttributes; attrs[.foregroundColor] = NSColor.placeholderTextColor
            // Draw with TextKit too: NSString.draw uses different leading,
            // which can place its baseline below an empty NSTextView caret.
            let storage = NSTextStorage(string: placeholder, attributes: attrs)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: textContainer?.containerSize ?? bounds.size)
            container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 5
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: textContainerOrigin)
        }
    }
    override func layout() { super.layout(); measure() }
    func measure() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        heightChanged?(ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2 + 16))
        needsDisplay = true
    }
    private func preserveFormattingUndo() {
        guard let storage = textStorage else { return }
        let original = NSAttributedString(attributedString: storage), selection = selectedRange()
        undoManager?.registerUndo(withTarget: self) { view in
            view.preserveFormattingUndo()
            view.textStorage?.setAttributedString(original)
            view.setSelectedRange(NSRange(location: min(selection.location, original.length), length: min(selection.length, max(0, original.length - selection.location))))
            view.didChangeText(); view.measure()
        }
        undoManager?.setActionName("Format notes")
    }
    func setHeading(_ level: Int) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: level == 0 ? 16 : level == 1 ? 26 : level == 2 ? 22 : 18, weight: level == 0 ? .regular : .semibold), NotesEditorFormat.heading: level]
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) { preserveFormattingUndo(); textStorage?.addAttributes(attrs, range: range); didChangeText() }
        typingAttributes = NotesEditorFormat.attributes.merging(attrs) { _, new in new }
        window?.makeFirstResponder(self); measure()
    }
    func toggleTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let font = (range.length > 0 ? textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : typingAttributes[.font]) as? NSFont ?? NSFont.systemFont(ofSize: 16)
        let removing = NSFontManager.shared.traits(of: font).contains(trait)
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            preserveFormattingUndo()
            textStorage?.enumerateAttribute(.font, in: range) { value, run, _ in
                let base = value as? NSFont ?? font
                textStorage?.addAttribute(.font, value: removing ? NSFontManager.shared.convert(base, toNotHaveTrait: trait) : NSFontManager.shared.convert(base, toHaveTrait: trait), range: run)
            }
            didChangeText()
        } else { typingAttributes[.font] = removing ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait) }
        window?.makeFirstResponder(self)
    }
    func toggleList() {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let text = (string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")
        let remove = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("• ") }
        guard let storage = textStorage else { return }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var offsets: [Int] = [], offset = 0
        for (index, line) in lines.enumerated() {
            if !(line.isEmpty && index == lines.count - 1 && lines.count > 1) { offsets.append(offset) }
            offset += line.utf16.count + 1
        }
        for location in offsets.reversed() {
            if remove { replacement.deleteCharacters(in: NSRange(location: location, length: 2)) }
            else { replacement.insert(NSAttributedString(string: "• ", attributes: NotesEditorFormat.attributes), at: location) }
        }
        insertText(replacement, replacementRange: range); window?.makeFirstResponder(self)

    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "b" { toggleTrait(.boldFontMask); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "i" { toggleTrait(.italicFontMask); return }
        if event.characters == " ", !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
           !hasMarkedText(), NotesAISelection.blankLine(string, range: selectedRange()) {
            openAITools(); return
        }
        // Slash is a discoverable formatting shortcut only at an empty line.
        if event.characters == "/", (string as NSString).substring(with: (string as NSString).paragraphRange(for: selectedRange())).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showFormatting?(); return }
        super.keyDown(with: event)
    }
    override func insertNewline(_ sender: Any?) {
        let line = (string as NSString).substring(with: (string as NSString).paragraphRange(for: selectedRange())).trimmingCharacters(in: .newlines)
        super.insertNewline(sender)
        typingAttributes = NotesEditorFormat.attributes
        if line.hasPrefix("• ") && line.count > 2 { insertText("• ", replacementRange: selectedRange()) }
    }
    override func paste(_ sender: Any?) {
        // External HTML/RTF carries fonts and colors that clash with the page.
        // Plain Markdown is interpreted using the editor's own style instead.
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(NotesEditorFormat.attributed(text), replacementRange: selectedRange())
    }
}

struct NotesEditor: View {
    @Binding var text: String
    var minimumHeight: CGFloat = 180
    var meeting: Meeting? = nil
    var aiBusy = false
    @State private var contentHeight: CGFloat = 180
    @State private var editor: NotesTextView?
    @State private var formatting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Menu("Text") { Button("Text") { editor?.setHeading(0) }; Button("Heading 1") { editor?.setHeading(1) }; Button("Heading 2") { editor?.setHeading(2) }; Button("Heading 3") { editor?.setHeading(3) } }
                    .menuStyle(.borderlessButton).frame(width: 68)
                Button { editor?.toggleTrait(.boldFontMask) } label: { Image(systemName: "bold") }.help("Bold (⌘B)")
                Button { editor?.toggleTrait(.italicFontMask) } label: { Image(systemName: "italic") }.help("Italic (⌘I)")
                Button { editor?.openAITools() } label: { Label("Ask AI", systemImage: "text.bubble") }.help("Write or edit with AI")
                Button { editor?.toggleList() } label: { Image(systemName: "list.bullet") }.help("Bulleted list")
            }.buttonStyle(QuietButtonStyle()).font(.system(size: 13)).foregroundStyle(.secondary)
            NativeNotesEditor(text: $text, height: $contentHeight, editor: $editor, formatting: $formatting, meeting: meeting, aiBusy: aiBusy)
                .frame(height: max(minimumHeight, contentHeight))
                .popover(isPresented: $formatting, arrowEdge: .top) {
                    VStack(alignment: .leading) {
                        ForEach(0..<4) { level in Button(level == 0 ? "Text" : "Heading \(level)") { editor?.setHeading(level); formatting = false } }
                        Button("Bulleted list") { editor?.toggleList(); formatting = false }
                    }.buttonStyle(QuietButtonStyle()).padding(10)
                }
        }
    }
}
private struct NativeNotesEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var editor: NotesTextView?
    @Binding var formatting: Bool
    var meeting: Meeting?
    var aiBusy: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        view.isRichText = true; view.importsGraphics = false; view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.font = NSFont.systemFont(ofSize: NotesEditorFormat.bodySize)
        view.allowsUndo = true
        view.textStorage?.setAttributedString(NotesEditorFormat.attributed(text))
        if text.isEmpty { view.typingAttributes = NotesEditorFormat.attributes }
        view.delegate = context.coordinator
        view.heightChanged = { value in DispatchQueue.main.async { if abs(height - value) > 1 { height = value } } }
        view.showFormatting = { formatting = true }
        view.aiMeeting = meeting; view.aiBusy = aiBusy
        scroll.documentView = view
        context.coordinator.lastMarkdown = text
        DispatchQueue.main.async {
            editor = view; view.measure()
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview-editor-ai") }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: 0, length: ProcessInfo.processInfo.arguments.contains("--preview-editor-ai-blank") ? 0 : min(42, view.string.utf16.count)))
                    view.openAITools()
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-editor-empty") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.window?.makeFirstResponder(view) }
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NotesTextView else { return }
        view.aiMeeting = meeting; view.aiBusy = aiBusy
        if text != context.coordinator.lastMarkdown {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(NotesEditorFormat.attributed(text))
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            context.coordinator.lastMarkdown = text
            if text.isEmpty { view.typingAttributes = NotesEditorFormat.attributes }
        }
        view.measure()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NotesTextView else { return }
        view.closeAITools(); view.aiMeeting = nil
        view.delegate = nil; view.heightChanged = nil; view.showFormatting = nil
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeNotesEditor
        var lastMarkdown = ""
        init(_ parent: NativeNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NotesTextView, let storage = view.textStorage else { return }
            let markdown = NotesEditorFormat.markdown(storage)
            lastMarkdown = markdown; parent.text = markdown; view.measure()
        }
    }
}
