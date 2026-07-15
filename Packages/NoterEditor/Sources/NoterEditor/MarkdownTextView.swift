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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
                .foregroundColor: theme.fg,
                .backgroundColor: NSColor.clear,
                .paragraphStyle: NSParagraphStyle.default
            ], range: full)
            let spans = MarkdownHighlighter.spans(in: textView.string)
            // Pass 1: content spans (everything except syntaxMarker).
            for span in spans where span.kind != .syntaxMarker {
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
                        .foregroundColor: theme.secondary,
                        .backgroundColor: theme.codeBackground
                    ], range: span.range)
                case .link:
                    storage.addAttribute(.foregroundColor, value: theme.accent, range: span.range)
                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: span.range)
                case .blockquote:
                    let quoteStyle = NSMutableParagraphStyle()
                    quoteStyle.firstLineHeadIndent = 16
                    quoteStyle.headIndent = 16
                    storage.addAttributes([
                        .foregroundColor: theme.secondary,
                        .paragraphStyle: quoteStyle
                    ], range: span.range)
                case .syntaxMarker:
                    break // handled in pass 2, after content so faint wins
                }
            }
            // Pass 2: syntax-marker glyphs on top, so faint overrides the
            // content color pass 1 just applied on the same range.
            for span in spans where span.kind == .syntaxMarker {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: theme.faint, range: span.range)
            }
            storage.endEditing()
        }
    }
}

/// Caps the prose measure (content column max 680pt, design.md ~62ch) and
/// left-aligns it to the 48pt title margin. Previously the column was centered,
/// which pushed the body right of the left-aligned title. `textContainerInset`
/// is symmetric so it can't produce asymmetric margins; instead we fix the
/// container width and override `textContainerOrigin` to pin the left edge.
final class MeasuredTextView: NSTextView {
    private let leftInset: CGFloat = 48
    private let topInset: CGFloat = 40
    private let maxWidth: CGFloat = 680

    override var textContainerOrigin: NSPoint {
        NSPoint(x: leftInset, y: topInset)
    }

    override func layout() {
        textContainerInset = NSSize(width: 0, height: topInset)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        // Cap the measure at 680pt, but never wider than the space left of the
        // 48pt margin (mirrored on the right), so a narrow editor never clips.
        let available = max(bounds.width - leftInset * 2, 0)
        textContainer?.size = NSSize(width: min(maxWidth, available),
                                     height: .greatestFiniteMagnitude)
        super.layout()
    }
}
