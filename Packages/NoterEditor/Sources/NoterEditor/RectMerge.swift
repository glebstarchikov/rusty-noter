import CoreGraphics
import Foundation

/// Pure geometry helper for R6e's blockquote-bar drawing pass: given a set
/// of per-line-fragment bar-segment rects (all sharing the same x/width --
/// see `MeasuredTextView.drawBackground(in:)`), merges the ones that are
/// vertically contiguous into single spanning runs.
///
/// The bug this fixes: even after `drawBackground` switched to full
/// line-fragment rects so consecutive quote-line segments abut with zero
/// gap between them (see that method's doc comment), each segment was
/// still drawn as its OWN independently-rounded pill
/// (`NSBezierPath(roundedRect:xRadius:yRadius:)`, radius = bar width / 2).
/// Two abutting pills each round their own top/bottom corners right at the
/// seam, which pinches the bar inward at every line boundary -- a visible
/// notch running down a multi-line quote, even though the rects themselves
/// touch with no actual gap between them. Merging contiguous segments into
/// one run BEFORE drawing means only a run's outer top/bottom corners get
/// rounded; every interior line boundary becomes a straight edge, so a
/// multi-line quote reads as one continuous bar. Two genuinely separate
/// quote blocks (a blank line/paragraph between them) leave a real gap --
/// far larger than `tolerance` -- so they stay two separate runs, each
/// with its own rounded bar.
///
/// Factored out of `MeasuredTextView.drawBackground(in:)` -- NSTextView
/// /NSLayoutManager-bound and hard to drive headlessly -- so the merge
/// logic itself is unit-testable directly, mirroring `CaretSkip` and
/// `BlockDecorations`.
public enum RectMerge {
    /// Merges rects that are vertically contiguous or overlapping into
    /// single spanning runs, assuming all input rects share the same x and
    /// width (true for blockquote bar segments -- see
    /// `MeasuredTextView.drawBackground(in:)`) so only their Y-extent
    /// needs merging.
    ///
    /// Rects are sorted by `minY` first, so caller order doesn't matter.
    /// Walking that sorted order, a rect joins the running run when its
    /// `minY` is at or before the run's `maxY` plus `tolerance` -- i.e.
    /// touching, overlapping, or separated by no more than `tolerance`
    /// points -- otherwise the running run is closed out and a new one
    /// starts at that rect. `tolerance` exists to absorb sub-pixel/
    /// line-spacing rounding between fragments that are visually
    /// contiguous but not bit-for-bit touching; it should stay well under
    /// a real paragraph gap (a full line height) so two genuinely separate
    /// quote blocks never bridge into one run.
    ///
    /// A merged run's rect spans from its first segment's `minY` to its
    /// last segment's `maxY`, at the shared x/width every input rect
    /// already carries.
    public static func mergeVertically(_ rects: [NSRect], tolerance: CGFloat) -> [NSRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted { $0.minY < $1.minY }
        var runs: [NSRect] = []
        var current = sorted[0]
        for rect in sorted.dropFirst() {
            if rect.minY <= current.maxY + tolerance {
                let minY = min(current.minY, rect.minY)
                let maxY = max(current.maxY, rect.maxY)
                current.origin.y = minY
                current.size.height = maxY - minY
            } else {
                runs.append(current)
                current = rect
            }
        }
        runs.append(current)
        return runs
    }
}
