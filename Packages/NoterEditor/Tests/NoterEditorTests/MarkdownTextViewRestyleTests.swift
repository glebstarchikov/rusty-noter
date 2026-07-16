import Testing
import Foundation
import SwiftUI
import AppKit
@testable import NoterEditor

/// Headless verification of R6c/R6d's hide/reveal mechanic against the real
/// `MarkdownTextView.Coordinator.restyle()` (not a reimplementation) driven
/// through a windowless `NSTextView`. `range(of:in:)` comes from
/// MarkdownHighlighterTests.swift (same target).
///
/// R6d replaced the 0.01pt-font hiding hack with TextKit glyph-nulling:
/// off-active `.syntaxMarker` ranges get the `.mdHidden` attribute, and
/// `Coordinator`'s `NSLayoutManagerDelegate` nulls those glyphs so they lay
/// out at zero width. `makeHarness` wires `textView.delegate = coordinator`
/// (mirroring `makeNSView`) so both that delegate and the caret-skip
/// `NSTextViewDelegate` hook are live for these tests.
///
/// What these tests CAN prove: attributes land correctly (`.mdHidden`
/// off-active, faint + normal font on-active), reveal flips as the
/// selection moves, restyle() never moves the selection or fires spurious
/// change notifications, hidden glyphs geometrically collapse to
/// near-zero/zero width, and the caret-skip delegate redirects a selection
/// change that would otherwise land inside a hidden run. What they CANNOT
/// prove: how any of this actually looks or feels to a human at the
/// keyboard — see task-6d-report.md.
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
        textView.delegate = coordinator
        coordinator.textView = textView
        return (coordinator, textView)
    }

    @Test func hiddenMarkerIsMarkedMdHiddenActiveMarkerStaysNormalAndFaint() {
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
        #expect(storage.attribute(.mdHidden, at: boldLeadMarker.location, effectiveRange: nil) == nil,
                "active marker must not carry .mdHidden")

        let headingMarker = range(of: "# ", in: text)
        #expect(storage.attribute(.mdHidden, at: headingMarker.location, effectiveRange: nil) != nil,
                "off-active marker should be marked .mdHidden for the glyph-nulling delegate to collapse")
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
        #expect(storage.attribute(.mdHidden, at: headingMarker.location, effectiveRange: nil) == nil)
        #expect(storage.attribute(.mdHidden, at: boldLeadMarker.location, effectiveRange: nil) != nil)

        // 2) Move cursor to the bold paragraph -> reveal follows: flips.
        textView.setSelectedRange(NSRange(location: range(of: "bold", in: text).location, length: 0))
        coordinator.restyle()
        #expect(storage.attribute(.mdHidden, at: headingMarker.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdHidden, at: boldLeadMarker.location, effectiveRange: nil) == nil)
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
        // so off-active it should collapse in full, not just partially.
        let text = "```swift\nlet x = 1\n```\nafter\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: range(of: "after", in: text).location, length: 0))
        coordinator.restyle()
        let storage = textView.textStorage!
        let fenceRange = range(of: "```swift", in: text)
        for offset in fenceRange.location..<NSMaxRange(fenceRange) {
            #expect(storage.attribute(.mdHidden, at: offset, effectiveRange: nil) != nil,
                    "every character of the off-active fence line should be marked .mdHidden")
        }
        let style = storage.attribute(.paragraphStyle, at: fenceRange.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.maximumLineHeight == 0.01,
                "the fence line's own paragraph style should clamp its line height near-zero too")
    }

    @Test func fencedCodeBlockDelimiterLineHeightGeometricallyCollapsesAndRestoresWhenActive() {
        // Glyph-nulling alone zeroes a fence line's WIDTH but TextKit still
        // reserves a full line's HEIGHT for an all-null-glyph line (found
        // via codex-check review; confirmed empirically: an 18pt line
        // stays 18pt tall even fully nulled without the paragraph-style
        // fix in restyle()). This is the geometric proof the fix actually
        // closes that gap, and that it reverts once the fence line becomes
        // the active paragraph (pass 0 resets every paragraph's style to
        // `.default` on every restyle() call).
        let text = "```swift\nlet x = 1\n```\nafter\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.textContainer?.size = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            Issue.record("no layout manager / text container available headlessly")
            return
        }
        let fenceRange = range(of: "```swift", in: text)
        func fenceLineHeight() -> CGFloat {
            let glyphIndex = lm.glyphRange(forCharacterRange: NSRange(location: fenceRange.location, length: 1), actualCharacterRange: nil).location
            var eff = NSRange()
            return lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &eff).height
        }

        // Off-active: fence line's height should collapse near-zero, not stay a full 18pt-ish line.
        textView.setSelectedRange(NSRange(location: range(of: "after", in: text).location, length: 0))
        coordinator.restyle()
        lm.ensureLayout(for: tc)
        #expect(fenceLineHeight() < 1, "off-active fence line should collapse to near-zero height, got \(fenceLineHeight())")

        // Cursor moves onto the fence line -> it becomes active -> height must be restored.
        textView.setSelectedRange(NSRange(location: fenceRange.location, length: 0))
        coordinator.restyle()
        lm.ensureLayout(for: tc)
        #expect(fenceLineHeight() > 1, "fence line should regain normal height once active, got \(fenceLineHeight())")
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

    @Test func invalidationMakesGlyphGeometryFollowActiveParagraphAcrossRestyles() {
        // Direct proof that restyle()'s invalidateGlyphs/invalidateLayout
        // call actually makes the glyph-nulling delegate re-run when the
        // active paragraph changes -- not just that the `.mdHidden`
        // attribute flips (hiddenMarkerIsMarkedMdHidden... proves that
        // already), but that the LAID-OUT GEOMETRY follows it across
        // restyle() calls, with no manual re-layout beyond what restyle()
        // itself triggers. This is the headless proxy for "does the reveal
        // actually redraw," and specifically guards against a regression
        // where glyphs stay stuck at whatever they were nulled to.
        let text = "# Title\n\nSome **bold** text.\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        textView.textContainer?.size = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            Issue.record("no layout manager / text container available headlessly")
            return
        }
        let headingMarker = range(of: "# ", in: text)
        func headingWidth() -> CGFloat {
            let glyphRange = lm.glyphRange(forCharacterRange: headingMarker, actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: glyphRange, in: tc).width
        }

        // Cursor on the bold paragraph -> heading is off-active -> collapsed.
        textView.setSelectedRange(NSRange(location: range(of: "bold", in: text).location, length: 0))
        coordinator.restyle()
        lm.ensureLayout(for: tc)
        #expect(headingWidth() == 0, "heading marker should collapse to exactly zero width off-active")

        // Cursor moves onto the heading -> invalidation must make the
        // delegate re-run and restore the glyphs' natural width.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.restyle()
        lm.ensureLayout(for: tc)
        #expect(headingWidth() > 1,
                "heading marker should regain its natural width once active -- proves invalidation re-runs the glyph-nulling delegate")
    }

    @Test func caretWalkingRightAcrossAParagraphBoundaryIntoAHiddenHeadingMarkerNeverRegressesOrSticks() {
        // Real-world caret-mechanics smoke test, fully wired exactly as
        // production ships it (Part 1 glyph-nulling and Part 2 caret-skip
        // share one Coordinator -- there's no way to ship one without the
        // other, since `makeHarness`/`makeNSView` wire `textView.delegate`
        // and `layoutManager.delegate` to the same object). Walks real
        // moveRight() presses from a body paragraph across the boundary
        // into a heading paragraph whose "# " marker is hidden until the
        // caret arrives there, exactly as restyle() would re-run on every
        // step in the shipping app (`textView.delegate = coordinator`
        // means `textViewDidChangeSelection` -> `restyle()` fires after
        // each move, same as `makeNSView`).
        //
        // This exists because isolated micro-testing during development
        // (forcing `.mdHidden` directly, bypassing restyle()'s own
        // reveal/hide cycle -- see task-6d-report.md) turned up that
        // TextKit 1's default caret movement over *null* glyphs (distinct
        // from the old near-zero-*font* glyphs, which stepped predictably
        // one character at a time) is sensitive to exactly what layout
        // work preceded it, occasionally landing somewhere other than a
        // plain one-character step. Asserting an exact position sequence
        // here would be overfitting to that sensitivity; the invariants
        // that actually matter for UX -- never jump backward, never get
        // stuck, and reach the destination -- are what's checked instead.
        let text = "xy\n# Title\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.restyle()

        var positions = [textView.selectedRange().location]
        for _ in 0..<8 {
            textView.moveRight(nil)
            positions.append(textView.selectedRange().location)
        }

        for i in 1..<positions.count {
            #expect(positions[i] >= positions[i - 1],
                    "moveRight must never move the caret backward across a hidden run; got \(positions)")
        }
        #expect(positions.last! > positions.first!,
                "caret should make forward progress across the document, not get stuck; got \(positions)")
        let titleStart = range(of: "Title", in: text).location
        #expect(positions.contains(where: { $0 >= titleStart }),
                "caret should reach the heading text within 8 presses; got \(positions)")
    }

    @Test func caretWalkingLeftBackAcrossAParagraphBoundaryOutOfAHeadingNeverJumpsForwardOrSticks() {
        // Mirror of the rightward walk, in reverse: starting inside the
        // (active, revealed) heading and walking left back out past its
        // own "# " marker -- which becomes hidden mid-walk, the instant
        // the caret's paragraph changes -- and on into the body paragraph.
        let text = "xy\n# Title\n"
        let (coordinator, textView) = makeHarness(text: text)
        let titleStart = range(of: "Title", in: text).location
        textView.setSelectedRange(NSRange(location: titleStart, length: 0))
        coordinator.restyle()

        var positions = [textView.selectedRange().location]
        for _ in 0..<8 {
            textView.moveLeft(nil)
            positions.append(textView.selectedRange().location)
        }

        for i in 1..<positions.count {
            #expect(positions[i] <= positions[i - 1],
                    "moveLeft must never move the caret forward across a hidden run; got \(positions)")
        }
        #expect(positions.last! < positions.first!,
                "caret should make backward progress across the document, not get stuck; got \(positions)")
        #expect(positions.contains(0), "caret should reach the start of the document within 8 presses; got \(positions)")
    }

    @Test func caretSkipRedirectsASelectionThatWouldLandInsideAHiddenRun() {
        // Positive proof of Part 2 through the REAL production path: a
        // `setSelectedRange` call (the same primitive both clicks and
        // `moveRight`/`moveLeft` funnel through) that would land strictly
        // inside a hidden `.mdHidden` run gets redirected by
        // `Coordinator.textView(_:willChangeSelectionFromCharacterRange:toCharacterRange:)`.
        // This is the scenario caret-skip actually matters for in this
        // editor: because whole-paragraph reveal means arrow-key entry into
        // a new paragraph always lands exactly at its first character (a
        // boundary, never "inside" a run -- see task-6d-report.md), a
        // *jump* like a mouse click landing on the collapsed, zero-width
        // "# " glyphs is the realistic way to end up strictly inside one.
        let text = "# Title\n\nBody text here.\n"
        let (coordinator, textView) = makeHarness(text: text)
        // Cursor starts on the body paragraph -> heading's "# " is hidden.
        textView.setSelectedRange(NSRange(location: range(of: "Body", in: text).location, length: 0))
        coordinator.restyle()

        let headingMarker = range(of: "# ", in: text) // [0, 2)
        #expect(textView.textStorage?.attribute(.mdHidden, at: headingMarker.location, effectiveRange: nil) != nil)

        // A click landing at index 1 -- strictly inside the hidden "# " run.
        // Approaching from the right (old location > proposed), the
        // near/far-edge heuristic treats this as "moving left" and snaps to
        // the run's start rather than stepping into its interior.
        textView.setSelectedRange(NSRange(location: headingMarker.location + 1, length: 0))
        #expect(textView.selectedRange() == NSRange(location: headingMarker.location, length: 0),
                "a selection change landing inside the hidden '# ' run should be redirected to its edge, not left mid-run")
    }

    @Test func caretSkipLeavesASelectionOutsideAnyHiddenRunUntouched() {
        // Companion negative case: a selection change that does NOT land
        // inside a hidden run must pass through byte-for-byte unchanged --
        // guards against caret-skip over-triggering on ordinary navigation.
        let text = "# Title\n\nBody text here.\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: range(of: "Body", in: text).location, length: 0))
        coordinator.restyle()

        let target = range(of: "text", in: text).location
        textView.setSelectedRange(NSRange(location: target, length: 0))
        #expect(textView.selectedRange() == NSRange(location: target, length: 0),
                "ordinary selection changes outside any hidden run must not be redirected")
    }

    @Test func caretSkipDoesNotInterfereWithNonEmptySelections() {
        // Drag/shift-click selections (non-empty ranges) must pass through
        // untouched even if they overlap a hidden run -- caret-skip only
        // ever adjusts empty (caret) selections per the brief.
        let text = "# Title\n\nBody text here.\n"
        let (coordinator, textView) = makeHarness(text: text)
        textView.setSelectedRange(NSRange(location: range(of: "Body", in: text).location, length: 0))
        coordinator.restyle()

        let headingMarker = range(of: "# ", in: text)
        let drag = NSRange(location: headingMarker.location, length: headingMarker.length)
        textView.setSelectedRange(drag)
        #expect(textView.selectedRange() == drag, "a non-empty selection spanning a hidden run must not be redirected")
    }
}
