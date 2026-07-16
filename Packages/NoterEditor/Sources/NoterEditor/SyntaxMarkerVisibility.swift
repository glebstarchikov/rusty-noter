import Foundation

/// Pure decision logic for R6c's hide/reveal-on-active-line mechanic: given
/// the current selection, which `.syntaxMarker` spans should render
/// revealed (dimmed, on the paragraph the cursor/selection is in) vs hidden
/// (near-zero font, off that paragraph). Factored out of
/// `MarkdownTextView.restyle()` — which is NSTextView/NSTextStorage-bound
/// and hard to drive in a headless test — so the caret/selection edge
/// cases (cursor on a heading line, multi-paragraph selection, cursor at a
/// paragraph boundary, etc.) can be unit-tested directly.
public enum SyntaxMarkerVisibility {
    /// The paragraph range containing `selectedRange`. Thin wrapper around
    /// `NSString.paragraphRange(for:)` — the exact call `restyle()` makes —
    /// so tests here exercise the identical logic used at runtime, not a
    /// reimplementation of it. For a multi-paragraph selection this extends
    /// to cover every paragraph the selection touches.
    public static func activeParagraphRange(in text: String, selectedRange: NSRange) -> NSRange {
        (text as NSString).paragraphRange(for: selectedRange)
    }

    /// True iff `span` should render revealed (dimmed, visible) rather than
    /// hidden (near-zero font) — i.e. its range intersects the active
    /// paragraph. Matches the brief's spec literally: a marker is "active"
    /// iff its range intersects `activePara`.
    public static func isActive(_ span: MarkdownSpan, activeParagraph: NSRange) -> Bool {
        NSIntersectionRange(span.range, activeParagraph).length > 0
    }
}
