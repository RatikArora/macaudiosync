// Generates App/AppIcon.icns — a macOS Big Sur-style icon: rounded square
// with a blue-violet gradient and a white speaker+waves symbol.
//
// Run:  swift App/make-icon.swift
// (Then make-app.sh copies the .icns into the app bundle.)

import AppKit

let canvas = 1024.0

func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

    // Big Sur icon grid: ~824pt rounded square centered on a 1024 canvas.
    let margin = 100.0
    let square = NSRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
    let shape = NSBezierPath(roundedRect: square, xRadius: 184, yRadius: 184)

    // Soft drop shadow, like system icons.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.set()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gradient fill.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.32, green: 0.18, blue: 0.92, alpha: 1.0), // violet
        NSColor(calibratedRed: 0.10, green: 0.52, blue: 1.00, alpha: 1.0), // azure
    ])!
    gradient.draw(in: shape, angle: -65)

    // Subtle highlight across the top.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: NSRect(x: square.minX, y: square.midY, width: square.width, height: square.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // White speaker-with-waves symbol.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("symbol unavailable")
    }
    let white = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    // Aspect-fit into the square, optically centered.
    let maxSide = square.width * 0.62
    let scale = min(maxSide / white.size.width, maxSide / white.size.height)
    let drawSize = NSSize(width: white.size.width * scale, height: white.size.height * scale)
    let origin = NSPoint(
        x: square.midX - drawSize.width / 2,
        y: square.midY - drawSize.height / 2
    )
    white.draw(in: NSRect(origin: origin, size: drawSize))

    return rep
}

let rep = renderMaster()
let pngURL = URL(fileURLWithPath: "App/AppIcon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: pngURL)
print("wrote \(pngURL.path)")
