import SwiftUI
import AppKit

/// Marks a `.syntaxMarker` range as hidden off the active paragraph. The
/// `NSLayoutManagerDelegate` glyph-nulling below (R6d) nulls the glyphs for
/// any character carrying this attribute -- true zero-width hiding done at
/// the TextKit layer, not a 0.01pt-font hack. Attribute-only: the marked
/// characters are still real characters in the string (files-are-truth).
extension NSAttributedString.Key {
    static let mdHidden = NSAttributedString.Key("noter.mdHidden")
}

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
    public final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?

        init(_ parent: MarkdownTextView) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit(textView.string)
            restyle()
        }

        /// Reveal follows the cursor: re-run the attribute-only restyle
        /// whenever the selection moves, so the active paragraph's markers
        /// un-hide and the previously-active paragraph's markers hide again.
        /// Safe to call unconditionally — `restyle()` never mutates the
        /// string, the selection, or the undo stack, so this cannot itself
        /// re-trigger selection-change (verified in
        /// MarkdownTextViewRestyleTests: attribute edits alone post no
        /// `NSTextView.didChangeSelectionNotification`).
        public func textViewDidChangeSelection(_ notification: Notification) {
            restyle()
        }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let theme = parent.theme

            // Opt this view into TextKit 1 compatibility mode: accessing
            // `.layoutManager` is the documented trigger (still verified
            // working on macOS 26) for a TextKit-2-default NSTextView to
            // migrate to an NSLayoutManager, which is required for the
            // shouldGenerateGlyphs delegate hook below to ever fire.
            // Idempotent and cheap once already opted in -- verified
            // empirically that repeat access re-fires no notification and
            // does no extra work -- so it's safe to call on every restyle().
            let layoutManager = textView.layoutManager
            if layoutManager?.delegate !== self {
                layoutManager?.delegate = self
            }
            // `backgroundLayoutEnabled` defaults to true, which per Apple's
            // docs means glyph generation/layout may be deferred to idle
            // run-loop time rather than happening immediately -- but that
            // idle work still runs on the main thread ("Background layout
            // occurs on the main thread when it is idle"), not a
            // background *thread*. Turning it off removes any ambiguity:
            // it makes layout for this view fully synchronous, so
            // `shouldGenerateGlyphs`/`setGlyphs` below -- which read
            // `NSTextStorage` and are not thread-safe -- are guaranteed to
            // run on the @MainActor this Coordinator is isolated to.
            layoutManager?.backgroundLayoutEnabled = false

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
            // Pass 2: syntax-marker glyphs, hide-vs-reveal by active paragraph
            // (R6c/R6d). On the paragraph the cursor/selection is in, dim
            // them (as before) so the raw glyphs stay visible and editable.
            // Off that paragraph, mark `.mdHidden` -- the
            // shouldGenerateGlyphs delegate below nulls those glyphs at the
            // TextKit layer, so no special font/color is needed here; the
            // pass-0 defaults above are fine, the glyph-null makes them
            // invisible regardless. Attribute-only: never touches the
            // string, selection, or undo stack.
            let activePara = SyntaxMarkerVisibility.activeParagraphRange(
                in: textView.string, selectedRange: textView.selectedRange())
            for span in spans where span.kind == .syntaxMarker {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                if SyntaxMarkerVisibility.isActive(span, activeParagraph: activePara) {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: span.range)
                } else {
                    storage.addAttribute(.mdHidden, value: true, range: span.range)
                    // A fence delimiter line (e.g. "```swift") is entirely
                    // .syntaxMarker -- the highlighter emits both .codeBlock
                    // and .syntaxMarker over the identical range only for
                    // those lines, never for a partial-line marker like a
                    // heading's "# ". Glyph-nulling zeroes such a line's
                    // WIDTH but TextKit still reserves a full line's HEIGHT
                    // for an all-null-glyph line (verified empirically: an
                    // 18pt line stays 18pt tall even fully nulled), so
                    // without this a hidden fence leaves a blank row rather
                    // than disappearing. Collapse the height too via
                    // NSParagraphStyle line-height clamping -- a documented,
                    // intentional TextKit lever, not a magic-font hack --
                    // reverted automatically once active because pass 0
                    // above resets every paragraph to `.default` on every
                    // restyle() call.
                    if spans.contains(where: { $0.kind == .codeBlock && $0.range == span.range }) {
                        let collapsedLine = NSMutableParagraphStyle()
                        collapsedLine.minimumLineHeight = 0.01
                        collapsedLine.maximumLineHeight = 0.01
                        storage.addAttribute(.paragraphStyle, value: collapsedLine, range: span.range)
                    }
                }
            }
            storage.endEditing()

            // The delegate only re-runs when glyphs actually regenerate,
            // which an attribute-only edit doesn't always guarantee. Force
            // it explicitly so the newly-active paragraph's markers get
            // their glyphs restored and the newly-inactive paragraph's get
            // nulled -- verified empirically this doesn't loop or flicker
            // (attribute edits alone post no selection/text-change
            // notification, so this can't re-enter restyle()).
            layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }

        // MARK: - NSLayoutManagerDelegate (glyph-nulling, R6d Part 1)

        /// Nulls the glyphs for characters marked `.mdHidden` so they render
        /// at zero width -- the robust, documented replacement for the old
        /// 0.01pt-font hack. Only fires once the text view is in TextKit 1
        /// compatibility mode (see the `.layoutManager` access in
        /// `restyle()`); `setGlyphs` is the only sanctioned way to apply
        /// modified properties here (per Apple's docs: "The only place apps
        /// are allowed to call this method directly is from [this delegate
        /// method]").
        public func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            var modified = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
            var anyHidden = false
            for i in 0..<glyphRange.length {
                let charIndex = charIndexes[i]
                guard charIndex < storage.length,
                      storage.attribute(.mdHidden, at: charIndex, effectiveRange: nil) != nil else { continue }
                modified[i].insert(.null)
                anyHidden = true
            }
            guard anyHidden else { return 0 }
            layoutManager.setGlyphs(glyphs, properties: modified, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return glyphRange.length
        }

        // MARK: - NSTextViewDelegate (caret-skip, R6d Part 2)

        /// Makes the caret glide across a hidden `.mdHidden` run in one
        /// press instead of pausing at every character inside it -- the
        /// hidden characters are still real characters in the string
        /// (glyph-nulling above only changes rendering), so without this
        /// hook the caret would still step through them one at a time. Pure
        /// decision logic lives in `CaretSkip` (unit-tested there); this
        /// just gathers the currently-hidden ranges and defers to it.
        /// Non-empty selections (drag/shift-click) pass through untouched.
        public func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
            toCharacterRange newSelectedCharRange: NSRange
        ) -> NSRange {
            guard newSelectedCharRange.length == 0, let storage = textView.textStorage else {
                return newSelectedCharRange
            }
            var hiddenRanges: [NSRange] = []
            storage.enumerateAttribute(.mdHidden, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                hiddenRanges.append(range)
            }
            let adjusted = CaretSkip.adjustedLocation(
                old: oldSelectedCharRange.location,
                proposed: newSelectedCharRange.location,
                hiddenRanges: hiddenRanges)
            return NSRange(location: adjusted, length: 0)
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
