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

        /// True once this view has opted into TextKit 1 compatibility mode
        /// (R6e hardening from the R6d review). The `.layoutManager` access
        /// below is the documented migration trigger; AppKit itself caches
        /// the result internally (repeat access is empirically a cheap
        /// no-op -- see task-6d-report.md), but this flag stops `restyle()`
        /// from depending on that AppKit-level caching every call. The
        /// migration, delegate wiring, and `backgroundLayoutEnabled` setup
        /// now run exactly once per Coordinator -- one Coordinator serves
        /// one `textView` for its whole lifetime (`makeCoordinator()` is
        /// called once by SwiftUI, and `textView` is assigned once in
        /// `makeNSView`) -- not once per restyle() call.
        private var isTextKit1Ready = false
        private weak var cachedLayoutManager: NSLayoutManager?

        /// Hanging indent (pt) applied to every list item's full paragraph
        /// range, ordered and unordered alike (R6e Parts 2/3): using the
        /// same value for both `firstLineHeadIndent` and `headIndent` means
        /// that once an unordered marker is hidden (glyph-nulled to zero
        /// width), wrapped continuation lines align under the item's text
        /// rather than under the bullet. `MeasuredTextView.bulletIndentX`
        /// places the drawn bullet inside this gap -- see its doc comment.
        private static let listIndent: CGFloat = 22

        /// Extra indent (pt) added per `ListItem.depth` level, on top of
        /// `listIndent`, so nested items step in under their parent (Fix:
        /// nested lists were rendering at a flat indent regardless of
        /// depth). Applied both to the paragraph indent below and -- via
        /// `BulletMarker.x`, resolved once here since only this loop knows
        /// each item's depth -- to the drawn bullet's x, so the bullet
        /// always sits inside its item's hanging-indent gap.
        private static let listDepthStep: CGFloat = 18

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

            // Opt this view into TextKit 1 compatibility mode, once (R6e
            // hardening -- see `isTextKit1Ready`'s doc comment above).
            // Accessing `.layoutManager` is the documented trigger (still
            // verified working on macOS 26) for a TextKit-2-default
            // NSTextView to migrate to an NSLayoutManager, which is
            // required for the shouldGenerateGlyphs delegate hook below to
            // ever fire.
            if !isTextKit1Ready, let migrated = textView.layoutManager {
                migrated.delegate = self
                // `backgroundLayoutEnabled` defaults to true, which per
                // Apple's docs means glyph generation/layout may be
                // deferred to idle run-loop time rather than happening
                // immediately -- but that idle work still runs on the main
                // thread ("Background layout occurs on the main thread when
                // it is idle"), not a background *thread*. Turning it off
                // removes any ambiguity: it makes layout for this view
                // fully synchronous, so `shouldGenerateGlyphs`/`setGlyphs`
                // below -- which read `NSTextStorage` and are not
                // thread-safe -- are guaranteed to run on the @MainActor
                // this Coordinator is isolated to.
                migrated.backgroundLayoutEnabled = false
                cachedLayoutManager = migrated
                isTextKit1Ready = true
            }
            let layoutManager = cachedLayoutManager

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
                    break // handled below: indent + ordered/unordered marker hide-vs-reveal (R6e)
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
            // Pass 3: list-item hanging indent (ordered + unordered) and the
            // unordered marker's own hide-vs-reveal (R6e). `.listMarker`
            // spans cover only the 2-4 char marker prefix, not the whole
            // line, so the indent -- which must cover the full paragraph or
            // wrapped continuation lines won't align under the item's text
            // -- is applied over `BlockDecorations.ListItem.lineRange`
            // rather than the raw span range (`BlockDecorations` also
            // classifies ordered vs. unordered, which the span's kind alone
            // can't do). Ordered markers ("1. ") keep their number always
            // visible -- it's meaningful content, not decoration. Only
            // unordered markers ("- "/"* "/"+ ") get the same
            // mdHidden-off-active / faint-on-active treatment as
            // .syntaxMarker spans above (reusing the same `activePara` and
            // `SyntaxMarkerVisibility.isActive` check via a synthetic span,
            // so "active" means the identical thing everywhere in this
            // function), so the bullet drawn in
            // `MeasuredTextView.drawBackground` is the only marker visible
            // once the cursor leaves the item -- never both a raw "- " and
            // a drawn bullet at once.
            let listItems = BlockDecorations.listItems(spans: spans, text: textView.string)
            // (range, depth) per hidden unordered marker -- depth is
            // resolved to the bullet's final drawn x below, once we know
            // whether this is the production `MeasuredTextView` (only it
            // has the geometry -- `bulletIndentX`, `textContainerOrigin`
            // -- needed to resolve an absolute x).
            var bulletMarkerEntries: [(range: NSRange, depth: Int)] = []
            for item in listItems {
                guard NSMaxRange(item.lineRange) <= storage.length,
                      NSMaxRange(item.markerRange) <= storage.length else { continue }
                let listStyle = NSMutableParagraphStyle()
                let indent = Self.listIndent + CGFloat(item.depth) * Self.listDepthStep
                listStyle.firstLineHeadIndent = indent
                listStyle.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: listStyle, range: item.lineRange)

                if item.isOrdered {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: item.markerRange)
                    continue
                }
                let markerSpan = MarkdownSpan(range: item.markerRange, kind: .listMarker)
                if SyntaxMarkerVisibility.isActive(markerSpan, activeParagraph: activePara) {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: item.markerRange)
                } else {
                    storage.addAttribute(.mdHidden, value: true, range: item.markerRange)
                    bulletMarkerEntries.append((range: item.markerRange, depth: item.depth))
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

            // Hand the drawn-decoration ranges to the view (R6e): quote
            // bars and list bullets are painted, not inserted into the
            // string -- files-are-truth means the markdown text itself is
            // never touched, so this is display-only geometry recomputed
            // fresh every restyle() and consumed by
            // `MeasuredTextView.drawBackground(in:)`. `as?` is nil (a
            // graceful no-op) for the plain `NSTextView` the test harness
            // uses -- only the production `MeasuredTextView` draws these.
            if let measured = textView as? MeasuredTextView {
                measured.theme = theme
                measured.blockquoteRanges = BlockDecorations.blockquoteLineRanges(spans: spans)
                // Resolve each marker's final x here (Fix 1 part 3): this
                // is the one place with both the per-item `depth` (this
                // loop) and the view's own bullet geometry
                // (`bulletIndentX`, `textContainerOrigin.x`) -- so
                // `drawBackground` just paints at `x`, with no depth/step
                // math of its own to duplicate or drift out of sync.
                measured.bulletMarkers = bulletMarkerEntries.map { entry in
                    BulletMarker(
                        range: entry.range,
                        x: measured.textContainerOrigin.x + measured.bulletIndentX
                            + CGFloat(entry.depth) * Self.listDepthStep)
                }
                measured.needsDisplay = true
            }
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

/// One hidden unordered-list marker's character range and the absolute x
/// (in the view's own coordinate space -- already including
/// `textContainerOrigin.x`, `bulletIndentX`, and the item's per-depth step)
/// its drawn bullet belongs at. Resolved once in `Coordinator.restyle()`,
/// the only place that knows each item's nesting depth alongside the
/// view's bullet geometry, so `drawBackground` below just paints at `x`
/// with no depth/indent-step arithmetic of its own to duplicate.
struct BulletMarker {
    let range: NSRange
    let x: CGFloat
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

    // MARK: - Block decoration drawing (R6e)

    /// Set by `Coordinator.restyle()` on every restyle -- the theme to draw
    /// decorations with, and the character ranges of blockquote lines /
    /// hidden unordered-list markers (each already carrying its resolved
    /// draw-x, see `BulletMarker`) to paint a bar / bullet for. Purely a
    /// rendering concern (never read back by restyle() or anything else),
    /// consumed only by `drawBackground(in:)` below.
    var theme: EditorTheme?
    var blockquoteRanges: [NSRange] = []
    var bulletMarkers: [BulletMarker] = []

    /// Bullet's x-offset from `textContainerOrigin.x`, inside the
    /// `Coordinator.listIndent` (22pt) gap the hanging indent reserves for
    /// it -- deliberately less than that so the ~4pt bullet, plus its own
    /// gap to the indented item text, both fit inside the reserved space.
    /// `fileprivate`, not `private`: `Coordinator.restyle()` reads this to
    /// resolve each `BulletMarker.x` (it also adds the per-depth step,
    /// which only it knows) -- see the call site there.
    fileprivate let bulletIndentX: CGFloat = 8
    private let bulletDiameter: CGFloat = 4
    /// Quote bar sits in the reserved 48pt left margin (`leftInset`),
    /// outside the text container entirely (negative = left of
    /// `textContainerOrigin.x`) rather than inside the blockquote's own
    /// 16pt headIndent gap -- there's ample clearance either way (16pt of
    /// indent vs. this bar ending at container-origin -11), so no overlap
    /// with the indented quote text regardless.
    private let quoteBarIndentX: CGFloat = -14
    private let quoteBarWidth: CGFloat = 3

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

    /// Paints block decorations BEHIND the text (`super` draws the standard
    /// background/selection fill first, then decorations, then -- later in
    /// NSTextView's own draw pipeline -- glyphs on top) -- display-only,
    /// never touches the string, selection, or undo stack. `restyle()`
    /// computes `blockquoteRanges`/`bulletMarkers` from
    /// `MarkdownHighlighter.spans` via `BlockDecorations` and calls
    /// `needsDisplay = true`; this turns each character range into a
    /// screen rect via the layout manager and paints a decoration there.
    ///
    /// The bug this fixes: Gleb found visually that both the bar and the
    /// bullet were drawing on TWO lines -- the correct one AND one line
    /// above it. The original (R6e) implementation used
    /// `boundingRect(forGlyphRange:in:)`, which -- per the local macOS
    /// 26.4 SDK's `NSLayoutManager.h` (Context7 still has no real Apple
    /// AppKit/TextKit coverage, same gap task-6d/6e reports hit) --
    /// returns "the smallest bounding rect which completely encloses the
    /// glyphs in the given glyphRange," i.e. a UNION over every line
    /// fragment the range's glyphs touch.
    ///
    /// Root cause, verified empirically (glyph-by-glyph, via
    /// `lineFragmentRect(forGlyphAt:effectiveRange:)` against a real
    /// multi-paragraph layout) rather than assumed: a glyph-nulled
    /// (`.mdHidden`, zero-width/`notShown`) marker run sitting at the very
    /// start of a line gets attributed by the typesetter to the tail of
    /// the PREVIOUS line's fragment, not its own -- so any range beginning
    /// with one touches two fragments, and `boundingRect` unioned them
    /// into a rect ~2 lines tall. (The existing
    /// `hiddenUnorderedMarkerRunReportsCorrectLineGeometryForBulletPlacement`
    /// test never caught this -- it only asserts the marker rect's width
    /// and height, never its Y-origin, which is exactly where the union
    /// bites.)
    ///
    /// `enumerateLineFragments(forGlyphRange:using:)` reports fragments
    /// individually instead of unioning them -- `usedRect`, the tight,
    /// actually-laid-out area, is used over the sibling `rect` param,
    /// which is the fuller reserved-layout rect and can overshoot -- but
    /// that alone is NOT the fix: the spurious previous-line fragment
    /// still shows up as one of the enumerated fragments. Proven
    /// empirically to matter for bullets specifically: `BulletMarker.range`
    /// is only the marker's own 2-4 chars (`BlockDecorations.ListItem
    /// .markerRange`), 100% nulled glyphs, so it's the *only* fragment
    /// `enumerateLineFragments` reports for that range -- "take the first
    /// fragment" would silently draw the bullet on the wrong line every
    /// time, not just when wrapped. So every fragment is filtered: it
    /// only counts if the glyph range `enumerateLineFragments` hands back
    /// FOR IT starts at/after the glyph range being queried -- the
    /// spurious fragment always starts before it (it began life on the
    /// previous line). Verified this isn't a false-negative trap: with no
    /// previous line at all (marker on the document's first paragraph),
    /// only the correct fragment is ever reported, and the filter keeps
    /// it.
    ///
    /// Bullets need one more step to have anything genuine to filter
    /// down to: since the marker's own range is wholly nulled glyphs (see
    /// above), it never resolves a second, real fragment on its own --
    /// verified even an otherwise-empty item ("- " then just the line's
    /// own terminating newline) still needs that newline's non-nulled
    /// glyph to anchor one. So the query is widened from the marker to
    /// its enclosing paragraph via `NSString.paragraphRange(for:)` --
    /// pure string-range math, unaffected by the glyph quirk -- then the
    /// filter picks the genuine fragment out of it. Blockquote bars don't
    /// need this widening: `blockquoteRanges` is already the whole source
    /// line, visible content included, so a genuine fragment is always
    /// among the ones enumerated.
    ///
    /// Blockquote bars draw one segment per genuine fragment, so a
    /// wrapped quote line's bar covers each of its visual rows (verified:
    /// an 8-row wrapped line yields 8 genuine fragments, in top-to-bottom
    /// order, plus the one spurious leading fragment). List bullets draw
    /// once, at the first genuine fragment -- a wrapped list item's
    /// bullet always belongs on its marker's own (first) line.
    ///
    /// One geometry choice differs between the two decorations, though:
    /// the blockquote loop below sizes each bar segment from the
    /// enumeration closure's first parameter -- the line fragment's FULL
    /// `rect` (the fuller, reserved-layout rect the doc above says can
    /// overshoot) -- rather than the tight `usedRect` the original (R6e)
    /// implementation used for both decorations. That overshoot is exactly
    /// what's wanted here: full line-fragment rects partition the text
    /// vertically with no gaps, so consecutive quoted lines' segments abut
    /// into one continuous bar instead of leaving a line-spacing-sized
    /// seam between them (`usedRect` is tight to the glyphs, which is
    /// narrower than a line's full reserved height). Bullets keep using
    /// `usedRect` for their y-centering below -- unaffected by this, and
    /// deliberately not touched.
    ///
    /// Abutting rects alone turned out not to be enough, though (Gleb
    /// confirmed visually after that fix shipped): each segment was still
    /// drawn as its OWN independently-rounded pill
    /// (`NSBezierPath(roundedRect:xRadius:yRadius:)`), so two abutting
    /// pills each round their own top/bottom corners right at the seam --
    /// a visible pinch at every line boundary even with zero gap between
    /// the rects. The blockquote loop below now collects every segment
    /// rect instead of drawing it immediately, merges vertically-
    /// contiguous ones into runs via `RectMerge.mergeVertically` (pure,
    /// unit-tested), and draws ONE rounded rect per run -- so a
    /// multi-line quote's interior line boundaries are straight edges,
    /// and only the whole run's outer top/bottom corners are rounded.
    /// Two genuinely separate quote blocks (a real paragraph gap between
    /// them) stay separate runs, each with its own rounded bar.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let storage = textStorage else { return }
        let barColor = theme?.borderStrong ?? .separatorColor
        let bulletColor = theme?.faint ?? .tertiaryLabelColor

        // Collect every bar segment rect instead of drawing it immediately
        // -- see the doc comment above: drawing each fragment as its own
        // rounded pill pinches the bar inward at every line boundary, even
        // where the rects themselves abut with no gap. `barSegments`
        // gathers segments across ALL blockquote ranges (not per-range)
        // since `RectMerge.mergeVertically` below sorts by Y itself, so a
        // single merge pass correctly joins one quote's own lines while
        // leaving a real paragraph gap between two separate quotes intact.
        var barSegments: [NSRect] = []
        for charRange in blockquoteRanges {
            guard charRange.location >= 0, NSMaxRange(charRange) <= storage.length else { continue }
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
                // Skip the spurious fragment inherited from the previous
                // line -- see the doc comment above.
                guard fragGlyphRange.location >= glyphRange.location else { return }
                // Full line-fragment rect, not the tight `usedRect` -- see
                // the doc comment above: full rects tile contiguously, so
                // consecutive quote-line segments abut with no seam.
                var barRect = fragRect
                barRect.origin.y += self.textContainerOrigin.y
                barRect.origin.x = self.textContainerOrigin.x + self.quoteBarIndentX
                barRect.size.width = self.quoteBarWidth
                barSegments.append(barRect)
            }
        }
        // One rounded rect per merged run -- see `RectMerge` and the doc
        // comment above. 1.5pt tolerance absorbs sub-pixel/line-spacing
        // slop between fragments that are visually contiguous but not
        // bit-for-bit touching, well under a real paragraph gap.
        let radius = quoteBarWidth / 2
        for runRect in RectMerge.mergeVertically(barSegments, tolerance: 1.5) {
            barColor.setFill()
            NSBezierPath(roundedRect: runRect, xRadius: radius, yRadius: radius).fill()
        }

        for marker in bulletMarkers {
            let charRange = marker.range
            guard charRange.location >= 0, NSMaxRange(charRange) <= storage.length else { continue }
            // Widen marker-only charRange to its paragraph so there's real
            // content for the typesetter to anchor a genuine fragment to
            // -- see the doc comment above.
            let lineRange = (storage.string as NSString).paragraphRange(for: charRange)
            let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect: NSRect?
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragGlyphRange, stop in
                guard fragGlyphRange.location >= glyphRange.location else { return }
                lineRect = usedRect
                stop.pointee = true
            }
            guard let lineRect else { continue }
            // x arrives pre-resolved (per-depth step included) from
            // `Coordinator.restyle()` -- see `BulletMarker`'s doc comment.
            let y = lineRect.origin.y + textContainerOrigin.y + (lineRect.height - bulletDiameter) / 2
            let dot = NSRect(x: marker.x, y: y, width: bulletDiameter, height: bulletDiameter)
            bulletColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
