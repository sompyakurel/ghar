// make_icon.swift — draws Ghar's app icon on your Mac.
// No downloads, no design tools: pure macOS drawing.
//
// Run from ~/Desktop/Ghar:
//     swift make_icon.swift
//
// What it draws: a cream Devanagari "घ" on deep crimson, ringed by a
// deep-blue rounded border (Nepal flag colors). iOS rounds the corners
// itself, so we fill the whole square.
//
// Teaching notes:
// - NSBitmapImageRep = a blank canvas of pixels we paint into.
// - NSBezierPath = vector shapes (rects, rounded rects).
// - We try macOS's built-in Devanagari fonts until one exists.
// - Want different colors? Change the three NSColor lines and re-run.
import AppKit
import Foundation

let size: CGFloat = 1024
let outPath = CommandLine.arguments.dropFirst().first
    ?? "ios/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

// Nepal-flag-inspired palette (tweak these to taste)
let crimson = NSColor(srgbRed: 0.64, green: 0.09, blue: 0.13, alpha: 1.0)
let flagBlue = NSColor(srgbRed: 0.05, green: 0.18, blue: 0.45, alpha: 1.0)
let cream = NSColor(srgbRed: 1.0, green: 0.96, blue: 0.88, alpha: 1.0)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 1. Crimson background, full bleed
crimson.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

// 2. Deep-blue rounded border
let inset: CGFloat = 64
let border = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset,
                        width: size - inset * 2, height: size - inset * 2),
    xRadius: 200, yRadius: 200)
flagBlue.setStroke()
border.lineWidth = 46
border.stroke()

// 3. Cream "घ", centered
let candidates = ["KohinoorDevanagari-Bold", "KohinoorDevanagari-Semibold",
                  "DevanagariMT", "DevanagariSangamMN"]
let fontName = candidates.first { NSFont(name: $0, size: 40) != nil }
    ?? NSFont.systemFont(ofSize: 40).fontName
let font = NSFont(name: fontName, size: 620)!
let style = NSMutableParagraphStyle()
style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: cream, .paragraphStyle: style
]
let glyph = NSAttributedString(string: "घ", attributes: attrs)
let gSize = glyph.size()
glyph.draw(at: NSPoint(x: (size - gSize.width) / 2,
                      y: (size - gSize.height) / 2 - 30))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: could not encode PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) — rebuild the app in Xcode to see it.")
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
