#!/usr/bin/env swift
// Renders the AgentMenu app icon and the menu-bar template image.
//
// Drawn in CoreGraphics rather than rasterised from SVG on purpose: the SVG
// rasterisers available without extra tooling drop gradients and strokes
// silently, and this project ships with no image dependencies. The shapes here
// are the source of truth; assets/brand/*.svg is the human-readable copy.
//
//   swift packaging/icon/make-icons.swift            # -> dist/icon/
//
// Requires nothing but the Swift toolchain and AppKit.

import AppKit
import Foundation

// MARK: - Brand

/// Vertical gradient of the icon body, top to bottom.
let bodyStops: [(CGFloat, NSColor)] = [
    (0.00, NSColor(srgbRed: 1.000, green: 0.494, blue: 0.714, alpha: 1)),   // #FF7EB6
    (0.42, NSColor(srgbRed: 0.839, green: 0.200, blue: 0.424, alpha: 1)),   // #D6336C
    (1.00, NSColor(srgbRed: 0.369, green: 0.063, blue: 0.180, alpha: 1)),   // #5E102E
]

/// A superellipse — Apple's icon silhouette is not a circular-cornered rect,
/// and at 1024px the difference is visible.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5.0, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for step in 0...steps {
        let theta = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
        let ct = cos(theta), st = sin(theta)
        let x = cx + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The glyph: a prompt caret, a command line under it, and the preset dot.
/// `side` is the size of the square the glyph is drawn into, origin at its
/// bottom-left, in a flipped-free (CoreGraphics, y-up) space.
func drawGlyph(in context: CGContext, side: CGFloat, origin: CGPoint, color: NSColor) {
    let s = side / 1024.0
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y)
    context.setStrokeColor(color.cgColor)
    context.setFillColor(color.cgColor)
    context.setLineWidth(76 * s)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Caret. Coordinates are quoted in a y-down design grid and flipped here,
    // so the drawing matches assets/brand/icon.svg line for line.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1024 - y) * s) }

    context.beginPath()
    context.move(to: p(366, 372))
    context.addLine(to: p(512, 512))
    context.addLine(to: p(366, 652))
    context.strokePath()

    context.beginPath()
    context.move(to: p(598, 652))
    context.addLine(to: p(718, 652))
    context.strokePath()

    let dot = CGRect(x: (700 - 44) * s, y: (1024 - 372 - 44) * s, width: 88 * s, height: 88 * s)
    context.fillEllipse(in: dot)
    context.restoreGState()
}

// MARK: - Renderers

func renderAppIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext

    // macOS icon grid: the artwork occupies 832 of 1024, centred.
    let inset = size * (96.0 / 1024.0)
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = squirclePath(in: body)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = bodyStops.map { $0.1.cgColor } as CFArray
    let locations = bodyStops.map { $0.0 }
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }
    // A single soft highlight along the top edge — depth without a plastic sheen.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.30).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.midY + body.height * 0.06),
            options: []
        )
    }
    context.restoreGState()

    // Hairline, so the icon keeps an edge on a white background.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(NSColor(srgbRed: 0.22, green: 0.02, blue: 0.09, alpha: 0.28).cgColor)
    context.setLineWidth(max(1, size * (8.0 / 1024.0)))
    context.strokePath()
    context.restoreGState()

    drawGlyph(in: context, side: size, origin: .zero, color: NSColor(white: 1, alpha: 0.95))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The menu-bar image is a template: one colour plus alpha, drawn at the point
/// size AppKit asks for. macOS tints it for light, dark and the active state,
/// so any colour here would be thrown away.
func renderMenuBarTemplate(points: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(points * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(pixels)px bitmap") }
    rep.size = NSSize(width: points, height: points)

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    // The rep's size is in points while its backing store is in pixels, so the
    // graphics context already scales; scaling again here would draw at 4x.
    let context = graphics.cgContext
    let s = points / 18.0
    context.setStrokeColor(NSColor.black.cgColor)
    context.setFillColor(NSColor.black.cgColor)
    context.setLineWidth(1.9 * s)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (18 - y) * s) }

    context.beginPath()
    context.move(to: p(5.4, 5.2))
    context.addLine(to: p(8.6, 9))
    context.addLine(to: p(5.4, 12.8))
    context.strokePath()

    context.beginPath()
    context.move(to: p(10.6, 12.8))
    context.addLine(to: p(13.2, 12.8))
    context.strokePath()

    context.fillEllipse(in: CGRect(x: (12.7 - 1.15) * s, y: (18 - 5.4 - 1.15) * s, width: 2.3 * s, height: 2.3 * s))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("dist/icon")
let iconset = out.appendingPathComponent("AgentMenu.iconset")
let menubar = out.appendingPathComponent("menubar")
for dir in [out, iconset, menubar] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// The names iconutil expects.
let iconSizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in iconSizes {
    write(renderAppIcon(size: size), to: iconset.appendingPathComponent("\(name).png"))
}
write(renderAppIcon(size: 1024), to: out.appendingPathComponent("AgentMenu-1024.png"))

for (suffix, scale) in [("", CGFloat(1)), ("@2x", 2), ("@3x", 3)] {
    write(renderMenuBarTemplate(points: 18, scale: scale),
          to: menubar.appendingPathComponent("MenuBarIconTemplate\(suffix).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", out.appendingPathComponent("AgentMenu.icns").path, iconset.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

print("wrote \(out.path): AgentMenu.icns, AgentMenu-1024.png, menubar/MenuBarIconTemplate{,@2x,@3x}.png")
