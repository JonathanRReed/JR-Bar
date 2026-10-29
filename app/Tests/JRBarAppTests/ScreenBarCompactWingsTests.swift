import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
import JRBarCore
import JRBarLEDS
import JRBarUI
@testable import JRBarApp

@MainActor
@Suite("Compact Notch shoulders", .renderProofAppearance)
struct ScreenBarCompactWingsTests {
    nonisolated static let renderEnabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private func view() -> ScreenBarView {
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 480, height: 64))
        view.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                                                 bandSpan: 480, leftExtent: 132, rightExtent: 132)
        return view
    }

    @Test("Codex retains visible ink while native menu items are revealed",
          .enabled(if: renderEnabled), arguments: [false, true])
    func persistentCodexGlyph(menuRevealed: Bool) throws {
        let bar = view()
        bar.earRecoveryReduceMotionOverride = true
        bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"))
        if menuRevealed {
            let edge = try #require(bar.rightWingRect).minX
            bar.rightEarLimit = edge
        }
        let left = try #require(bar.leftWingRect)
        #expect(left.width == 19)
        let scene = ZStack(alignment: .top) {
            ProofDesktop(dark: true)
            HostedBar(view: bar).frame(width: bar.bounds.width, height: bar.bounds.height)
        }
        let bitmap = try ProofRender.render(scene.frame(width: 480, height: 100),
            size: CGSize(width: 480, height: 100), scale: 2, settle: 0.05)
        let x0 = Int(ceil(left.minX * 2)) + 2
        let x1 = Int(floor(left.maxX * 2)) - 2
        let y0 = Int((bar.bounds.height - left.maxY) * 2) + 4
        let y1 = Int((bar.bounds.height - left.minY) * 2) - 4
        var brightPixels = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 {
                    brightPixels += 1
                }
            }
        }
        #expect(brightPixels > 10, "An active provider must not become an empty black cap")
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try png.write(to: ProofRender.directory.appendingPathComponent("persistent-codex-menu-\(menuRevealed).png"))
    }

    @Test("bare provider glyphs adapt without changing shoulder widths or privacy groups")
    func providerGlyphSizes() throws {
        let slot = ScreenBarWingSlot(text: "Working", provider: "codex")
        #expect(slot.minimumMarkWidth == 13)
        #expect(ScreenBarWingSlot.providerMarkSize(width: 13) == 9)
        #expect(ScreenBarWingSlot.providerMarkSize(width: 17) == 13)
        #expect(ScreenBarWingSlot.providerMarkSize(width: 32) == 13)
        #expect(slot.preferredEarWidth == 32)
        var privateSlot = slot
        privateSlot.sensors = NotchSensorState(microphoneInUse: false, cameraInUse: true)
        #expect(privateSlot.minimumMarkWidth == 17)
    }

    @Test("physical shoulder room recovers symmetrically without overshoot")
    func clearanceRecoveryIsConservative() throws {
        let view = view()
        view.drivesEarRecoveryByHand = true
        view.earRecoveryReduceMotionOverride = false
        view.wings = ScreenBarWings(right: ScreenBarWingSlot(text: "Menu", symbol: "ellipsis", accessory: .init(symbol: "cup.and.saucer.fill")))
        let preferred = ScreenBarGeometry.wingMenuRowExtent
        func claim(_ width: CGFloat) {
            view.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                bandSpan: 480, leftExtent: width, rightExtent: width)
        }
        claim(14)
        #expect(view.leftWingRect?.width == 14 && view.rightWingRect?.width == 14)
        claim(19)
        #expect(view.rightWingRect?.width == 14)
        view.advanceEarRecovery(by: 0.07)
        let halfway = try #require(view.rightWingRect).width
        #expect(halfway > 14 && halfway < preferred)
        #expect(view.leftWingRect?.width == halfway)
        claim(13)
        #expect(view.leftWingRect?.width == 13 && view.rightWingRect?.width == 13)
        view.advanceEarRecovery(by: 1)
        #expect(view.rightWingRect?.width == 13)
        claim(19)
        view.advanceEarRecovery(by: 0.14)
        #expect(view.leftWingRect?.width == preferred && view.rightWingRect?.width == preferred)
        claim(14)
        view.earRecoveryReduceMotionOverride = true
        claim(19)
        #expect(view.rightWingRect?.width == preferred)
        view.earRecoveryReduceMotionOverride = false
        view.wingsLive = true
        claim(14)
        claim(19)
        view.wingsLive = false
        #expect(view.rightWingRect?.width == preferred)
        view.advanceEarRecovery(by: 1)
        #expect(view.rightWingRect?.width == preferred)
    }

    @Test("menu interaction does not collapse or resize restored wings")
    func menuInteractionKeepsWingsVisible() throws {
        let bar = view()
        bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"))
        let left = try #require(bar.leftWingRect)
        let right = try #require(bar.rightWingRect)
        for clearance: CGFloat in [20, 11, 0, -8, 40] {
            bar.configureWingLayout(geometry: bar.wingGeometry,
                                    leftLimit: left.maxX - clearance,
                                    rightLimit: right.minX + clearance)
            #expect(bar.leftWingRect == left)
            #expect(bar.rightWingRect == right)
        }
        bar.configureWingLayout(geometry: bar.wingGeometry, leftLimit: nil, rightLimit: nil)
        #expect(bar.leftWingRect == left && bar.rightWingRect == right)
    }

    @Test("one small mark does not reserve two oversized blank shoulders")
    func compactSingleMark() throws {
        let view = view()
        var wings = ScreenBarWings()
        wings.right = ScreenBarWingSlot(text: "Idle")
        view.wings = wings
        let left = try #require(view.leftWingRect)
        let right = try #require(view.rightWingRect)
        #expect(left.width == 19 && right.width == left.width)
        #expect(view.trayRect?.width == CGFloat(224))
    }

    @Test("content stays symmetric through native menu limits")
    func contentAndClearance() throws {
        let view = view()
        var wings = ScreenBarWings()
        wings.left = ScreenBarWingSlot(text: "Working", provider: "codex", accessory: .init(symbol: "cup.and.saucer.fill"))
        view.wings = wings
        let wanted = ScreenBarGeometry.wingMenuRowExtent
        #expect(view.leftWingRect?.width == wanted)
        #expect(view.rightWingRect?.width == wanted)
        let boundary = try #require(view.rightWingRect).minX
        view.rightEarLimit = boundary + 20
        #expect(view.leftWingRect?.width == wanted && view.rightWingRect?.width == wanted)
    }

    private struct HostedBar: NSViewRepresentable {
        let view: ScreenBarView
        func makeNSView(context: Context) -> ScreenBarView { view }
        func updateNSView(_ nsView: ScreenBarView, context: Context) {}
    }

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func compactRender() throws {
        let view = view()
        var wings = ScreenBarWings()
        wings.right = ScreenBarWingSlot(text: "Idle")
        view.wings = wings
        let scene = ZStack(alignment: .top) {
            ProofDesktop(dark: true)
            HostedBar(view: view).frame(width: view.bounds.width, height: view.bounds.height)
        }
        try ProofRender.write(scene.frame(width: 480, height: 100),
                              size: CGSize(width: 480, height: 100), name: "notch-compact-shoulders")
    }

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func clearanceRecoveryRender() throws {
        let bar = view()
        bar.drivesEarRecoveryByHand = true
        bar.earRecoveryReduceMotionOverride = false
        bar.wings = ScreenBarWings(right: ScreenBarWingSlot(text: "Menu", symbol: "ellipsis", accessory: .init(symbol: "cup.and.saucer.fill")))
        bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
            bandSpan: 480, leftExtent: 14, rightExtent: 14)
        bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
            bandSpan: 480, leftExtent: 132, rightExtent: 132)
        var cells: [ProofCell] = []
        for (dt, label): (TimeInterval, String) in [(0, "Constrained"), (0.07, "Recovering"), (0.07, "Restored")] {
            bar.advanceEarRecovery(by: dt)
            let scene = ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                HostedBar(view: bar).frame(width: bar.bounds.width, height: bar.bounds.height)
            }
            let bitmap = try ProofRender.render(scene.frame(width: 480, height: 100),
                size: CGSize(width: 480, height: 100), scale: 2, settle: 0)
            cells.append(ProofCell(label: label, bitmap: bitmap))
        }
        try ProofContactSheet.write(cells, columns: 3, title: "Conservative wing recovery",
                                    name: "notch-clearance-recovery")
    }

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func shoulderBoundaryRender() throws {
        var low: CGFloat = 32
        var high: CGFloat = 80
        for _ in 0..<20 {
            let height = (low + high) / 2
            let radius = NotchSilhouetteGeometry.radius(size: CGSize(width: 190, height: height),
                notchDepth: 32, restingRadius: 8)
            if height - 32 < radius { low = height } else { high = height }
        }
        let boundary = (low + high) / 2
        var cells: [ProofCell] = []
        for (width, height, notch): (CGFloat, CGFloat, CGFloat) in [
            (190, 33, 185), (190, boundary - 0.01, 185), (190, boundary + 0.01, 185),
            (190, 50, 185), (320, 90, 300), (320, 180, 300)
        ] {
            let bar = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
            bar.updateLayout {
                bar.notchCornerRadius = 8
                bar.wingGeometry = ScreenBarWingGeometry(notchWidth: notch, notchDepth: 32,
                    bandSpan: 250, leftExtent: 132, rightExtent: 132)
                bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"),
                    right: ScreenBarWingSlot(text: "Working", provider: "claude"))
                bar.islandFrame = CGRect(x: (500 - width) / 2, y: 200 - height, width: width, height: height)
            }
            let scene = ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                NotchSilhouette(notchDepth: 32, restingRadius: 8, notchWidth: notch)
                    .fill(.black).frame(width: width, height: height)
                HostedBar(view: bar).frame(width: 500, height: 200)
            }
            let bitmap = try ProofRender.render(scene.frame(width: 500, height: 200),
                size: CGSize(width: 500, height: 200), scale: 2, settle: 0)
            let heightLabel = String(format: "%.2f", Double(height))
            cells.append(ProofCell(label: "Slot \(Int(notch)), height \(heightLabel)", bitmap: bitmap))
        }
        try ProofContactSheet.write(cells, columns: 3, title: "Connected shoulders at the corner handoff",
                                    name: "notch-shoulder-boundary")
    }

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func coupledMotionRender() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        toy.screenBarShown = { true }
        NotchSurfaceRenderProofTests.fill(model, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(model) }
        let probe = NSHostingView(rootView: NotchCardView(model: model, style: .island, width: 320))
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let canvas = CGRect(x: 0, y: 0, width: 480, height: height + 24)
        let idle = CGRect(x: 147, y: canvas.height - 32, width: 186, height: 32)
        let card = CGRect(x: 80, y: canvas.height - height, width: 320, height: height)
        let morph = NotchMorph(rest: 32, open: height, restWidth: 186, openWidth: 320)
        var cells: [ProofCell] = []
        for opening in [true, false] {
            toy.expand(held: true)
            if !opening {
                toy.collapseIsland()
                // A real animated fold keeps the full layout until it lands.
                model.pinned = true
            }
            toy.stage.cardHeight = card.height
            toy.stage.cardWidth = card.width
            toy.stage.showContent(level: opening ? 0 : 1, expanded: opening)
            var spring = NotchFrameSpring(at: opening ? idle : card)
            spring.retarget(opening ? card : idle,
                motion: NotchMotion.frameMotion(from: spring.frame, to: opening ? card : idle))
            var elapsed = 0.0
            for time in [0.0, 0.04, 0.08, 0.14, 0.22, 0.4] {
                let dt = time - elapsed
                spring.integrate(dt: dt)
                elapsed = time
                let shape = spring.frame
                toy.stage.shape = NotchStage.local(shape, in: canvas)
                toy.stage.setOpenness(morph.openness(size: shape.size), expanded: opening, dt: dt)
                let bar = ScreenBarView(frame: canvas)
                bar.updateLayout {
                    bar.islandFrame = shape
                    bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                        bandSpan: 250, leftExtent: 132, rightExtent: 132)
                    bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"),
                        right: ScreenBarWingSlot(text: "Working", provider: "claude"))
                }
                let scene = ZStack(alignment: .top) {
                    ProofDesktop(dark: true)
                    NotchIslandView(toy: toy).frame(width: canvas.width, height: canvas.height)
                    HostedBar(view: bar).frame(width: canvas.width, height: canvas.height)
                }
                let bitmap = try ProofRender.render(scene.frame(width: canvas.width, height: canvas.height),
                    size: canvas.size, scale: 1, settle: 0.05)
                cells.append(ProofCell(label: "\(opening ? "Open" : "Close") \(Int(time * 1000)) ms", bitmap: bitmap))
            }
        }
        toy.stage.shape = nil
        try ProofContactSheet.write(cells, columns: 6, title: "One shape clock, compact shoulders, stable canvas",
                                    name: "notch-coupled-motion")
    }
    @Test("Blue coupled light stays outside the island and inside its housing",
          .enabled(if: renderEnabled), arguments: [1.0, 2.0])
    func blueCoupledJoinClipsLight(scale: Double) throws {
        let size = CGSize(width: 500, height: 200)
        for height: CGFloat in [32, 64, 120] {
            let bar = ScreenBarView(frame: CGRect(origin: .zero, size: size))
            let island = CGRect(x: height == 32 ? 157 : 90, y: 200 - height,
                                width: height == 32 ? 186 : 320, height: height)
            bar.updateLayout {
                bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                    bandSpan: 500, leftExtent: 132, rightExtent: 132, menuRowStemWidth: 186)
                bar.islandFrame = island
                bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Left", symbol: "circle.fill"),
                    right: ScreenBarWingSlot(text: "Right", symbol: "circle.fill"))
            }
            bar.display(colors: Array(repeating: RGB(r: 0, g: 0.3, b: 1), count: 8))
            let housing = try #require(bar.housingPaintPath)
            let islandPath = try #require(ScreenBarTrayShape.islandPath(island,
                stemWidth: 186, notchDepth: 32, radius: bar.notchCornerRadius))
            let band = bar.bandRect
            let scene = HostedBar(view: bar).frame(width: size.width, height: size.height)
                .background(Color(white: 0.2))
            let bitmap = try ProofRender.render(scene, size: size, scale: scale)
            var litStripPixels = 0
            var excludedPixels = 0
            for y in 0..<Int(size.height * scale) {
                for x in 0..<Int(size.width * scale) {
                    let point = CGPoint(x: (Double(x) + 0.5) / scale,
                        y: size.height - (Double(y) + 0.5) / scale)
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let blue = color.blueComponent - max(color.redComponent, color.greenComponent)
                    if band.insetBy(dx: 2, dy: 0.5).contains(point) {
                        if blue > 0.15 { litStripPixels += 1 }
                    }
                    // Stay one pixel inside the exclusion to avoid testing edge antialiasing.
                    let pixel = 1 / scale
                    let insideIsland = [CGPoint(x: point.x - pixel, y: point.y - pixel),
                        CGPoint(x: point.x + pixel, y: point.y + pixel)].allSatisfy { islandPath.contains($0) }
                    if insideIsland && !housing.contains(point) {
                        excludedPixels += 1
                        #expect(blue < 0.1, "Blue light must not paint the excluded island")
                    }
                }
            }
            #expect(excludedPixels > 20)
            #expect(litStripPixels > 20, "Clipping keeps the intended strip below the chin lit")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory.appendingPathComponent(
                "blue-coupled-join-height-\(Int(height))-scale-\(Int(scale)).png"))
        }
    }

}
