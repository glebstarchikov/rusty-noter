import Testing
import Foundation
import SwiftUI
import AppKit
@testable import NoterEditor

/// Headless verification of R6c's hide/reveal mechanic against the real
/// `MarkdownTextView.Coordinator.restyle()` (not a reimplementation) driven
/// through a windowless `NSTextView`. `range(of:in:)` comes from
/// MarkdownHighlighterTests.swift (same target).
///
/// What these tests CAN prove: attributes land correctly (near-zero font +
/// clear off-active, faint + normal font on-active), reveal flips as the
/// selection moves, restyle() never moves the selection or fires spurious
/// change notifications, and (geometrically) hidden glyphs collapse to
/// near-zero width. What they CANNOT prove: how any of this actually looks
/// or feels to a human at the keyboard — see task-6c-report.md.
@MainActor
@Suite struct MarkdownTextViewRestyleTests {
    private func makeHarness(
        text: String,
        onEdit: @escaping (String) -> Void = { _ in }
    ) -> (coordinator: MarkdownTextView.Coordinator, textView: NSTextView) {
        var current = text
        let binding = Binding<String>(get: { current }, set: { current = $0 })
        let view = MarkdownTextView(text: binding, theme: .standard(), onEdit: onEdit)
        let coordinator = view.makeCoordinator()
        let textView = NSTextView()
        textView.string = text
        coordinator.textView = textView
        return (coordinator, textView)
    }

    @Test func hiddenMarkerCollapsesToNearZeroFontActiveMarkerStaysNormalSize() {
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        // Cursor on the bold paragraph: bold's ** markers active; heading's # marker off-active.
        textView.setSelectedRange(NSRange(location: range(of: "bold", in: text).location, length: 0))
        coordinator.restyle()

        let boldLeadMarker = range(of: "**bold**", in: text).prefix(2)
        let storage = textView.textStorage!
        let activeFont = storage.attribute(.font, at: boldLeadMarker.location, effectiveRange: nil) as? NSFont
        #expect((activeFont?.pointSize ?? 0) > 1, "active marker should keep a normal-size font")
        let activeColor = storage.attribute(.foregroundColor, at: boldLeadMarker.location, effectiveRange: nil) as? NSColor
        #expect(activeColor == EditorTheme.standard().faint)

        let headingMarker = range(of: "# ", in: text)
        let hiddenFont = storage.attribute(.font, at: headingMarker.location, effectiveRange: nil) as? NSFont
        #expect(hiddenFont?.pointSize == 0.01, "off-active marker should collapse to the near-zero hidden font")
        let hiddenColor = storage.attribute(.foregroundColor, at: headingMarker.location, effectiveRange: nil) as? NSColor
        #expect(hiddenColor == NSColor.clear)
    }

    @Test func revealFollowsCursorAcrossTwoParagraphs() {
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        let storage = textView.textStorage!
        let headingMarker = range(of: "# ", in: text)
        let boldLeadMarker = range(of: "**bold**", in: text).prefix(2)

        // 1) Cursor on the heading -> heading marker active, bold marker hidden.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.restyle()
        #expect(((storage.attribute(.font, at: headingMarker.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) > 1)
        #expect((storage.attribute(.font, at: boldLeadMarker.location, effectiveRange: nil) as? NSFont)?.pointSize == 0.01)

        // 2) Move cursor to the bold paragraph -> reveal follows: flips.
        textView.setSelectedRange(NSRange(location: range(of: "bold", in: text).location, length: 0))
        coordinator.restyle()
        #expect((storage.attribute(.font, at: headingMarker.location, effectiveRange: nil) as? NSFont)?.pointSize == 0.01)
        #expect(((storage.attribute(.font, at: boldLeadMarker.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) > 1)
    }

    @Test func restyleNeverMovesTheSelection() {
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        let caret = NSRange(location: 3, length: 2)
        textView.setSelectedRange(caret)
        coordinator.restyle()
        #expect(textView.selectedRange() == caret, "attribute-only restyle must never move the selection")
    }

