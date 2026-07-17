import AppKit
import Foundation

// Renders the Rusty Noter app icon: a charcoal squircle with a white page and an
// indigo text caret (concept C). Same squircle geometry + charcoal as the
// claude-widget critter icon, so the two apps read as one family. Pixel-art
// motif = axis-aligned rects on a 512 design grid.
//
// Usage: swift scripts/render-appicon.swift <output-dir>
//        (writes icon_16.png ... icon_1024.png)

func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
            green: CGFloat((v >> 8) & 0xFF) / 255.0,
            blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes = [16, 32, 64, 128, 256, 512, 1024]

let charcoal = 0x1C1B1F   // squircle bg — design 'elevated' (dark), matches claude-widget
let paper    = 0xF2F1EE   // warm off-white page
let indigo   = 0x8A86FF   // accent (dark) — the caret, the one interactive moment

for size in sizes {
    let px = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Fill a rect given fractions of the 512 grid in TOP-LEFT origin (y down);
    // the bitmap context is bottom-left origin, so flip y here.
    func fillTL(_ v: Int, _ fx: Double, _ fy: Double, _ fw: Double, _ fh: Double) {
        hex(v).setFill()
        let x = CGFloat(fx) * px, w = CGFloat(fw) * px, h = CGFloat(fh) * px
        let yTop = CGFloat(fy) * px
        NSBezierPath(rect: NSRect(x: x, y: px - yTop - h, width: w, height: h)).fill()
    }

    // Charcoal squircle: inset 6%, corner radius 22% of full size.
    hex(charcoal).setFill()
    NSBezierPath(roundedRect: NSRect(x: px * 0.06, y: px * 0.06, width: px * 0.88, height: px * 0.88),
                 xRadius: px * 0.22, yRadius: px * 0.22).fill()

    // Page silhouette.
    fillTL(paper, 156.0 / 512.0, 126.0 / 512.0, 200.0 / 512.0, 260.0 / 512.0)
    // Text lines cut out of the page (charcoal): full, short 'current', full, short.
    fillTL(charcoal, 184.0 / 512.0, 176.0 / 512.0, 132.0 / 512.0, 22.0 / 512.0)
    fillTL(charcoal, 184.0 / 512.0, 218.0 / 512.0,  58.0 / 512.0, 22.0 / 512.0)
    fillTL(charcoal, 184.0 / 512.0, 260.0 / 512.0, 132.0 / 512.0, 22.0 / 512.0)
    fillTL(charcoal, 184.0 / 512.0, 302.0 / 512.0,  96.0 / 512.0, 22.0 / 512.0)
    // Indigo caret at the end of the current line.
    fillTL(indigo, 252.0 / 512.0, 210.0 / 512.0, 14.0 / 512.0, 38.0 / 512.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(size).png")
    do { try data.write(to: url); print("wrote \(url.lastPathComponent)") }
    catch { FileHandle.standardError.write("failed \(url.lastPathComponent): \(error)\n".data(using: .utf8)!) }
}
