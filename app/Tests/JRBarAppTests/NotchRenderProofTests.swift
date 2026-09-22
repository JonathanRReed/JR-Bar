import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
import JRBarLEDS
@testable import JRBarApp

/// Render proof for the notch wrap: the tray silhouette against a fake
/// bezel at 4×, so a human can eyeball that the corners match the
/// hardware's own radius and the marks centre inside the bezel — the
/// thing screenshots keep judging. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write /tmp/notch-proof PNGs.
@Suite("Notch wrap render proof")
@MainActor
struct NotchRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func expandingSilhouette() throws {
        let directory = URL(fileURLWithPath: "/tmp/notch-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for height: CGFloat in [36, 76, 180] {
            let view = ZStack(alignment: .top) {
                Color(white: 0.24)
                NotchSilhouette(notchDepth: 32, restingRadius: 8)
                    .fill(.black)
                    .frame(width: height == 36 ? 260 : 340, height: height)
            }.frame(width: 400, height: 210)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("silhouette-\(Int(height)).png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func combinedUnderlight() throws {
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 500, height: 60))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 213,
            leftExtent: 60, rightExtent: 76)
        view.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Working", provider: "claude"),
            right: ScreenBarWingSlot(text: "Codex", provider: "codex", meter: 0.5))
        view.menuHandleRevealed = false
        view.islandFrame = CGRect(x: 157.5, y: 28, width: 185, height: 32)
        view.relayout()
        view.display(colors: Array(repeating: RGB(r: 1, g: 0.25, b: 0.25), count: 8))
        view.layoutSubtreeIfNeeded()
        let context = try #require(CGContext(
            data: nil, width: 2000, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 4, y: 4)
        context.setFillColor(CGColor(gray: 0.24, alpha: 1))
        context.fill(view.bounds)
        view.layer?.render(in: context)
        // Offscreen CALayer rendering omits SwiftUI's hosted content.
        // Render the actual wings view into the same coordinate space.
        let hosting = try #require(view.subviews.compactMap {
            $0 as? NSHostingView<ScreenBarWingsView>
        }.first)
        let wings = ImageRenderer(content: hosting.rootView.frame(width: 500, height: 60))
        wings.scale = 4
        context.draw(try #require(wings.cgImage), in: view.bounds)
        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/notch-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("combined-underlight.png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func expandedCardFooterClearsHigherHousing() throws {
        let scale: CGFloat = 4
        let width: CGFloat = 380
        let notchDepth: CGFloat = 32
        let topInset: CGFloat = 38
        let model = makeTestCardModel()
        model.pinned = true
        model.focus = ScreenBarFocus(style: nil, label: "Codex", word: "Working",
                                     clickSession: nil)

        // Measure and render the real card, including the Agent Overview
        // footer. The test model has every runtime reader disabled.
        let renderedIsland = try Self.renderedIsland(
            model: model, width: width, topInset: topInset,
            notchDepth: notchDepth, bottomAdjustment: 0, scale: scale)
        let islandHeight = renderedIsland.height
        let islandPixels = renderedIsland.bitmap
        try #require(Self.unsupportedPlaceholderFraction(in: islandPixels) < 0.05,
                     "native card render produced AppKit's unsupported-view placeholder")
        let islandImage = try #require(islandPixels.cgImage)
        try Self.requireTopDownBitmapCoordinates(scale: scale)
        let renderedFooterClearance = try Self.footerInkClearance(
            in: islandPixels, scale: scale)

        // Negative control for the old 16-pt total inset. Reducing both the
        // card's reported height and the island frame by 14 points must put
        // the same real footer inside the Screen Bar housing overlap.
        let oldInsetIsland = try Self.renderedIsland(
            model: model, width: width, topInset: topInset,
            notchDepth: notchDepth, bottomAdjustment: -14, scale: scale)
        try #require(Self.unsupportedPlaceholderFraction(in: oldInsetIsland.bitmap) < 0.05,
                     "negative-control card render produced AppKit's unsupported-view placeholder")
        let oldFooterClearance = try Self.footerInkClearance(
            in: oldInsetIsland.bitmap, scale: scale)
        #expect(oldInsetIsland.height == islandHeight - 14,
                "negative control must reproduce the old 14-point-shorter island frame")

        let canvasSize = CGSize(
            width: width,
            height: islandHeight + ScreenBarDesign.bandHeight
                + ScreenBarGeometry.coupledChin + ScreenBarGeometry.coupledSlack)
        let islandFrame = CGRect(x: 0, y: canvasSize.height - islandHeight,
                                 width: width, height: islandHeight)
        let screenBar = ScreenBarView(frame: CGRect(origin: .zero, size: canvasSize))
        screenBar.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: notchDepth, bandSpan: width,
            leftExtent: 40, rightExtent: 40)
        screenBar.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Working", provider: "claude"),
            right: ScreenBarWingSlot(text: "Codex", provider: "codex"))
        screenBar.islandFrame = islandFrame
        screenBar.relayout()
        screenBar.display(colors: Array(repeating: RGB(r: 0.25, g: 0.65, b: 1), count: 8))
        screenBar.layoutSubtreeIfNeeded()
        let screenBarPixels = try Self.nativeBitmap(of: screenBar, scale: scale)
        try #require(Self.unsupportedPlaceholderFraction(in: screenBarPixels) < 0.05,
                     "native Screen Bar render produced AppKit's unsupported-view placeholder")
        let screenBarImage = try #require(screenBarPixels.cgImage)

        let housing = try #require(screenBar.housingRect)
        let overlap = housing.maxY - islandFrame.minY
        #expect(overlap == NotchSilhouetteGeometry.maximumExpandedRadius)
        #expect(NotchCardView.islandBottomContentInset >= overlap + 2,
                "the real Agent Overview footer ink clears the higher Screen Bar housing")
        #expect(renderedFooterClearance >= overlap + 1.5,
                "rendered Agent Overview pixels remain above the composited housing")
        #expect(oldFooterClearance < overlap + 1.5,
                "negative control: the old 16-pt inset must fail the rendered footer clearance")
        print("notch footer clearance current=\(renderedFooterClearance) "
              + "oldInset=\(oldFooterClearance) housingOverlap=\(overlap)")

        let pixelsWide = Int(ceil(canvasSize.width * scale))
        let pixelsHigh = Int(ceil(canvasSize.height * scale))
        let context = try #require(CGContext(
            data: nil, width: pixelsWide, height: pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.24, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvasSize))
        context.draw(islandImage, in: islandFrame)
        // Actual desktop order: the Screen Bar panel is above the island.
        // Native caching captures its CALayers and hosted SwiftUI wings
        // together, avoiding ImageRenderer's AppKit placeholder.
        context.draw(screenBarImage, in: CGRect(origin: .zero, size: canvasSize))

        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/notch-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("expanded-card-composite.png"))
    }

    /// Five frames of the island's expand morph, driven by the real
    /// `NotchFrameSpring` at the Alcove constants — a human can watch
    /// the silhouette lead and check the ~2% overshoot lands soft.
    /// Rendered through the native `NSHostingView`+`cacheDisplay` path —
    /// ImageRenderer's offscreen SwiftUI pipeline emits its
    /// unsupported-view placeholder here and a placeholder is not
    /// evidence. Off by default; `JRBAR_RENDER_PROOF=1` writes
    /// /tmp/jrbar-audit/notch-expand-*.png.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/jrbar-audit PNGs"))
    func expandFrames() throws {
        let directory = URL(fileURLWithPath: "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = makeTestCardModel()
        model.pinned = true
        model.focus = ScreenBarFocus(style: nil, label: "Codex", word: "Working",
                                     clickSession: nil)
        model.contentRevealed = true

        let scale: CGFloat = 2
        let width: CGFloat = 380
        let topInset: CGFloat = 38
        let notchDepth: CGFloat = 32
        let card = NotchCardView(model: model, style: .island, width: width)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let expandedHeight = topInset + ceil(probe.fittingSize.height)

        // Idle ≈ the wide capsule strip; the card is the expand target.
        let idle = CGRect(x: 0, y: 0, width: 285, height: notchDepth)
        let grown = CGRect(x: 0, y: 0, width: width, height: expandedHeight)

        var heights: [CGFloat] = []
        var inks: [Double] = []
        for t in [0.0, 0.1, 0.2, 0.3, 0.5] {
            var spring = NotchFrameSpring(at: idle)
            spring.retarget(grown, motion: NotchMotion.expand)
            _ = spring.integrate(dt: t)
            let frame = spring.frame
            heights.append(frame.height)
            let scene = ZStack(alignment: .top) {
                Color(white: 0.24)
                ZStack(alignment: .top) {
                    NotchSilhouette(notchDepth: notchDepth, restingRadius: 8)
                        .fill(.black)
                    card.padding(.top, topInset)
                }
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .clipped()
            }
            .frame(width: width + 40, height: expandedHeight + 24)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: scene)
            hosting.frame = CGRect(x: 0, y: 0, width: width + 40,
                                   height: expandedHeight + 24)
            let bitmap = try Self.nativeBitmap(of: hosting, scale: scale)
            try #require(Self.unsupportedPlaceholderFraction(in: bitmap) < 0.05,
                         "expand frame at t=\(t) rendered AppKit's unsupported-view placeholder")
            inks.append(Self.darkInkFraction(in: bitmap))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = String(format: "notch-expand-%03d.png", Int(t * 1000))
            try png.write(to: directory.appendingPathComponent(name))
        }

        // The morph itself is the claim: strictly growing through the
        // first three frames, and the ink footprint — the black
        // silhouette's painted share of the canvas — grows with it,
        // proving real pixels landed at every t, not a stamp.
        #expect(heights[0] == notchDepth)
        #expect(heights[1] > heights[0])
        #expect(heights[2] > heights[1])
        #expect(heights[3] > heights[2])
        #expect(heights[4] >= expandedHeight * 0.97,
                "t=0.5 frame should be at/near the grown card (\(heights) vs \(expandedHeight))")
        #expect(inks[0] > 0, "t=0 frame painted no silhouette")
        #expect(inks[4] > inks[0] * 5,
                "the grown card must paint far more black than the idle strip")
        print("notch expand heights=\(heights.map { Int($0.rounded()) }) "
              + "inks=\(inks.map { ($0 * 1000).rounded() / 1000 })")
    }

    /// The share of sampled pixels that are dark ink — the black
    /// island silhouette against the grey canvas. A placeholder or an
    /// empty render has ~none; a growing island has a growing share.
    private static func darkInkFraction(in bitmap: NSBitmapImageRep) -> Double {
        var ink = 0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                sampled += 1
                if color.alphaComponent > 0.5,
                   max(color.redComponent, color.greenComponent,
                       color.blueComponent) < 0.15 {
                    ink += 1
                }
            }
        }
        return sampled == 0 ? 0 : Double(ink) / Double(sampled)
    }

    private static func nativeBitmap(of view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func renderedIsland(
        model: NotchCardModel,
        width: CGFloat,
        topInset: CGFloat,
        notchDepth: CGFloat,
        bottomAdjustment: CGFloat,
        scale: CGFloat
    ) throws -> (bitmap: NSBitmapImageRep, height: CGFloat) {
        let card = NotchCardView(model: model, style: .island, width: width)
            .padding(.bottom, bottomAdjustment)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let height = topInset + ceil(probe.fittingSize.height)
        let island = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: notchDepth, restingRadius: 8).fill(.black)
            card.padding(.top, topInset)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: island)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return (try nativeBitmap(of: hosting, scale: scale), height)
    }

    /// Native cached bitmaps address rows from the top. Prove that mapping
    /// before converting distance from the bottom into a bitmap row.
    private static func requireTopDownBitmapCoordinates(scale: CGFloat) throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let bottomMarker = CALayer()
        bottomMarker.backgroundColor = NSColor.systemRed.cgColor
        bottomMarker.frame = CGRect(x: 0, y: 0, width: 12, height: 3)
        view.layer?.addSublayer(bottomMarker)
        let bitmap = try nativeBitmap(of: view, scale: scale)
        let low = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 1))
        let high = try #require(bitmap.colorAt(
            x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 2))
        try #require(high.redComponent > 0.5 && high.redComponent > high.blueComponent,
                     "the final bitmap rows did not contain the bottom marker")
        try #require(low.redComponent < 0.2 && low.greenComponent < 0.2,
                     "bitmap orientation probe did not keep its top edge black")
    }

    private static func footerInkClearance(
        in bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) throws -> CGFloat {
        let scanHeight = min(bitmap.pixelsHigh, Int(80 * scale))
        var lowestInk: Int?
        for y in 0..<scanHeight {
            for x in Int(8 * scale)..<(bitmap.pixelsWide - Int(8 * scale)) {
                guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y), color.alphaComponent > 0.5 else {
                    continue
                }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.08 {
                    lowestInk = y
                    break
                }
            }
            if lowestInk != nil { break }
        }
        return CGFloat(try #require(
            lowestInk, "no Agent Overview footer ink found in the bottom 80 points")) / scale
    }

    /// AppKit's unsupported offscreen representation is a yellow field
    /// with a large red prohibition mark. Reject it before any pixel test
    /// can accidentally treat that artwork as card content.
    private static func unsupportedPlaceholderFraction(in bitmap: NSBitmapImageRep) -> Double {
        var suspicious = 0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                sampled += 1
                let yellow = color.redComponent > 0.7 && color.greenComponent > 0.5
                    && color.blueComponent < 0.3
                let red = color.redComponent > 0.7 && color.greenComponent < 0.3
                    && color.blueComponent < 0.3
                if yellow || red { suspicious += 1 }
            }
        }
        return sampled == 0 ? 1 : Double(suspicious) / Double(sampled)
    }

    /// The scene the screenshots crop: a 185-pt bezel at the top of a
    /// 500-pt window, our tray wrapping it flush with the bezel's bottom
    /// edge. The bezel is drawn as the test's own black bar — what the
    /// hardware shows.
    private static func scene(_ model: ScreenBarWingsModel) -> some View {
        ZStack(alignment: .top) {
            Color(white: 0.24)   // the menu bar's field
            VStack(spacing: 0) {
                // The bezel: screen top, square where it meets the lid,
                // bottom corners at the hardware's own ~8 pt.
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8,
                                       bottomTrailingRadius: 8, topTrailingRadius: 0,
                                       style: .continuous)
                    .fill(.black)
                    .frame(width: 185, height: 32)
                Spacer()
            }
            ScreenBarWingsView(model: model)
        }
        .frame(width: 500, height: 48)
        .environment(\.colorScheme, .dark)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/notch-proof PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: "/tmp/notch-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The claim the geometry answers for a 185-pt slot in a
        // 500-pt window: the ears hug the bezel at its own depth —
        // flush with the hardware's bottom edge, 36 pt of wing.
        let size = NSSize(width: 500, height: 48)
        let depth: CGFloat = 32 + ScreenBarGeometry.wingEarDrop
        let leftRect = CGRect(x: 157.5 - 36, y: size.height - depth, width: 36, height: depth)
        let rightRect = CGRect(x: 342.5, y: size.height - depth, width: 36, height: depth)

        for (name, left, right, corner) in [
            ("standard-8pt", ScreenBarWingSlot(text: "Working", provider: "claude"),
             ScreenBarWingSlot(text: "Claude 72%", provider: "claude", meter: 0.72),
             NotchProfile.standardCornerRadius),
            ("custom-4pt", ScreenBarWingSlot(text: "Working", provider: "claude"),
             ScreenBarWingSlot(text: "Claude 72%", provider: "claude", meter: 0.72),
             CGFloat(4)),
            ("notice", nil,
             ScreenBarWingSlot(text: "Charging · 84%", symbol: "bolt.fill", tone: .attention),
             NotchProfile.standardCornerRadius),
        ] as [(String, ScreenBarWingSlot?, ScreenBarWingSlot?, CGFloat)] {
            let model = ScreenBarWingsModel()
            model.viewHeight = size.height
            model.notchCorner = corner
            // The bezel's side edges in tray-local x: 185-pt bezel centred
            // in the 500-pt scene → 157.5 / 342.5, less the tray's origin.
            // An unclaimed side ends the tray at its bezel edge, as
            // `updateWingChips` builds it — that side must grow no lobe.
            let trayMinX = left == nil ? 157.5 : leftRect.minX
            let trayMaxX = right == nil ? 342.5 : rightRect.maxX
            let trayRect = CGRect(x: trayMinX, y: size.height - depth,
                                  width: trayMaxX - trayMinX, height: depth)
            model.tray = trayRect
            model.left = left.map { ($0, leftRect) }
            model.right = right.map { ($0, rightRect) }

            let renderer = ImageRenderer(content: Self.scene(model))
            renderer.scale = 4
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("render failed for \(name)")
                continue
            }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
