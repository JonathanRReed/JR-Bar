// Renders the placeholder app icon: a dark rounded tile with a notch cap and
// one glowing gradient band under it. Usage: swift make-icon.swift out.png
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
    // Tile
    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 64, dy: 64), xRadius: 200, yRadius: 200)
    NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // Notch cap hanging from the top edge of the tile
    let cap = NSBezierPath()
    cap.move(to: NSPoint(x: 302, y: 960))
    cap.line(to: NSPoint(x: 722, y: 960))
    cap.line(to: NSPoint(x: 722, y: 700))
    cap.curve(to: NSPoint(x: 662, y: 640), controlPoint1: NSPoint(x: 722, y: 667), controlPoint2: NSPoint(x: 695, y: 640))
    cap.line(to: NSPoint(x: 362, y: 640))
    cap.curve(to: NSPoint(x: 302, y: 700), controlPoint1: NSPoint(x: 329, y: 640), controlPoint2: NSPoint(x: 302, y: 667))
    cap.close()
    NSColor.black.setFill()
    cap.fill()

    // Glow halo under the band
    let band = NSRect(x: 214, y: 552, width: 596, height: 74)
    let bandColors = [
        NSColor(srgbRed: 0.0, green: 0.90, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.30, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.10, alpha: 1),
    ]
    let gradient = NSGradient(colors: bandColors)!
    for (inset, alpha) in [(-80.0, 0.10), (-48.0, 0.16), (-22.0, 0.26)] {
        NSGraphicsContext.saveGraphicsState()
        let halo = NSBezierPath(roundedRect: band.insetBy(dx: inset * 0.8, dy: inset), xRadius: 120, yRadius: 120)
        NSGraphicsContext.current?.compositingOperation = .plusLighter
        gradient.draw(in: halo, angle: 0)
        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1 - alpha).setFill()
        halo.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // The band itself
    gradient.draw(in: NSBezierPath(roundedRect: band, xRadius: 37, yRadius: 37), angle: 0)
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not render icon\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
