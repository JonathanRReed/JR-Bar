// Renders the app icon and the menu bar glyph.
//
//   swift make-icon.swift <AppIcon.iconset dir> [MenuBarGlyph@2x.png]
//
// The icon: a dark glass tile in the macOS rounded-square shape, a subtle
// notch silhouette hanging from its top edge, and a short glowing bar under
// it (the Screen Bar's band with its halo). No text. Every size is drawn at
// its own pixel size rather than downsampled, so the 16 and 32 px icons keep
// a crisp bar instead of a smear. The glyph is the same motif as a black
// template image at 18×18 pt (rendered at 2×), for design review next to
// `StatusIconRenderer`, which draws it in code.
import AppKit
import CoreImage

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <AppIcon.iconset> [MenuBarGlyph@2x.png]\n".data(using: .utf8)!)
    exit(2)
}
let iconsetPath = arguments[1]
let glyphPath = arguments.count > 2 ? arguments[2] : nil

// MARK: - Palette

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let tileTop = color(0x2A2E38)
let tileBottom = color(0x0C0D12)
let notchFill = color(0x04050A)
let bandColors = [color(0x2CD9FF), color(0x5A8CFF), color(0x9B6BFF), color(0xFF5FA8)]

// MARK: - Drawing

/// Draws the icon into the current graphics context, `side` pixels square.
func drawIcon(side: CGFloat) {
    let s = side / 1024
    let tiny = side <= 32
    let small = side <= 64
    // The macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
    let tileRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tileRadius = 186 * s
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

    // Tile: dark glass, lit from above.
    NSGradient(colors: [tileTop, tileBottom])!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // A soft sheen across the top third.
    let sheen = NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.10), 0.0), (NSColor.white.withAlphaComponent(0.0), 1.0))!
    sheen.draw(in: NSRect(x: tileRect.minX, y: tileRect.maxY - 300 * s, width: tileRect.width, height: 300 * s), angle: -90)
    // Faint vignette at the bottom corners.
    let vignette = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0.0), 0.0), (NSColor.black.withAlphaComponent(0.28), 1.0))!
    vignette.draw(in: NSRect(x: tileRect.minX, y: tileRect.minY, width: tileRect.width, height: 260 * s), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Notch silhouette: hangs from the tile's top edge, rounded at the bottom.
    let notchWidth = 380 * s
    let notchDepth = 236 * s
    let notchRadius = 66 * s
    let notchRect = NSRect(x: tileRect.midX - notchWidth / 2, y: tileRect.maxY - notchDepth, width: notchWidth, height: notchDepth + tileRadius)
    let notch = NSBezierPath(roundedRect: notchRect, xRadius: notchRadius, yRadius: notchRadius)
    // The band: a short rounded bar under the notch, wider than it, as the
    // Screen Bar's wings are.
    let bandWidth = 520 * s
    let bandHeight = max(tiny ? 2.5 : 2, 46 * s)
    let gap = max(2, 30 * s)
    var bandY = tileRect.maxY - notchDepth - gap - bandHeight
    if tiny { bandY = (bandY).rounded() }
    let bandRect = NSRect(x: tileRect.midX - bandWidth / 2, y: bandY, width: bandWidth, height: bandHeight)
    let gradient = NSGradient(colors: bandColors)!

    // Halo: the band blurred, added as light. A wide soft bloom that fills
    // the tile below the band, and a tight one that reads as the band's own
    // glow. The blurred source is thicker than the band so the bloom keeps
    // some intensity once spread.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let bloom: [(CGFloat, Double, CGFloat, CGFloat)] = tiny
        ? [(2.0, 0.55, 1.05, 2.0), (0.8, 0.7, 1.0, 1.2)]
        : [(150 * s, small ? 1.0 : 0.85, 1.25, 4.0), (60 * s, small ? 1.0 : 0.8, 1.05, 2.0), (18 * s, 0.9, 1.0, 1.2)]
    for (radius, alpha, spreadX, spreadY) in bloom {
        let haloRect = bandRect.insetBy(dx: -bandWidth * (spreadX - 1) / 2, dy: -bandHeight * (spreadY - 1) / 2)
        if let glow = blurredBand(rect: haloRect, gradient: gradient, radius: max(0.6, radius), canvas: side) {
            glow.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .plusLighter, fraction: alpha)
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // Notch silhouette, drawn after the halo so it stays a crisp shape hanging from the top edge.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    notchFill.setFill()
    notch.fill()
    if !tiny {
        // A hairline of light along the notch's lower edge so it reads as a shape, not a hole.
        NSColor.white.withAlphaComponent(small ? 0.10 : 0.07).setStroke()
        let edge = NSBezierPath(roundedRect: notchRect.insetBy(dx: 0.5 * s, dy: 0.5 * s), xRadius: notchRadius, yRadius: notchRadius)
        edge.lineWidth = max(1, 2.5 * s)
        edge.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The band itself, with a thin highlight along its top edge.
    let band = NSBezierPath(roundedRect: bandRect, xRadius: bandHeight / 2, yRadius: bandHeight / 2)
    gradient.draw(in: band, angle: 0)
    if !tiny {
        NSGraphicsContext.saveGraphicsState()
        band.addClip()
        let highlight = NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.45), 0.0), (NSColor.white.withAlphaComponent(0.0), 1.0))!
        highlight.draw(in: NSRect(x: bandRect.minX, y: bandRect.maxY - bandHeight * 0.45, width: bandRect.width, height: bandHeight * 0.45), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Rim light on the tile's top edge.
    if !tiny {
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1 * s, dy: 1 * s), xRadius: tileRadius, yRadius: tileRadius)
        rim.lineWidth = max(1, 2 * s)
        NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.22), 0.0), (NSColor.white.withAlphaComponent(0.02), 0.5), (NSColor.white.withAlphaComponent(0.0), 1.0))!
            .draw(in: rimStroke(rim, width: rim.lineWidth), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A path's stroke as a fill region (for gradient strokes).
func rimStroke(_ path: NSBezierPath, width: CGFloat) -> NSBezierPath {
    let cg = path.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return NSBezierPath(cgPath: cg)
}

/// The band drawn alone on a transparent canvas and Gaussian-blurred.
func blurredBand(rect: NSRect, gradient: NSGradient, radius: CGFloat, canvas: CGFloat) -> NSImage? {
    let size = Int(canvas)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    gradient.draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = rep.cgImage else { return nil }
    let input = CIImage(cgImage: cgImage)
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
    blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(radius, forKey: kCIInputRadiusKey)
    guard let output = blur.outputImage?.cropped(to: input.extent) else { return nil }
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    guard let result = context.createCGImage(output, from: input.extent) else { return nil }
    return NSImage(cgImage: result, size: NSSize(width: canvas, height: canvas))
}

/// The menu bar glyph: the notch cap over the bar, as `StatusIconRenderer.drawGlyph`.
func drawGlyph(scale: CGFloat) {
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor.black.withAlphaComponent(0.38).setFill()
    let cap = NSBezierPath()
    cap.move(to: NSPoint(x: 4.5, y: 15.5))
    cap.line(to: NSPoint(x: 13.5, y: 15.5))
    cap.line(to: NSPoint(x: 13.5, y: 12.2))
    cap.curve(to: NSPoint(x: 11.7, y: 10.4), controlPoint1: NSPoint(x: 13.5, y: 11.2), controlPoint2: NSPoint(x: 12.7, y: 10.4))
    cap.line(to: NSPoint(x: 6.3, y: 10.4))
    cap.curve(to: NSPoint(x: 4.5, y: 12.2), controlPoint1: NSPoint(x: 5.3, y: 10.4), controlPoint2: NSPoint(x: 4.5, y: 11.2))
    cap.close()
    cap.fill()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 2.5, y: 5.6, width: 13, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
}

// MARK: - Output

func render(pixels: Int, draw: (CGFloat) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high
    context?.shouldAntialias = true
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

do {
    try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
    for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                           ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        guard let png = render(pixels: pixels, draw: { side in drawIcon(side: side) }) else { throw NSError(domain: "make-icon", code: 1) }
        try png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent("icon_\(name).png"))
    }
    if let glyphPath {
        guard let png = render(pixels: 36, draw: { _ in drawGlyph(scale: 2) }) else { throw NSError(domain: "make-icon", code: 1) }
        try png.write(to: URL(fileURLWithPath: glyphPath))
    }
} catch {
    FileHandle.standardError.write("could not render icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
