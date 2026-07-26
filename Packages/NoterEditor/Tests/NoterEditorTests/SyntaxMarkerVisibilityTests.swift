import Testing
import Foundation
@testable import NoterEditor

/// Tests for the pure "which markers are active given selection" logic
/// (R6c). `range(of:in:)` and `NSRange.prefix/suffix` come from
/// MarkdownHighlighterTests.swift (same target).
@Suite struct SyntaxMarkerVisibilityTests {
    @Test func cursorOnHeadingLineActivatesItsMarker() {
        let text = "# Title\n\nBody paragraph.\n"
        let headingMarker = MarkdownSpan(range: range(of: "# ", in: text), kind: .syntaxMarker)
        let caret = NSRange(location: 3, length: 0) // inside "Title"
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
        #expect(SyntaxMarkerVisibility.isActive(headingMarker, activeParagraph: activePara))
    }

    @Test func cursorOnAnotherParagraphHidesHeadingMarker() {
        let text = "# Title\n\nBody paragraph.\n"
        let headingMarker = MarkdownSpan(range: range(of: "# ", in: text), kind: .syntaxMarker)
        let caret = NSRange(location: range(of: "Body paragraph.", in: text).location + 2, length: 0)
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
        #expect(!SyntaxMarkerVisibility.isActive(headingMarker, activeParagraph: activePara))
    }

