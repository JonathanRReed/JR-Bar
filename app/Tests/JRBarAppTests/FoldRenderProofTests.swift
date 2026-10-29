import JRBarTestSupport
import AppKit
import CoreVideo
import Foundation
import JRBarCore
import MetalKit
import SwiftUI
import Testing
@testable import JRBarApp

/// Render proof for the Fold's two looks: a synthetic desktop (menu bar,
/// Dock, three windows, a grid on the wallpaper; no real screen content)
/// folded at 110/100/90/75/60/30/10° from a lid resting at 110°. Each
/// angle gets two pictures: the **panel** (what the glass shows) and the
/// **observer** (what a seated eye sees: the panel re-projected from the
/// eye onto the resting lid, with the room showing where the glass has
/// dropped away). In the Duo the observer row should not move: the
/// desktop stays put and only the glass silhouette drops, soft and dark
/// toward the top, black at 30° and 10°.
///
/// The drift check always runs; the strips (`fold-duo-strip.png`,
/// `fold-room-strip.png`) are written only with `JRBAR_RENDER_PROOF=1`,
/// into `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Fold render proof", .renderProofAppearance)
@MainActor
struct FoldRenderProofTests {
    /// The shaders compile off the main thread and a main-actor renderer
    /// never waits for them, so the suite warms the cache itself and
    /// passes whether it runs alone or after another Fold suite.
    init() async {
        await withCheckedContinuation { continuation in
            FoldShaderCache.shared.prewarm(pixelFormat: .bgra8Unorm) { continuation.resume() }
        }
    }

    nonisolated static let width = 1512
    nonisolated static let height = 982
    static let rest = 110.0
    static let angles: [Double] = [110, 100, 90, 75, 60, 30, 10]
    /// The observer's view reaches this far past the resting screen on
    /// every side, as a share of its height.
    static let margin: Float = 0.08

    // The desktop's parts, in pixels from the top-left.
    static let dockRect = CGRect(x: 506, y: 900, width: 500, height: 60)
    static let yellowWindow = CGRect(x: 180, y: 470, width: 440, height: 230)
    static let checkerWindow = CGRect(x: 780, y: 150, width: 460, height: 370)
    static let textWindow = CGRect(x: 90, y: 110, width: 610, height: 450)

    // MARK: The desktop

