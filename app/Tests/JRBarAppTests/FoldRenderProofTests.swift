import AppKit
import CoreVideo
import Foundation
import JRBarCore
import MetalKit
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
@Suite("Fold render proof")
@MainActor
struct FoldRenderProofTests {
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
    /// far stream sees: the wallpaper alone) into a capture-shaped frame.
    static func desktop(wallpaperOnly: Bool = false) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &maybeBuffer) == kCVReturnSuccess)
        let buffer = try #require(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        // Top-left origin, like the capture.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        drawWallpaper(ctx)
        guard !wallpaperOnly else { return buffer }
        drawTextWindow(ctx)
        drawCheckerWindow(ctx)
        fill(ctx, yellowWindow, 245, 225, 70)
        drawMenuBar(ctx)
        drawDock(ctx)
        return buffer
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

    static func makeTarget(_ device: MTLDevice) throws -> MTLTexture {
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
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * FoldRenderProofTests.width + x) * 4
            return (Double(bytes[i + 2]), Double(bytes[i + 1]), Double(bytes[i]))
        }
    }

    static func pixels(_ texture: MTLTexture) -> Pixels {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return Pixels(bytes: bytes)
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

    /// The Duo's reopen from the black hold, at its worst: the lid is
    /// already back at rest when the first frame lands, so the whole
    /// unfold plays on the chase. Frames every 50 ms from the release;
    /// the first is still black and the picture comes up out of it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the reopen strip"))
    func reopenStrip() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = try Self.makeRig(.duo)
        var chase = DeltaChase()
        chase.reset(to: FoldDuoModel.reopenDelta(reference: Self.rest, perspective: 0.6))
        var cells: [(Double, CGImage, CGImage)] = []
        for frame in 0...30 {
            let drawn = Self.rest - chase.tick(target: 0, dt: 1.0 / 60) * 180 / .pi
            guard frame % 3 == 0, cells.count < 7 else { continue }
            let panel = try Self.renderPanel(rig, angle: drawn)
            // The lid itself is at rest: the eye sees the glass flat.
            let seen = try Self.renderObserver(rig, panel: panel, angle: Self.rest)
            cells.append((drawn, try Self.image(panel), try Self.image(seen)))
        }
        let title = "Duo reopen — the lid is back at 110° as the first frame lands; the glass unfolds from black, one cell per 50 ms"
        let url = dir.appendingPathComponent("fold-duo-reopen-strip.png")
        try Self.writePNG(try Self.makeStrip(cells, title: title), to: url)
    }

    // MARK: Pictures

    static func image(_ texture: MTLTexture) throws -> CGImage {
        let px = pixels(texture)
        let provider = try #require(CGDataProvider(data: Data(px.bytes) as CFData))
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    /// One column per angle: the panel on top, the observer below, each
    /// labelled, under a title.
    static func makeStrip(_ cells: [(Double, CGImage, CGImage)], title: String) throws -> CGImage {
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
            text(String(format: "%.0f° glass", cell.0), at: CGPoint(x: x, y: panelY + ch + 3), size: 13)
            ctx.draw(cell.1, in: CGRect(x: x, y: panelY, width: cw, height: ch))
            text(String(format: "%.0f° seated eye", cell.0), at: CGPoint(x: x, y: observerY + ch + 3), size: 13)
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