    @Test func caretAtEveryOffsetInSingleParagraphKeepsItsMarkersActive() {
        // Arrow-key surrogate: sweep the caret across every offset in a
        // one-paragraph document (including *inside* the marker glyphs
        // themselves) and confirm the paragraph's own markers never
        // flicker hidden mid-line. Stops before the trailing "\n" — a
        // caret placed just past it sits in the (empty) phantom paragraph
        // that follows a trailing newline, a separate, deliberately
        // untested edge case.
        let text = "Some **bold** text."
        let boldMarkers = [
            MarkdownSpan(range: range(of: "**bold**", in: text).prefix(2), kind: .syntaxMarker),
            MarkdownSpan(range: range(of: "**bold**", in: text).suffix(2), kind: .syntaxMarker)
        ]
        let length = (text as NSString).length
        for offset in 0..<length {
            let caret = NSRange(location: offset, length: 0)
            let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
            for marker in boldMarkers {
                #expect(SyntaxMarkerVisibility.isActive(marker, activeParagraph: activePara),
                        "offset \(offset) should keep bold markers active in a single-paragraph doc")
            }
        }
    }

    @Test func multiParagraphSelectionActivatesMarkersInEveryTouchedParagraph() {
        let text = "# One\n\n# Two\n\n# Three\n"
        let markerOne = MarkdownSpan(range: range(of: "# ", in: text), kind: .syntaxMarker)
        let twoRange = range(of: "# Two", in: text)
        let markerTwo = MarkdownSpan(range: NSRange(location: twoRange.location, length: 2), kind: .syntaxMarker)
        let threeRange = range(of: "# Three", in: text)
        let markerThree = MarkdownSpan(range: NSRange(location: threeRange.location, length: 2), kind: .syntaxMarker)

        // Selection spans from inside "One" through inside "Two" -- touches two paragraphs, not three.
        let selection = NSRange(location: 2, length: twoRange.location + 3 - 2)
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: selection)
        #expect(SyntaxMarkerVisibility.isActive(markerOne, activeParagraph: activePara))
        #expect(SyntaxMarkerVisibility.isActive(markerTwo, activeParagraph: activePara))
        #expect(!SyntaxMarkerVisibility.isActive(markerThree, activeParagraph: activePara))
    }

    @Test func caretAtStartOfNewParagraphActivatesTheNewOneNotThePrevious() {
        let text = "# One\n\n# Two\n"
        let markerOne = MarkdownSpan(range: range(of: "# ", in: text), kind: .syntaxMarker)
        let twoMarkerRange = NSRange(location: range(of: "# Two", in: text).location, length: 2)
        let markerTwo = MarkdownSpan(range: twoMarkerRange, kind: .syntaxMarker)

        // Caret exactly at the first character of paragraph two (right after the blank line).
        let caret = NSRange(location: twoMarkerRange.location, length: 0)
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
        #expect(!SyntaxMarkerVisibility.isActive(markerOne, activeParagraph: activePara))
        #expect(SyntaxMarkerVisibility.isActive(markerTwo, activeParagraph: activePara))
    }

    @Test func adjacentTouchingMarkerJustPastParagraphBoundaryIsNotActive() {
        // Boundary sanity: a marker that starts exactly at the active
        // paragraph's end (zero-length intersection) does not count as
        // active. Documents NSIntersectionRange's "touching but not
        // overlapping" semantics for this decision.
        let activePara = NSRange(location: 0, length: 5)
        let touchingMarker = MarkdownSpan(range: NSRange(location: 5, length: 2), kind: .syntaxMarker)
        #expect(!SyntaxMarkerVisibility.isActive(touchingMarker, activeParagraph: activePara))
    }

    @Test func markerFullyBeforeOrAfterActiveParagraphIsNotActive() {
        let activePara = NSRange(location: 10, length: 5)
        let before = MarkdownSpan(range: NSRange(location: 0, length: 3), kind: .syntaxMarker)
        let after = MarkdownSpan(range: NSRange(location: 20, length: 3), kind: .syntaxMarker)
        #expect(!SyntaxMarkerVisibility.isActive(before, activeParagraph: activePara))
        #expect(!SyntaxMarkerVisibility.isActive(after, activeParagraph: activePara))
    }

    @Test func crlfLineEndingsStillResolveTheCorrectActiveParagraph() {
        // Mirrors the highlighter's own CRLF paranoia (notes may arrive
        // with Windows line endings) -- the paragraph-range wrapper is a
        // thin pass-through to NSString, but confirm it holds here too.
        let text = "# One\r\n\r\n# Two\r\n"
        let markerOne = MarkdownSpan(range: range(of: "# ", in: text), kind: .syntaxMarker)
        let twoRange = range(of: "# Two", in: text)
        let markerTwo = MarkdownSpan(range: NSRange(location: twoRange.location, length: 2), kind: .syntaxMarker)
        let caret = NSRange(location: twoRange.location + 3, length: 0)
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
        #expect(!SyntaxMarkerVisibility.isActive(markerOne, activeParagraph: activePara))
        #expect(SyntaxMarkerVisibility.isActive(markerTwo, activeParagraph: activePara))
    }

    @Test func realisticRichNoteOnlyActivatesMarkersOnTheCursorParagraph() {
        // Cross-checks the pure logic against real MarkdownHighlighter
        // output (not hand-built spans) for a note shaped like the smoke
        // test's rich note: heading, bold, inline code, list, blockquote,
        // link, fenced code.
        let text = """
        # Notes

        Some **bold** and `code` and a [link](https://example.com).

        - item one
        - item two

        > a quote

        ```swift
        let x = 1
        ```
        """
        let spans = MarkdownHighlighter.spans(in: text)
        let markers = spans.filter { $0.kind == .syntaxMarker }
        #expect(!markers.isEmpty)

        // Cursor on the bold/code/link paragraph only.
        let caret = NSRange(location: range(of: "bold", in: text).location, length: 0)
        let activePara = SyntaxMarkerVisibility.activeParagraphRange(in: text, selectedRange: caret)
        let boldMarker = markers.first { $0.range == range(of: "**bold**", in: text).prefix(2) }
        let codeMarker = markers.first { $0.range == range(of: "`code`", in: text).prefix(1) }
        let headingMarker = markers.first { $0.range == range(of: "# ", in: text) }
        let fenceMarker = markers.first { $0.range == range(of: "```swift", in: text) }

        #expect(boldMarker != nil && SyntaxMarkerVisibility.isActive(boldMarker!, activeParagraph: activePara))
        #expect(codeMarker != nil && SyntaxMarkerVisibility.isActive(codeMarker!, activeParagraph: activePara))
        #expect(headingMarker != nil && !SyntaxMarkerVisibility.isActive(headingMarker!, activeParagraph: activePara))
        #expect(fenceMarker != nil && !SyntaxMarkerVisibility.isActive(fenceMarker!, activeParagraph: activePara))
    }
}
