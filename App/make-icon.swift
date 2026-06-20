// Generates App/AppIcon-1024.png — the "Synced Ripples" app icon: a graphite
// rounded square with concentric sound ripples radiating from a glowing core.
// One source, one sound, in sync everywhere — the whole idea of the app in a
// single restrained mark. The in-app AppLogo and the receiver's "searching"
// loader reuse the same ripple motif.
//
// Run:  swift App/make-icon.swift   (writes the 1024 master PNG)
// Then ./App/make-iconset.sh turns it into App/AppIcon.icns, and make-app.sh
// copies that into the bundle.

import AppKit

let canvas = 1024.0

func renderMaster(_ canvas: Double) -> NSBitmapImageRep {
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
    let margin = canvas * (100.0 / 1024.0)
    let square = NSRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
    let shape = NSBezierPath(roundedRect: square, xRadius: canvas * 0.18, yRadius: canvas * 0.18)

    // Soft drop shadow, like system icons.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.shadowBlurRadius = canvas * 0.024
    shadow.set()
    NSColor.black.set()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Solid graphite — restrained and premium, no "AI" gradient.
    NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.135, alpha: 1.0).setFill()
    shape.fill()

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()

    // A whisper of top highlight for a little depth.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.06),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: NSRect(x: square.minX, y: square.midY, width: square.width, height: square.height / 2), angle: -90)

    // Concentric sound ripples radiating from a glowing core.
    let cx = square.midX
    let cy = square.midY
    let w = square.width

    // Soft radial glow behind the core.
    let glowR = w * 0.30
    if let glow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.30),
        NSColor.white.withAlphaComponent(0.0),
    ]) {
        glow.draw(in: NSRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2),
                  relativeCenterPosition: NSPoint(x: 0, y: 0))
    }

    // Concentric ripples, fading and thinning outward — a sound pulse
    // mid-flight. Crisp circles (the organic motion lives in the animated
    // loader); a luminous, slightly larger core reads as "an emitting source"
    // rather than a flat target.
    let ringRadii = [0.175, 0.275, 0.375].map { $0 * w }
    let ringWidth = [0.032, 0.021, 0.013].map { $0 * w }
    let ringAlpha = [0.92, 0.50, 0.24]
    for i in 0..<ringRadii.count {
        let r = ringRadii[i]
        let path = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        path.lineWidth = ringWidth[i]
        NSColor.white.withAlphaComponent(ringAlpha[i]).set()
        path.stroke()
    }

    // Bright solid core = the source.
    let coreR = w * 0.072
    NSColor.white.set()
    NSBezierPath(ovalIn: NSRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2)).fill()

    NSGraphicsContext.current?.restoreGraphicsState()
    return rep
}

let rep = renderMaster(canvas)
let pngURL = URL(fileURLWithPath: "App/AppIcon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: pngURL)
print("wrote \(pngURL.path)")
