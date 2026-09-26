// make_icon.swift — draws Ghar's app icon on your Mac.
// No downloads, no design tools: pure macOS drawing.
//
// Run from ~/Desktop/Ghar:
//     swift make_icon.swift
//
// What it draws: a cream home icon on deep crimson, ringed by a
// deep-blue rounded border (Nepal flag colors). iOS rounds the corners
// itself, so we fill the whole square.
//
// Teaching notes:
// - NSBitmapImageRep = a blank canvas of pixels we paint into.
// - NSBezierPath = vector shapes. The house is one path: move(to:) +
//   line(to:) trace the roof triangle and walls like connect-the-dots,
//   then fill() paints it. The door and window are crimson shapes on
//   top, so they look cut out.
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

// 3. Cream home icon, centered.
// A house is one filled path: trace the roof triangle + walls like
// connect-the-dots, then fill. The door and round window are crimson
// shapes painted on top, so they look cut out.
let house = NSBezierPath()
house.move(to: NSPoint(x: 232, y: 620))   // left eave

house.line(to: NSPoint(x: 512, y: 880))   // roof peak

house.line(to: NSPoint(x: 792, y: 620))   // right eave

house.line(to: NSPoint(x: 712, y: 620))   // step in to the right wall

house.line(to: NSPoint(x: 712, y: 270))   // right wall down

house.line(to: NSPoint(x: 312, y: 270))   // bottom wall

house.line(to: NSPoint(x: 312, y: 620))   // left wall up

house.close()                             // back to the left eave
cream.setFill()
house.fill()

// Door + round window, cut out in crimson
crimson.setFill()
NSBezierPath(rect: NSRect(x: 462, y: 270, width: 100, height: 190)).fill()
NSBezierPath(ovalIn: NSRect(x: 472, y: 690, width: 80, height: 80)).fill()

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