    /// Draws the synthetic desktop (or, `wallpaperOnly`, what the Room's
    /// far stream sees: the wallpaper alone) into a capture-shaped frame,
    /// `scale` pixels to the point: 2 is the Retina capture.
    static func desktop(wallpaperOnly: Bool = false, scale: Int = 1) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let pixelsWide = width * scale
        let pixelsHigh = height * scale
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, pixelsWide, pixelsHigh, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &maybeBuffer) == kCVReturnSuccess)
        let buffer = try #require(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: pixelsWide, height: pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        // Top-left origin, like the capture.
        ctx.translateBy(x: 0, y: CGFloat(pixelsHigh))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        drawWallpaper(ctx)
        guard !wallpaperOnly else { return buffer }
        drawTextWindow(ctx)
        drawCheckerWindow(ctx)
        fill(ctx, yellowWindow, 245, 225, 70)
        drawMenuBar(ctx)
        drawDock(ctx)
        drawHingeText(ctx)
        return buffer
    }

    /// Two lines of synthetic text on the wallpaper just above the Dock,
    /// where the fold should keep the desktop exactly as sharp as it was.
    static let hingeText = CGRect(x: 180, y: 740, width: 760, height: 120)

    private static func drawHingeText(_ ctx: CGContext) {
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let lines: [(String, CGFloat)] = [
            ("Fold proof: thirteen-point text on a synthetic desktop", 13),
            ("Eleven-point detail: 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ", 11),
            ("The hinge rows should stay as sharp as the desktop was", 13),
        ]
        var y = hingeText.minY
        for line in lines {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: line.1, weight: .regular),
                .foregroundColor: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
            ]
            (line.0 as NSString).draw(at: CGPoint(x: hingeText.minX, y: y), withAttributes: attrs)
            y += 36
        }
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ r: Int, _ g: Int, _ b: Int) {
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                 blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(rect)
    }

    private static func drawWallpaper(_ ctx: CGContext) {
        for y in 0..<height {
            let t = Double(y) / Double(height)
            fill(ctx, CGRect(x: 0, y: y, width: width, height: 1),
                 Int(40 + 160 * t), Int(50 + 60 * t), Int(120 - 10 * t))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
        for x in stride(from: 0, to: width, by: 42) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
        for y in stride(from: 0, to: height, by: 42) { ctx.fill(CGRect(x: 0, y: y, width: width, height: 1)) }
    }

    private static func drawTextWindow(_ ctx: CGContext) {
        fill(ctx, textWindow, 28, 30, 36)
        fill(ctx, CGRect(x: textWindow.minX, y: textWindow.minY, width: textWindow.width, height: 26), 52, 54, 62)
        for (i, y) in stride(from: textWindow.minY + 44, to: textWindow.maxY - 16, by: 18).enumerated() {
            let w = CGFloat(180 + (i * 97) % 330)
            fill(ctx, CGRect(x: textWindow.minX + 24, y: y, width: w, height: 7),
                 i % 5 == 0 ? 110 : 200, i % 5 == 0 ? 170 : 205, i % 5 == 0 ? 240 : 210)
        }
    }

    private static func drawCheckerWindow(_ ctx: CGContext) {
        fill(ctx, checkerWindow, 250, 250, 250)
        let cell: CGFloat = 12
        var y = checkerWindow.minY + 26
        var row = 0
        while y < checkerWindow.maxY {
            var x = checkerWindow.minX
            var col = row % 2
            while x < checkerWindow.maxX {
                if col % 2 == 0 {
                    fill(ctx, CGRect(x: x, y: y, width: min(cell, checkerWindow.maxX - x),
                                     height: min(cell, checkerWindow.maxY - y)), 20, 20, 24)
                }
                x += cell
                col += 1
            }
            y += cell
            row += 1
        }
        fill(ctx, CGRect(x: checkerWindow.minX, y: checkerWindow.minY, width: checkerWindow.width, height: 26), 70, 72, 80)
    }

    private static func drawMenuBar(_ ctx: CGContext) {
        fill(ctx, CGRect(x: 0, y: 0, width: width, height: 37), 28, 28, 36)
        for i in 0..<5 { fill(ctx, CGRect(x: 20 + i * 64, y: 13, width: 44, height: 11), 225, 225, 230) }
        for i in 0..<7 { fill(ctx, CGRect(x: width - 40 - i * 34, y: 11, width: 18, height: 15), 225, 225, 230) }
    }

    private static func drawDock(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(srgbRed: 40 / 255, green: 220 / 255, blue: 90 / 255, alpha: 1))
        ctx.addPath(CGPath(roundedRect: dockRect, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
    }

    // MARK: Rendering

    struct Rig {
        let renderer: FoldRenderer
        let desktop: MTLTexture
        let observerPipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState
        let queue: MTLCommandQueue
    }

    /// A renderer for `look` holding the desktop, plus the observer pass
    /// (test-only: compiled from the renderer's own source, so it shares
    /// the Duo's side-view helpers).
    static func makeRig(_ look: FoldLook) throws -> Rig {
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        renderer.look = look
        let frame = try desktop()
        #expect(renderer.setFullFrame(frame))
        if look == .room {
            #expect(renderer.setFarFrame(try desktop(wallpaperOnly: true)))
            let size = CGSize(width: width, height: height)
            let rects = [yellowWindow, checkerWindow, textWindow].map {
                CGRect(x: $0.minX / size.width, y: $0.minY / size.height,
                       width: $0.width / size.width, height: $0.height / size.height)
            }
            renderer.setCards(PortalDepth.cards(for: rects))
            // The cards are stamped on the next full frame.
            #expect(renderer.setFullFrame(frame))
        }
        let device = renderer.device
        let library = try device.makeLibrary(source: FoldRenderer.shaderSource + observerSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "foldVertex")
        desc.fragmentFunction = library.makeFunction(name: "foldObserver")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let texture = try makeTarget(device)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: try #require(CVPixelBufferGetBaseAddress(frame)),
                        bytesPerRow: CVPixelBufferGetBytesPerRow(frame))
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        return Rig(renderer: renderer, desktop: texture,
                   observerPipeline: try device.makeRenderPipelineState(descriptor: desc),
                   sampler: try #require(device.makeSamplerState(descriptor: samplerDesc)),
                   queue: try #require(device.makeCommandQueue()))
    }

    static func makeTarget(_ device: MTLDevice, width: Int = width,
                           height: Int = height) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        return try #require(device.makeTexture(descriptor: desc))
    }

    /// What the glass shows at `angle`: the live desktop while the
    /// overlay is out (no travel yet), else the look's overlay — the
    /// toy's own mapping for each look, from a lid resting at 110°.
    static func renderPanel(_ rig: Rig, angle: Double, blur: Double = 0.6,
                            shade: Double = 0.67) throws -> MTLTexture {
        let delta = rest - angle
        guard delta > 0.2 else { return rig.desktop }
        let renderer = rig.renderer
        if renderer.look == .duo {
            FoldDuoModel.apply(to: &renderer.params, reference: rest, theta: angle, hold: 1,
                               perspective: 0.6, blur: blur, shade: shade, fadeLength: 0.55,
                               reduceMotion: false)
        } else {
            FoldPortalModel.apply(to: &renderer.params,
                                  delta: FoldMath.deltaRadians(angle: angle, reference: rest),
                                  perspective: 0.6, blur: blur, shade: shade, frost: 0, hold: 1,
                                  usedBuckets: renderer.usedBucketCount, reduceMotion: false)
        }
        let out = try makeTarget(renderer.device)
        #expect(renderer.render(to: out, size: CGSize(width: width, height: height)))
        return out
    }

    /// What the seated eye sees with the glass at `angle`.
    static func renderObserver(_ rig: Rig, panel: MTLTexture, angle: Double) throws -> MTLTexture {
        let out = try makeTarget(rig.renderer.device)
        let command = try #require(rig.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        let eye = FoldDuoModel.eye(perspective: 0.6)
        var o: [Float] = [Float(eye.x), Float(eye.y), Float(rest * .pi / 180), Float(angle * .pi / 180),
                          Float(width) / Float(height), margin, 0, 0]
        encoder.setRenderPipelineState(rig.observerPipeline)
        encoder.setFragmentTexture(panel, index: 0)
        encoder.setFragmentSamplerState(rig.sampler, index: 0)
        encoder.setFragmentBytes(&o, length: o.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return out
    }

    static let observerSource = """
    struct FoldObserver { float2 eye; float thetaRef; float theta; float aspect; float margin; float pad0; float pad1; };

    // The resting screen widened by `margin`: each pixel casts a ray from
    // the eye through its point on the resting lid and looks for the
    // physical glass at `theta`. A hit shows the panel there; a miss
    // shows the room (a grey check), never the black void.
    fragment float4 foldObserver(FoldOut in [[stage_in]],
                                 texture2d<float> panel [[texture(0)]],
                                 constant FoldObserver &o [[buffer(0)]],
                                 sampler s [[sampler(0)]]) {
        float m = o.margin;
        float2 q = float2((in.uv.x - 0.5) * (1.0 + 2.0 * m) * o.aspect,
                          (1.0 - in.uv.y) * (1.0 + 2.0 * m) - m);
        float2 Q = q.y * duoLidDir(o.thetaRef);
        float2 E = o.eye;
        float2 n = duoLidNormal(o.theta);
        float2 cc = floor(in.uv * float2(48.0, 32.0));
        float3 room = float3(0.42, 0.43, 0.45) * (0.92 + 0.08 * fmod(cc.x + cc.y, 2.0));
        if (dot(E, n) <= 0.0) { return float4(room, 1.0); }
        float den = dot(Q - E, n);
        if (abs(den) < 1e-5) { return float4(room, 1.0); }
        float sPar = -dot(E, n) / den;
        if (sPar <= 0.0) { return float4(room, 1.0); }
        float2 R = E + sPar * (Q - E);
        float hp = dot(R, duoLidDir(o.theta));
        float xp = sPar * q.x;
        if (hp < 0.0 || hp > 1.0 || abs(xp) > 0.5 * o.aspect) { return float4(room, 1.0); }
        return float4(panel.sample(s, float2(xp / o.aspect + 0.5, 1.0 - hp)).rgb, 1.0);
    }
    """

    // MARK: Measuring

    struct Pixels {
        let bytes: [UInt8]
        var width = FoldRenderProofTests.width
        var height = FoldRenderProofTests.height
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i + 2]), Double(bytes[i + 1]), Double(bytes[i]))
        }
    }

    static func pixels(_ texture: MTLTexture) -> Pixels {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return Pixels(bytes: bytes, width: w, height: h)
    }

    /// The Dock's centroid: the green only the Dock wears.
    static func dockCentroid(_ px: Pixels) -> CGPoint? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in (height / 2)..<height {
            for x in 0..<width {
                let c = px.rgb(x, y)
                if c.g > 100 && c.g > c.r + 60 && c.g > c.b + 60 {
                    sx += Double(x); sy += Double(y); n += 1
                }
            }
        }
        return n > 50 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    /// The yellow window's centroid: the one yellow on the desktop.
    static func yellowCentroid(_ px: Pixels) -> CGPoint? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let c = px.rgb(x, y)
                if c.r > 120 && c.g > 100 && c.b < 0.5 * c.g && abs(c.r - c.g) < 60 {
                    sx += Double(x); sy += Double(y); n += 1
                }
            }
        }
        return n > 50 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    /// Where `values` crosses halfway between its two ends, by linear
    /// interpolation — an edge's position, robust to blur.
    static func crossing(_ values: [Double]) -> Double? {
        guard let first = values.first, let last = values.last, abs(last - first) > 30 else { return nil }
        let half = (first + last) / 2
        for i in 1..<values.count where (values[i - 1] - half) * (values[i] - half) <= 0 {
            let span = values[i] - values[i - 1]
            return Double(i - 1) + (span == 0 ? 0 : (half - values[i - 1]) / span)
        }
        return nil
    }

    /// The yellow window's bottom-left corner, as edge crossings of its
    /// green channel: the left edge along a row near its foot, the
    /// bottom edge down its middle. `near` is the corner at rest.
    static func windowCorner(_ px: Pixels, near: CGPoint, width span: Int = 40) -> CGPoint? {
        let row = Int(near.y) - 30
        let column = Int(near.x) + 200
        let xs = (Int(near.x) - span)...(Int(near.x) + span)
        let ys = (Int(near.y) - span)...(Int(near.y) + span)
        guard let left = crossing(xs.map { px.rgb($0, row).g }),
              let bottom = crossing(ys.map { px.rgb(column, $0).g }) else { return nil }
        return CGPoint(x: Double(xs.lowerBound) + left, y: Double(ys.lowerBound) + bottom)
    }

    /// The yellow window's corner as the observer shows the resting
    /// desktop: the resting screen scaled into the widened view.
    static var restingCorner: CGPoint {
        let m = Double(margin)
        let scale = 1 / (1 + 2 * m)
        let x = (yellowWindow.minX - Double(width) / 2) * scale + Double(width) / 2
        let y = (yellowWindow.maxY + m * Double(height)) * scale
        return CGPoint(x: x, y: y)
    }

    // MARK: Tests

    @Test("in the Duo the seated eye sees the desktop hold still from 110° to 75°")
    func duoObserverHolds() throws {
        // The Dock at the default knobs; the window corner with blur and
        // shade at 0 — a corner blurred over 7 px has no ±2 px position,
        // and the hold is geometry: the picture must not slide or shrink.
        let rig = try Self.makeRig(.duo)
        var docks: [Double: CGPoint] = [:]
        var corners: [Double: CGPoint] = [:]
        for angle in [110.0, 100, 90, 75] {
            let px = Self.pixels(try Self.renderObserver(rig, panel: try Self.renderPanel(rig, angle: angle), angle: angle))
            docks[angle] = Self.dockCentroid(px)
            let flat = try Self.renderPanel(rig, angle: angle, blur: 0, shade: 0)
            corners[angle] = Self.windowCorner(Self.pixels(try Self.renderObserver(rig, panel: flat, angle: angle)),
                                               near: Self.restingCorner)
        }
        let dock0 = try #require(docks[110])
        let corner0 = try #require(corners[110])
        #expect(abs(corner0.x - Self.restingCorner.x) < 2 && abs(corner0.y - Self.restingCorner.y) < 2,
                "the corner at rest is where the desktop puts it: \(corner0) vs \(Self.restingCorner)")
        for angle in [100.0, 90, 75] {
            let dock = try #require(docks[angle], "no Dock seen at \(angle)°")
            let corner = try #require(corners[angle], "no window corner seen at \(angle)°")
            #expect(abs(dock.x - dock0.x) <= 2 && abs(dock.y - dock0.y) <= 2,
                    "the Dock moved at \(angle)°: \(dock) vs \(dock0)")
            #expect(abs(corner.x - corner0.x) <= 2 && abs(corner.y - corner0.y) <= 2,
                    "the window corner moved at \(angle)°: \(corner) vs \(corner0)")
        }
    }

    @Test("in the Duo the glass is black by the time a seated eye loses it")
    func duoBlackNearShut() throws {
        let rig = try Self.makeRig(.duo)
        for angle in [30.0, 10] {
            let px = Self.pixels(try Self.renderPanel(rig, angle: angle))
            var brightest = 0.0
            for i in stride(from: 0, to: px.bytes.count, by: 4) {
                brightest = max(brightest, Double(max(px.bytes[i], px.bytes[i + 1], px.bytes[i + 2])))
            }
            #expect(brightest == 0, "\(angle)° should be black, brightest \(brightest)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the fold strips"))
    func strips() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for look in FoldLook.allCases {
            let rig = try Self.makeRig(look)
            var cells: [(Double, CGImage, CGImage)] = []
            var drift: [String] = []
            var yellow0: CGPoint?
            for angle in Self.angles {
                let panel = try Self.renderPanel(rig, angle: angle)
                let seen = try Self.renderObserver(rig, panel: panel, angle: angle)
                let px = Self.pixels(seen)
                // How far the seated eye sees the yellow window move.
                if let yellow = Self.yellowCentroid(px) {
                    if yellow0 == nil { yellow0 = yellow }
                    if let y0 = yellow0 {
                        drift.append(String(format: "%.0f° %+.1f,%+.1f px", angle, yellow.x - y0.x, yellow.y - y0.y))
                    }
                }
                let glass = try Self.image(panel)
                let eye = try Self.image(seen)
                cells.append((angle, glass, eye))
                let stem = String(format: "fold-%@-%.0f", look.rawValue, angle)
                try Self.writePNG(glass, to: dir.appendingPathComponent(stem + "-glass.png"))
                try Self.writePNG(eye, to: dir.appendingPathComponent(stem + "-eye.png"))
            }
            let title = look == .duo
                ? "Duo — the picture holds still for a seated eye; the glass softens and darkens away from the hinge"
                : "Room — the older portal room (Hold 100%)"
            let strip = try Self.makeStrip(cells, title: title)
            let url = dir.appendingPathComponent("fold-\(look.rawValue)-strip.png")
            try Self.writePNG(strip, to: url)
            print("fold proof: wrote \(url.path) — yellow window as the eye sees it: \(drift.joined(separator: "; "))")
        }
    }

    /// The Duo's reopen from the black hold: the picture held across the
    /// closed lid, the lid coming back up from 15° to 110° over a second,
    /// the fold following it from black to flat. Frames at equal steps of
    /// time; no clock drives anything but the lid.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the reopen strip"))
    func reopenStrip() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        var motion = FoldMotion()
        var ease = FoldGateEase()
        let dt = 1.0 / 60
        var cells: [(Double, CGImage, CGImage)] = []
        var captions: [(glass: String, eye: String)] = []
        let picks: Set<Int> = [0, 14, 24, 30, 36, 44, 52, 60]
        motion.feedDirect(FoldBlackout.releaseAngle)
        var now = 0.0
        motion.tick(at: now, dt: dt)
        for frame in 0...90 {
            now = Double(frame) * dt
            let u = min(1, Double(frame) / 60)
            let lid = FoldBlackout.releaseAngle + (Self.rest - FoldBlackout.releaseAngle) * (u * u * (3 - 2 * u))
            motion.feedDirect(lid)
            let drawn = motion.tick(at: now, dt: dt) ?? lid
            let delta = ease.tick(target: max(0, Self.rest - drawn) * .pi / 180, dt: dt)
            guard picks.contains(frame) else { continue }
            let glassAngle = Self.rest - delta * 180 / .pi
            let panel = try Self.renderPanel(rig, angle: glassAngle)
            let seen = try Self.renderObserver(rig, panel: panel, angle: lid)
            cells.append((glassAngle, try Self.image(panel), try Self.image(seen)))
            captions.append((glass: String(format: "%.2f s · glass %.0f°", now, glassAngle),
                             eye: String(format: "seated eye, lid at %.0f°", lid)))
        }
        #expect(abs((motion.angle ?? 0) - Self.rest) < 1.0)
        let title = "Duo reopen from the black hold: the lid comes back up from 15° to 110°, "
            + "and the fold follows it out of black to flat — no clock, only the lid"
        let url = dir.appendingPathComponent("fold-duo-reopen-strip.png")
        try Self.writePNG(try Self.makeStrip(cells, title: title, captions: captions), to: url)
    }

    /// A slow close, the case that used to stall in plateaus and lurch: the
    /// lid goes down at 6°/s, the sensor reports whole degrees, and the
    /// motion draws it. Five frames at equal steps of time; the glass angle
    /// is the motion's own, and each gap between frames is the same travel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the slow-close strip"))
    func slowCloseStrip() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        let speed = 6.0
        func lid(_ t: Double) -> Double { Self.rest - speed * max(0, t - 0.3) }
        let dt = 1.0 / 120
        var motion = FoldMotion()
        var nextPoll = 0.0
        var shown: [(t: Double, angle: Double)] = []
        let picks: [Double] = [2, 4, 6, 8, 10]
        var t = 0.0
        while t <= 10.01 {
            while nextPoll <= t + 1e-12 {
                motion.feed(FoldMotionTests.reading(lid, at: nextPoll), at: nextPoll)
                nextPoll += dt
            }
            let drawn = motion.tick(at: t, dt: dt) ?? Self.rest
            if picks.contains(where: { abs($0 - t) < dt / 2 }) { shown.append((t, drawn)) }
            t += dt
        }
        #expect(shown.count == picks.count)
        // Equal steps of time are equal steps of travel: within a degree.
        let steps = zip(shown, shown.dropFirst()).map { $0.0.angle - $0.1.angle }
        for step in steps { #expect(abs(step - 2 * speed) < 1.0, "a step of \(step)° in 2 s at \(speed)°/s") }
        var cells: [(Double, CGImage, CGImage)] = []
        var captions: [(glass: String, eye: String)] = []
        for frame in shown {
            let panel = try Self.renderPanel(rig, angle: frame.angle)
            let seen = try Self.renderObserver(rig, panel: panel, angle: lid(frame.t))
            cells.append((frame.angle, try Self.image(panel), try Self.image(seen)))
            captions.append((glass: String(format: "%.0f s · glass %.1f°", frame.t, frame.angle),
                             eye: String(format: "seated eye, lid %.0f°", lid(frame.t))))
        }
        let title = "Duo, a slow close (6°/s, whole-degree sensor): five frames two seconds apart, "
            + "each a twelve-degree step of the glass, no plateau"
        let url = dir.appendingPathComponent("fold-duo-slow-close-strip.png")
        try Self.writePNG(try Self.makeStrip(cells, title: title, captions: captions), to: url)
    }

    /// The overlay as the window server composites it: the panel at
    /// `alpha` over the live desktop. The toy sets that alpha on the window.
    static func composite(_ rig: Rig, panel: MTLTexture, alpha: Double) throws -> MTLTexture {
        let under = pixels(rig.desktop).bytes
        let over = pixels(panel).bytes
        var mixed = [UInt8](repeating: 255, count: under.count)
        for i in stride(from: 0, to: under.count, by: 4) {
            for c in 0..<3 {
                mixed[i + c] = UInt8(max(0, min(255, (Double(under[i + c]) * (1 - alpha) + Double(over[i + c]) * alpha).rounded())))
            }
        }
        let out = try makeTarget(rig.renderer.device)
        out.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: mixed, bytesPerRow: width * 4)
        return out
    }

    /// A fold that comes into view late: the lid closes at 40°/s from 110°
    /// and the first captured frame lands when it is 28° down (0.7 s in).
    /// The fold fades in on the lid's next degrees of travel, at the lid's
    /// real angle, rather than rushing to it. Frames every 80 ms from the
    /// landing; the opacity is the toy's own (the Duo's two-degree ramp
    /// times the entry fade).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the entry strip"))
    func entryStrip() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        let dt = 1.0 / 120
        let speed = 40.0
        let landed = 0.7
        func lid(_ t: Double) -> Double { Self.rest - speed * t }
        var motion = FoldMotion()
        var fade = FoldEntryFade()
        var cells: [(Double, CGImage, CGImage)] = []
        var captions: [(glass: String, eye: String)] = []
        var opacities: [Double] = []
        var t = 0.0
        var nextPoll = 0.0
        var shot = 0
        while t <= landed + 0.55 {
            while nextPoll <= t + 1e-12 {
                motion.feed(FoldMotionTests.reading(lid, at: nextPoll), at: nextPoll)
                nextPoll += dt
            }
            let drawn = motion.tick(at: t, dt: dt) ?? Self.rest
            if t >= landed {
                let delta = max(0, Self.rest - drawn) * .pi / 180
                if !fade.active, shot == 0 { fade.begin(delta: delta, at: t) }
                let entry = fade.opacity(delta: delta, at: t)
                let opacity = FoldDuoModel.alpha(delta: Self.rest - drawn) * entry
                if Int(((t - landed) / dt).rounded()) % 10 == 0 {
                    let panel = try Self.renderPanel(rig, angle: drawn)
                    let shown = try Self.composite(rig, panel: panel, alpha: opacity)
                    let seen = try Self.renderObserver(rig, panel: shown, angle: lid(t))
                    cells.append((drawn, try Self.image(shown), try Self.image(seen)))
                    captions.append((glass: String(format: "%.2f s · lid %.0f° · overlay %.0f%%", t, lid(t), opacity * 100),
                                     eye: "seated eye"))
                    opacities.append(opacity)
                    shot += 1
                }
            }
            t += dt
        }
        #expect(opacities.first == 0, "the landing frame is the live desktop")
        #expect(opacities.last == 1)
        for pair in zip(opacities, opacities.dropFirst()) {
            #expect(pair.1 >= pair.0, "the fold only ever comes in")
        }
        let title = "Duo, first frame lands late (lid already 28° down): the fold comes into view "
            + "on the lid's travel, at the lid's real angle, with no rush"
        let url = dir.appendingPathComponent("fold-duo-entry-strip.png")
        try Self.writePNG(try Self.makeStrip(cells, title: title, captions: captions), to: url)
    }

    /// A reopen that stops short of where the lid rested: 110°, down to
    /// 80°, back up to 104°. The 6° fold follows the lid for a second of
    /// stillness, then 104° becomes the rest and the fold unwinds from
    /// the reference it was drawing, so the screen ends clean at the lid's
    /// own angle instead of holding a soft, dark, shifted top. Driven by
    /// the real `MoveAnchor` and `FoldGateEase` at 60 Hz.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the reopen-settle strip"))
    func reopenSettleStrip() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        var anchor = MoveAnchor()
        anchor.armThreshold = 3
        anchor.feed(Self.rest, at: 0)
        for (i, dip) in [95.0, 80, 90, 100].enumerated() {
            anchor.feed(dip, at: Double(i + 1) * 0.1)
        }
        let lid = 104.0
        let parkedAt = 0.5
        var chase = FoldGateEase()
        var cells: [(Double, CGImage, CGImage)] = []
        var captions: [(glass: String, eye: String)] = []
        let picks: Set<Int> = [0, 30, 59, 60, 66, 72, 90]
        for frame in 0...90 {
            let t = parkedAt + Double(frame) / 60
            anchor.feed(lid, at: t)
            let reference = anchor.anchor ?? Self.rest
            let delta = chase.tick(target: max(0, reference - lid) * .pi / 180, dt: 1.0 / 60)
            guard picks.contains(frame) else { continue }
            let drawn = Self.rest - delta * 180 / .pi
            let panel = try Self.renderPanel(rig, angle: drawn)
            let seen = try Self.renderObserver(rig, panel: panel, angle: lid)
            cells.append((drawn, try Self.image(panel), try Self.image(seen)))
            let clock = String(format: "%.2f s", t - parkedAt)
            let glass = String(format: "%@ · glass %.0f°, rest %.0f°", clock, drawn, reference)
            captions.append((glass: glass, eye: "seated eye, lid at 104°"))
        }
        #expect(anchor.anchor == lid, "the stopped reopen is the new rest")
        #expect(chase.value == 0, "and the fold has unwound")
        let title = "Duo reopen that stops short — rested at 110°, dipped to 80°, back to 104°: "
            + "the fold follows for 1 s of stillness, then 104° is the rest and it unwinds"
        let url = dir.appendingPathComponent("fold-duo-reopen-settle-strip.png")
        try Self.writePNG(try Self.makeStrip(cells, title: title, captions: captions), to: url)
    }

    /// What one Duo frame costs the GPU, drawn at the 14-inch panel's own
    /// size (3024×1964, the overlay's drawable) from the 1x picture the
    /// capture used to film and from the Retina one it films now, with
    /// the Duo blur: the median of five batches of 40 draws back to back at
    /// each lid angle, after a warm-up batch. Written to `fold-duo-gpu.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to measure the Duo's GPU cost"))
    func duoGPUCost() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panelWidth = 3024, panelHeight = 1964
        var lines: [String] = []
        for scale in [1, 2] {
            let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
            renderer.look = .duo
            #expect(renderer.setFullFrame(try Self.desktop(scale: scale)))
            let out = try Self.makeTarget(renderer.device, width: panelWidth, height: panelHeight)
            let size = CGSize(width: panelWidth, height: panelHeight)
            let picture = "\(Self.width * scale)x\(Self.height * scale)"
            let pyramid = renderer.duoPyramid.map { "\($0.mipmapLevelCount) levels, \($0.allocatedSize / 1_000_000) MB" } ?? "none"
            var medians: [String] = []
            for angle in [100.0, 90, 75, 60] {
                FoldDuoModel.apply(to: &renderer.params, reference: Self.rest, theta: angle, hold: 1,
                                   perspective: 0.6, blur: 0.6, shade: 0.67, fadeLength: 0.55,
                                   reduceMotion: false)
                _ = renderer.gpuTimePerFrame(to: out, size: size, frames: 40)
                var times: [Double] = []
                for _ in 0..<5 {
                    let time = try #require(renderer.gpuTimePerFrame(to: out, size: size, frames: 40))
                    times.append(time * 1000)
                }
                times.sort()
                medians.append(String(format: "%.0f° %.3f ms", angle, times[times.count / 2]))
            }
            let label = "front"
            lines.append("picture \(picture) (pyramid \(pyramid)), \(label) blur, drawn at "
                         + "\(panelWidth)x\(panelHeight): " + medians.joined(separator: ", "))
        }
        let report = lines.joined(separator: "\n") + "\n"
        print("fold proof: GPU per Duo frame\n" + report)
        try report.write(to: dir.appendingPathComponent("fold-duo-gpu.txt"), atomically: true, encoding: .utf8)
    }

    /// The checker window as the seated eye sees it mid-fold: its mean
    /// brightness, 0…255, over the cells (its title bar left out). Sharp,
    /// its 20 and 250 cells average 135 in the numbers and about 184 in
    /// light, which is where a blur that mixes light lands it.
    static func checkerMean(_ px: Pixels) -> Double {
        let m = Double(margin)
        let scale = 1 / (1 + 2 * m)
        let box = CGRect(x: checkerWindow.minX + 20, y: checkerWindow.minY + 40,
                         width: checkerWindow.width - 40, height: checkerWindow.height - 60)
        let x0 = Int(((box.minX - Double(width) / 2) * scale + Double(width) / 2).rounded())
        let x1 = Int(((box.maxX - Double(width) / 2) * scale + Double(width) / 2).rounded())
        let y0 = Int(((box.minY + m * Double(height)) * scale).rounded())
        let y1 = Int(((box.maxY + m * Double(height)) * scale).rounded())
        var sum = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = px.rgb(x, y)
                sum += (c.r + c.g + c.b) / 3
                n += 1
            }
        }
        return sum / max(1, n)
    }

    /// The checker window's mean brightness as the seated eye sees it, at
    /// rest and mid-fold, with the default Shade and with Shade 0 (blur
    /// alone). Written to `fold-duo-checker.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to measure the checker window"))
    func checkerMeasurement() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        var lines: [String] = []
        for shade in [0.67, 0] {
            var cells: [String] = []
            for angle in [110.0, 90, 80, 75] {
                let panel = try Self.renderPanel(rig, angle: angle, shade: shade)
                let seen = Self.pixels(try Self.renderObserver(rig, panel: panel, angle: angle))
                cells.append(String(format: "%.0f° %.1f", angle, Self.checkerMean(seen)))
            }
            let label = "front"
            lines.append(String(format: "%@ blur, shade %.2f: ", label, shade) + cells.joined(separator: ", "))
        }
        let report = lines.joined(separator: "\n") + "\n"
        print("fold proof: checker window mean as the eye sees it\n" + report)
        try report.write(to: dir.appendingPathComponent("fold-duo-checker.txt"), atomically: true, encoding: .utf8)
    }

    /// The capture's resolution at the hinge: the same fold drawn on the
    /// 14-inch panel (3024×1964) from the 1x picture the capture used to
    /// film and from the Retina picture it films now, cropped to the text
    /// above the Dock at 1:1, at rest and two degrees in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the resolution comparison"))
    func resolutionComparison() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panelWidth = 3024, panelHeight = 1964
        let crop = CGRect(x: Self.hingeText.minX * 2 - 20, y: Self.hingeText.minY * 2 - 20,
                          width: 1100, height: Self.hingeText.height * 2 + 40)
        var rows: [(String, CGImage)] = []
        for angle in [109.9, 108.0] {
            for scale in [1, 2] {
                let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
                renderer.look = .duo
                #expect(renderer.setFullFrame(try Self.desktop(scale: scale)))
                FoldDuoModel.apply(to: &renderer.params, reference: Self.rest, theta: angle, hold: 1,
                                   perspective: 0.6, blur: 0.6, shade: 0.67, fadeLength: 0.55,
                                   reduceMotion: false)
                let out = try Self.makeTarget(renderer.device, width: panelWidth, height: panelHeight)
                #expect(renderer.render(to: out, size: CGSize(width: panelWidth, height: panelHeight)))
                let full = try Self.image(out)
                let picture: String = scale == 1 ? "1512×982 (0.10.0)" : "3024×1964 (now)"
                let label = String(format: "%@ picture, glass %.1f°", picture, angle)
                rows.append((label, try #require(full.cropping(to: crop))))
            }
        }
        try Self.writePNG(try Self.stack(rows, title: "Duo on the 14-inch panel at 1:1, the text above the Dock"),
                          to: dir.appendingPathComponent("fold-duo-resolution-compare.png"))
    }

    /// Two full-size pictures side by side under their labels.
    static func pair(_ left: CGImage, _ right: CGImage, left leftLabel: String,
                     right rightLabel: String) throws -> CGImage {
        let pad = 12, label = 26
        let w = left.width + right.width + 3 * pad
        let h = max(left.height, right.height) + label + 2 * pad
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        let top = h - pad - label
        (leftLabel as NSString).draw(at: CGPoint(x: pad, y: top + 3), withAttributes: attrs)
        (rightLabel as NSString).draw(at: CGPoint(x: 2 * pad + left.width, y: top + 3), withAttributes: attrs)
        ctx.draw(left, in: CGRect(x: pad, y: top - left.height, width: left.width, height: left.height))
        ctx.draw(right, in: CGRect(x: 2 * pad + left.width, y: top - right.height,
                                   width: right.width, height: right.height))
        return try #require(ctx.makeImage())
    }

    /// Pictures stacked top to bottom at 1:1, each under its label.
    static func stack(_ rows: [(String, CGImage)], title: String) throws -> CGImage {
        let pad = 12, label = 26, head = 34
        let widest: Int = rows.map { $0.1.width }.max() ?? 1
        let w = widest + 2 * pad
        var rowsHeight = 0
        for row in rows { rowsHeight += row.1.height + label + pad }
        let h = head + rowsHeight + pad
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        (title as NSString).draw(at: CGPoint(x: pad, y: h - head + 8), withAttributes: attrs)
        var top = h - head
        for row in rows {
            (row.0 as NSString).draw(at: CGPoint(x: pad, y: top - label + 4), withAttributes: attrs)
            top -= label
            ctx.draw(row.1, in: CGRect(x: pad, y: top - row.1.height, width: row.1.width, height: row.1.height))
            top -= row.1.height + pad
        }
        return try #require(ctx.makeImage())
    }

    /// A Settings search that lands on a row the current look hides —
    /// Frost in the Duo, Goes dark over in the Room — draws it switched
    /// off, saying which look has it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the card proofs"))
    func searchLandsOnALookOnlyRow() throws {
        for (look, row) in [(FoldLook.duo, "Frost"), (FoldLook.room, "Goes dark over")] {
            var toys = ToysState()
            toys.fold.look = look
            let core = CoreModel()
            let settings = SettingsStore(core: core)
            let store = ToysStore(core: core, settings: settings, state: toys,
                                  cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
            settings.toys = store
            let fold = try #require(store.fold)
            let hit = try #require(settings.searchEntries.first { $0.card == "fold" && $0.title == row })
            settings.reveal(hit)
            let probe = NSHostingView(rootView: fold.controls.environment(settings).frame(width: 560))
            probe.layoutSubtreeIfNeeded()
            let tall = ceil(probe.fittingSize.height) + 90
            for dark in [false, true] {
                let view = Form { Section { fold.controls } }
                    .formStyle(.grouped)
                    .environment(settings)
                    .frame(width: 640, height: tall)
                try ProofRender.write(view, size: CGSize(width: 640, height: tall),
                                      name: "fold-card-search-\(look.rawValue)-\(dark ? "dark" : "light")",
                                      dark: dark)
            }
            withExtendedLifetime(store) {}
        }
    }

    // MARK: Pictures

    static func image(_ texture: MTLTexture) throws -> CGImage {
        let px = pixels(texture)
        let provider = try #require(CGDataProvider(data: Data(px.bytes) as CFData))
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return try #require(CGImage(
            width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: px.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    /// One column per angle: the panel on top, the observer below, each
    /// labelled (by its angle, or by `captions` when given), under a title.
    static func makeStrip(_ cells: [(Double, CGImage, CGImage)], title: String,
                          captions: [(glass: String, eye: String)]? = nil) throws -> CGImage {
        let cw = 378, ch = 245, pad = 10, head = 34, label = 22
        let w = cells.count * cw + (cells.count + 1) * pad
        let h = head + 2 * (label + ch + pad) + pad
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        func text(_ s: String, at p: CGPoint, size: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
            ]
            (s as NSString).draw(at: p, withAttributes: attrs)
        }
        text(title, at: CGPoint(x: pad, y: h - head + 8), size: 16)
        for (i, cell) in cells.enumerated() {
            let x = pad + i * (cw + pad)
            let panelY = h - head - label - ch
            let observerY = panelY - pad - label - ch
            let caption = captions.map { $0[i] }
            let glassLabel = caption?.glass ?? String(format: "%.0f° glass", cell.0)
            let eyeLabel = caption?.eye ?? String(format: "%.0f° seated eye", cell.0)
            text(glassLabel, at: CGPoint(x: x, y: panelY + ch + 3), size: 13)
            ctx.draw(cell.1, in: CGRect(x: x, y: panelY, width: cw, height: ch))
            text(eyeLabel, at: CGPoint(x: x, y: observerY + ch + 3), size: 13)
            ctx.draw(cell.2, in: CGRect(x: x, y: observerY, width: cw, height: ch))
        }
        return try #require(ctx.makeImage())
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
