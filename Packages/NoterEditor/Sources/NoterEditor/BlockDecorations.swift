import Foundation

/// Pure decision logic for R6e's block-decoration drawing pass: given the
/// spans `MarkdownHighlighter` produces, computes which character ranges
/// need a drawn decoration (blockquote left-bar / list bullet) and, for
/// list items, the full paragraph range the hanging indent must cover.
///
/// `MarkdownHighlighter.spans` carries no ordered-vs-unordered distinction
/// on `.listMarker` (both "- " and "1. " produce the same span kind) and no
/// full-paragraph range for list items (the span is just the 2-4 char
/// marker prefix) -- both are needed here but neither belongs in the
/// highlighter itself (it stays a pure lexer over spans; `.listMarker`'s 20
/// existing tests are untouched by this file). Factored out of
/// `MarkdownTextView.restyle()` -- NSTextView/NSTextStorage-bound and hard
/// to drive headlessly -- so this is unit-testable directly, mirroring
/// `SyntaxMarkerVisibility` and `CaretSkip`.
public enum BlockDecorations {
    /// One list item's marker, its full paragraph range (needed for the
    /// hanging indent -- wrapped continuation lines must align under the
    /// item's text, which requires the indent to cover the whole paragraph,
    /// not just the marker), and whether it's ordered ("1. ") or unordered
    /// ("- "/"* "/"+ "). Only unordered markers get hidden in favor of a
    /// drawn bullet; ordered numbers are meaningful and stay visible.
    ///
    /// `markerRange` is the bullet/number glyph plus its one trailing
    /// space only -- NOT the highlighter's raw `.listMarker` span, which
    /// (via `listRx`'s `^\s*`) also swallows any leading whitespace on a
    /// nested item. Hiding that whitespace too would glyph-null a nested
    /// item's only indentation signal, making `"  - nested"` render
    /// identically to a top-level `"- item"` off-active (found in
    /// codex-check review of this task's diff) -- so the leading
    /// whitespace is deliberately excluded here and left for Pass 0's
    /// normal styling to render at its real character width.
    /// `depth` is the item's nesting level, derived from the leading
    /// whitespace `listRx`'s `^\s*` captured ahead of the marker glyph: 2
    /// spaces OR 1 tab count as one level (`leadingSpaces / 2 +
    /// leadingTabs`, integer division). A top-level item (no leading
    /// whitespace) is depth 0. Consumed by `MarkdownTextView.restyle()` to
    /// scale both the paragraph's hanging indent and the drawn bullet's x
    /// position per nesting level, so deeper items visually step in.
    public struct ListItem: Equatable {
        public let markerRange: NSRange
        public let lineRange: NSRange
        public let isOrdered: Bool
        public let depth: Int

        public init(markerRange: NSRange, lineRange: NSRange, isOrdered: Bool, depth: Int) {
            self.markerRange = markerRange
            self.lineRange = lineRange
            self.isOrdered = isOrdered
            self.depth = depth
        }
    }

    /// One range per source line carrying a `.blockquote` span. Each is
    /// already whole-line (`MarkdownHighlighter` processes markdown line by
    /// line, emitting one `.blockquote` span per `> `-prefixed line), so no
    /// expansion is needed. Deliberately NOT merged across consecutive
    /// quote lines into one multi-line block -- each line gets its own
    /// drawn bar segment; whether stacked segments read as one continuous
    /// bar or show seams at a given corner radius is part of Gleb's visual
    /// gate, not decided here.
    public static func blockquoteLineRanges(spans: [MarkdownSpan]) -> [NSRange] {
        spans.filter { $0.kind == .blockquote }.map(\.range)
    }

    /// Every `.listMarker` span, classified ordered/unordered by inspecting
    /// the marker text itself (the span's own kind can't distinguish them)
    /// and expanded to its full paragraph range via the same
    /// `NSString.paragraphRange(for:)` call `SyntaxMarkerVisibility` uses
    /// for the active-paragraph check, so this stays consistent with the
    /// rest of the editor's paragraph-boundary handling (CRLF included).
    public static func listItems(spans: [MarkdownSpan], text: String) -> [ListItem] {
        let ns = text as NSString
        var items: [ListItem] = []
        for span in spans where span.kind == .listMarker {
            guard span.range.location >= 0, NSMaxRange(span.range) <= ns.length else { continue }
            let markerText = ns.substring(with: span.range)
            // listRx (`^\s*(?:[-*+]|\d+\.) `) guarantees the first
            // non-whitespace character is either a bullet glyph or the
            // first digit of an ordered number -- that single character is
            // enough to classify the whole marker.
            let isOrdered = markerText.first(where: { !$0.isWhitespace })?.isNumber ?? false
            // Strip the regex's optional leading `\s*` (nesting
            // indentation) from the range that gets hidden/bulleted -- see
            // `ListItem.markerRange`'s doc comment above.
            let leadingWhitespaceChars = markerText.prefix(while: { $0.isWhitespace })
            let leadingWhitespace = leadingWhitespaceChars.utf16.count
            let markerRange = NSRange(
                location: span.range.location + leadingWhitespace,
                length: span.range.length - leadingWhitespace)
            let lineRange = ns.paragraphRange(for: span.range)
            // Depth from the same leading-whitespace slice -- see
            // `ListItem.depth`'s doc comment above for the 2-spaces-or-1-tab
            // rule.
            let spaceCount = leadingWhitespaceChars.filter { $0 == " " }.count
            let tabCount = leadingWhitespaceChars.filter { $0 == "\t" }.count
            let depth = spaceCount / 2 + tabCount
            items.append(ListItem(markerRange: markerRange, lineRange: lineRange, isOrdered: isOrdered, depth: depth))
        }
        return items
    }
}
