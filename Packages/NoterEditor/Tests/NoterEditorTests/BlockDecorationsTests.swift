import Testing
import Foundation
@testable import NoterEditor

/// Tests for the pure "which char ranges are blockquote/bullet lines given
/// spans" logic (R6e). `range(of:in:)` comes from MarkdownHighlighterTests.swift
/// (same target). Mirrors `SyntaxMarkerVisibilityTests`/`CaretSkipTests` in
/// spirit: exercise the pure decision logic directly, driven by real
/// `MarkdownHighlighter.spans(in:)` output wherever possible so these tests
/// don't drift from what the highlighter actually emits.
@Suite struct BlockDecorationsTests {
    // MARK: - blockquoteLineRanges

    @Test func blockquoteLineRangesReturnsOneRangePerBlockquoteSpan() {
        let text = "> line one\n> line two\nnot a quote\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let ranges = BlockDecorations.blockquoteLineRanges(spans: spans)
        #expect(ranges == [range(of: "> line one", in: text), range(of: "> line two", in: text)],
                "one range per source quote line, no merging across lines -- each is drawn independently")
    }

    @Test func blockquoteLineRangesEmptyWhenNoBlockquote() {
        let text = "Some plain text.\n- a list item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(BlockDecorations.blockquoteLineRanges(spans: spans) == [])
    }

    // MARK: - listItems: ordered vs. unordered classification

    @Test func dashMarkerIsUnordered() {
        let text = "- item one\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].isOrdered == false)
    }

    @Test func asteriskAndPlusMarkersAreUnordered() {
        let text = "* item one\n+ item two\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.isOrdered == false })
    }

    @Test func numberedMarkerIsOrdered() {
        let text = "1. item one\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].isOrdered == true)
    }

    @Test func multiDigitNumberedMarkerIsOrdered() {
        let text = "10. tenth item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].isOrdered == true)
    }

    @Test func indentedNestedDashMarkerIsStillUnordered() {
        // listRx (`^\s*(?:[-*+]|\d+\.) `) allows leading whitespace for
        // nested items -- classification must still key off the
        // bullet/number character, not the leading whitespace.
        let text = "  - nested item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].isOrdered == false)
        #expect(items[0].markerRange == range(of: "- ", in: text))
        #expect(items[0].depth == 1, "2 leading spaces == one nesting level")
    }

    @Test func fourSpaceIndentedDashMarkerIsDepthTwo() {
        // 2 spaces == one level, so 4 spaces == two levels -- a
        // double-nested item.
        let text = "    - double nested item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].isOrdered == false)
        #expect(items[0].markerRange == range(of: "- ", in: text))
        #expect(items[0].depth == 2)
    }

    @Test func nestedMarkerRangeExcludesLeadingWhitespaceUnlikeTheRawHighlighterSpan() {
        // codex-check (this task): the raw `.listMarker` span DOES include
        // the leading "  " (that's how the highlighter's own regex is
        // written), but `BlockDecorations.markerRange` must NOT -- hiding
        // that whitespace too would glyph-null a nested item's only
        // indentation signal, making it render identical to a top-level
        // item off-active. This is the one place `markerRange` diverges
        // from a straight passthrough of the highlighter's span range.
        let text = "  - nested item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let listMarkerSpan = spans.first { $0.kind == .listMarker }!
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(listMarkerSpan.range == range(of: "  - ", in: text), "sanity: the raw span really does include the leading whitespace")
        #expect(items[0].markerRange == range(of: "- ", in: text), "BlockDecorations' marker range must exclude it")
        #expect(items[0].markerRange != listMarkerSpan.range)
    }

    @Test func mixedOrderedAndUnorderedClassifiedIndependently() {
        let text = "- unordered\n1. ordered\n* also unordered\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.map(\.isOrdered) == [false, true, false])
    }

    // MARK: - listItems: marker range passthrough (no leading whitespace to strip)

    @Test func markerRangeMatchesTheHighlighterListMarkerSpanExactlyWhenNotIndented() {
        // Top-level (non-nested) items have no leading whitespace for
        // listRx's `^\s*` to match, so there's nothing to strip -- marker
        // range and the raw span range coincide exactly in this case.
        let text = "- item one\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let listMarkerSpan = spans.first { $0.kind == .listMarker }!
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items[0].markerRange == listMarkerSpan.range)
    }

    // MARK: - listItems: full paragraph line range (for the hanging indent)

    @Test func lineRangeCoversTheWholeLineNotJustTheMarker() {
        let text = "- a longer item that would wrap onto a second visual line\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        let expectedLine = (text as NSString).paragraphRange(for: range(of: "- ", in: text))
        #expect(items[0].lineRange == expectedLine)
        #expect(items[0].lineRange.length > items[0].markerRange.length,
                "the indent must cover the full paragraph so wrapped continuation lines align, not just the 2-4 char marker")
    }

    @Test func lineRangeForLastLineWithNoTrailingNewlineStaysInBounds() {
        let text = "- last line, no trailing newline"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(NSMaxRange(items[0].lineRange) == (text as NSString).length)
    }

    // MARK: - listItems: multiple items, ordering, and non-list content

    @Test func multipleListItemsReturnedInDocumentOrder() {
        let text = "- one\n- two\n- three\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        let markerStarts = items.map(\.markerRange.location)
        #expect(markerStarts == markerStarts.sorted(), "items must come back in document order")
        #expect(items.map(\.markerRange) == [range(of: "- one", in: text).prefix(2),
                                             range(of: "- two", in: text).prefix(2),
                                             range(of: "- three", in: text).prefix(2)])
    }

    @Test func blockquoteLinesDoNotAppearAsListItems() {
        let text = "> quoted\n- item\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 1)
        #expect(items[0].markerRange == range(of: "- ", in: text))
    }

    @Test func nonListSpansAreIgnored() {
        let text = "# Heading\n\nSome **bold** text.\n"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(BlockDecorations.listItems(spans: spans, text: text) == [])
    }

    // MARK: - listItems: CRLF parity (codebase convention: always test this explicitly)

    @Test func crlfLineEndingsStillProduceACorrectFullLineRange() {
        let text = "- item one\r\n- item two\r\n"
        let spans = MarkdownHighlighter.spans(in: text)
        let items = BlockDecorations.listItems(spans: spans, text: text)
        #expect(items.count == 2)
        for item in items {
            #expect((text as NSString).substring(with: item.lineRange).hasSuffix("\r\n"))
        }
    }

    // MARK: - listItems: defensive bounds guard

    @Test func outOfBoundsSpanIsSkippedRatherThanCrashing() {
        let text = "- item\n"
        let bogus = MarkdownSpan(range: NSRange(location: 100, length: 3), kind: .listMarker)
        let items = BlockDecorations.listItems(spans: [bogus], text: text)
        #expect(items == [])
    }
}
