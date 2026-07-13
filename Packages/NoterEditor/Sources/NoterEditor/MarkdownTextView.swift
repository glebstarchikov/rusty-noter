import SwiftUI
import AppKit

/// Markdown source editor: NSTextView with attribute-only restyling on every
/// change. Attribute edits never move the selection or dirty the undo stack.
public struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let theme: EditorTheme
    var onEdit: (String) -> Void

    public init(text: Binding<String>, theme: EditorTheme, onEdit: @escaping (String) -> Void) {
        self._text = text
        self.theme = theme
        self.onEdit = onEdit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.bg

        let textView = MeasuredTextView()
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = theme.bodyFont
        textView.textColor = theme.fg
        textView.backgroundColor = theme.bg
        textView.insertionPointColor = theme.accent
        textView.delegate = context.coordinator
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.restyle()
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            // External reload path: replace wholesale, restyle, keep it undoable-free.
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, (text as NSString).length), length: 0)
            textView.setSelectedRange(clamped)
            context.coordinator.restyle()
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?

        init(_ parent: MarkdownTextView) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit(textView.string)
            restyle()
        }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let theme = parent.theme
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([
                .font: theme.bodyFont,
                .foregroundColor: theme.fg
            ], range: full)
            for span in MarkdownHighlighter.spans(in: textView.string) {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                switch span.kind {
                case .heading(let level):
                    storage.addAttribute(.font, value: theme.font(for: level), range: span.range)
                case .bold:
                    storage.addAttribute(.font, value: theme.boldFont, range: span.range)
                case .italic:
                    storage.addAttribute(.font, value: theme.italicFont, range: span.range)
                case .inlineCode, .codeBlock:
                    storage.addAttributes([
                        .font: theme.monoFont,
                        .foregroundColor: theme.secondary
                    ], range: span.range)
                case .link:
                    storage.addAttribute(.foregroundColor, value: theme.accent, range: span.range)
                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: span.range)
                case .blockquote:
                    storage.addAttribute(.foregroundColor, value: theme.secondary, range: span.range)
                }
            }
            storage.endEditing()
        }
    }
}

/// Caps the prose measure: content column max 680pt, centered (design.md ~62ch).
final class MeasuredTextView: NSTextView {
    override func layout() {
        let maxWidth: CGFloat = 680
        let horizontal = max((bounds.width - maxWidth) / 2, 40)
        textContainerInset = NSSize(width: horizontal, height: 40)
        super.layout()
    }
}