    @Test func restyleDoesNotFireSelectionChangeNotification_noFeedbackLoop() {
        // Directly verifies the brief's callout: does restyle()'s attribute
        // editing alone provoke NSTextView.didChangeSelectionNotification?
        // If it did, wiring textViewDidChangeSelection -> restyle() would
        // recurse. Attach a real observer and count actual posts.
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        // queue: nil delivers synchronously on the posting thread (main,
        // here), so this is safe despite not being provably Sendable.
        nonisolated(unsafe) var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: nil
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.restyle()
        coordinator.restyle() // twice, to be extra sure repeated attribute edits stay quiet

        #expect(notificationCount == 0,
                "attribute-only edits must not post a selection-change notification (would re-enter restyle via textViewDidChangeSelection and loop)")
    }

    @Test func restyleDoesNotTriggerTextChangeOrOnEdit() {
        // Companion check: attribute-only edits also must not look like a
        // *text* change, or restyle() would spuriously re-invoke onEdit
        // (persistence) on every selection move -- a files-are-truth hazard.
        let text = "# Title\n\nSome **bold** text.\n"
        var editCount = 0
        let (coordinator, textView) = makeHarness(text: text) { _ in editCount += 1 }
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        nonisolated(unsafe) var textChangeCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in textChangeCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.restyle()

        #expect(textChangeCount == 0, "attribute-only edits must not post NSText.didChangeNotification")
        #expect(editCount == 0, "restyle() must never invoke onEdit -- that would dirty persistence on every cursor move")
    }

    @Test func fencedCodeBlockDelimiterLineCollapsesEntirelyWhenOffActive() {
        // Every character of a fence line ("```swift") is a .syntaxMarker,
        // so off-active it should collapse in full, not just partially --
        // worth flagging in the report as a visible-height change to confirm
        // with Gleb (whole line goes near-zero height, not just narrower).
        let text = "```swift\nlet x = 1\n```\nafter\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: range(of: "after", in: text).location, length: 0))
        coordinator.restyle()
        let storage = textView.textStorage!
        let fenceRange = range(of: "```swift", in: text)
        for offset in fenceRange.location..<NSMaxRange(fenceRange) {
            let font = storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 0.01, "every character of the off-active fence line should collapse")
        }
    }

    @Test func hiddenMarkerGlyphsCollapseToNearZeroWidthGeometrically() {
        // Geometric proxy for "clicking near hidden glyphs" and "does the
        // content actually read clean": measure the laid-out width of a
        // hidden marker run vs. normal content. This is the strongest
        // headless evidence available that the technique achieves visual
        // hiding, short of an actual screenshot.
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        textView.textContainer?.size = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.setSelectedRange(NSRange(location: range(of: "bold", in: text).location, length: 0))
        coordinator.restyle()

        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            Issue.record("no layout manager / text container available headlessly")
            return
        }
        lm.ensureLayout(for: tc)

        let headingMarker = range(of: "# ", in: text) // off-active, hidden
        let headingGlyphRange = lm.glyphRange(forCharacterRange: headingMarker, actualCharacterRange: nil)
        let headingRect = lm.boundingRect(forGlyphRange: headingGlyphRange, in: tc)

        let titleWord = range(of: "Title", in: text) // normal-size content, for scale
        let titleGlyphRange = lm.glyphRange(forCharacterRange: titleWord, actualCharacterRange: nil)
        let titleRect = lm.boundingRect(forGlyphRange: titleGlyphRange, in: tc)

        #expect(headingRect.width < 1, "hidden marker glyphs should occupy near-zero width, got \(headingRect.width)")
        #expect(titleRect.width > headingRect.width * 10,
                "normal content should be meaningfully wider than the collapsed marker for scale")
    }

    @Test func arrowRightStepsOneCharacterAtATimeAcrossANearZeroFontRun() {
        // Empirical check for the brief's core caret-behavior question: does
        // the near-zero-font technique make TextKit treat a hidden marker
        // as one atomic "skip", or does the caret still stop at every
        // character (just with near-zero visual movement per press)?
        // Isolated from the active-paragraph logic by forcing the font
        // directly, so this measures pure caret mechanics.
        let text = "x **bold** y\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle()

        let leadMarker = range(of: "**bold**", in: text).prefix(2)
        textView.textStorage?.addAttribute(.font, value: EditorTheme.standard().hiddenFont, range: leadMarker)
        textView.setSelectedRange(NSRange(location: leadMarker.location, length: 0))

        textView.moveRight(nil)
        let afterFirstPress = textView.selectedRange()
        textView.moveRight(nil)
        let afterSecondPress = textView.selectedRange()

        #expect(afterFirstPress == NSRange(location: leadMarker.location + 1, length: 0),
                "expected moveRight to step by exactly one character; got \(afterFirstPress) -- if this fails, arrow-key stepping across hidden runs is NOT one-character-per-press and needs re-testing interactively")
        #expect(afterSecondPress == NSRange(location: leadMarker.location + 2, length: 0),
                "second moveRight should cross the second hidden '*' -- two presses to cross '**', not one atomic skip; got \(afterSecondPress)")
    }
}
