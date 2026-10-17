import AppKit
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Screen Bar coupled layout")
struct ScreenBarCoupledLayoutTests {
    private func geometry(span: CGFloat = 250) -> ScreenBarWingGeometry {
        ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32, bandSpan: span,
                              leftExtent: 132, rightExtent: 132)
    }

    private func wings() -> ScreenBarWings {
        ScreenBarWings(left: ScreenBarWingSlot(text: "Synthetic work", provider: "claude"),
                       right: ScreenBarWingSlot(text: "Synthetic quota", provider: "codex", meter: 0.4))
    }

    @Test("divider spacer reflow preserves Notch wings, content and stationary hover", arguments: [CGFloat(142), 22])
    func dividerReflowKeepsNotchStable(glyphWidth: CGFloat) throws {
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 1512, height: 200))
        let geometry = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32,
                                            bandSpan: 250, leftExtent: 132, rightExtent: 132)
        view.configureWingLayout(geometry: geometry, leftLimit: nil, rightLimit: nil)
        view.wings = wings()
        let initialLeft = try #require(view.leftWingRect)
        let initialRight = try #require(view.rightWingRect)
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter,
            hitRects: { [view.leftWingRect, view.rightWingRect].compactMap { $0 } }, focus: { nil })
        interaction.pointerLocation = { CGPoint(x: initialLeft.midX, y: initialLeft.midY) }
        interaction.islandOwnsNotch = { true }
        var hoverEdges: [Bool] = []
        interaction.onIslandHover = { active, _ in hoverEdges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        for width in [CGFloat(172), 296, 600, 1900, 600, 296, 172] {
            let divider = CGRect(x: 1073 - width, y: 4.5, width: width, height: 24)
            let ink = StatusItemController.boundaryInkFrame(divider, glyphWidth: glyphWidth, spacer: width - 142)
            #expect(ink.width == 162, "painted title and native padding remain protected")
            let raw = MenuBarUtility.earLimits(items: [],
                island: CGRect(x: 663.5, y: 0, width: 185, height: 32),
                row: CGRect(x: 0, y: 0, width: 1512, height: 32),
                concealedApps: [:], sections: [:], revealed: [.hidden], ourPID: 42, divider: ink)
            let left = raw.left.flatMap { $0 < 756 ? $0 + 8 : nil }
            let right = raw.right.flatMap { $0 > 756 ? $0 - 8 : nil }
            view.configureWingLayout(geometry: geometry, leftLimit: left, rightLimit: right)
            interaction.pointerMoved(geometryOnly: true)
            #expect(view.leftWingRect == initialLeft)
            #expect(view.rightWingRect == initialRight)
            #expect(interaction.hovering)
        }
        #expect(hoverEdges == [true])
    }

    @Test("one native clearance publication exposes both new flanks and skips unchanged pairs")
    func nativeClearancePublishesTogether() {
        let left = ScreenBarGeometry.earItemLimitLeft
        let right = ScreenBarGeometry.earItemLimitRight
        let observer = ScreenBarGeometry.earLimitsChanged
        ScreenBarGeometry.earLimitsChanged = nil
        defer {
            ScreenBarGeometry.earLimitsChanged = nil
            ScreenBarGeometry.setEarItemLimits(left: left, right: right)
            ScreenBarGeometry.earLimitsChanged = observer
        }
        ScreenBarGeometry.setEarItemLimits(left: nil, right: nil)
        var snapshots: [(CGFloat?, CGFloat?)] = []
        ScreenBarGeometry.earLimitsChanged = {
            snapshots.append((ScreenBarGeometry.earItemLimitLeft, ScreenBarGeometry.earItemLimitRight))
        }
        ScreenBarGeometry.setEarItemLimits(left: 100, right: 200)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.0 == 100 && snapshots.first?.1 == 200)
        ScreenBarGeometry.setEarItemLimits(left: 100, right: 200)
        #expect(snapshots.count == 1)
        ScreenBarGeometry.setEarItemLimits(left: nil, right: nil)
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.0 == nil && snapshots.last?.1 == nil)
    }

    @Test("adjacent samples at the rounded-foot handoff keep the connector continuous")
    func shoulderCornerHandoff() throws {
        let tray = CGRect(x: 125.5, y: 168, width: 249, height: 32)
        let before = try #require(ScreenBarGeometry.shoulderConnector(tray: tray,
            body: CGRect(x: 155, y: 160.01, width: 190, height: 39.99), trayRadius: 8, bodyRadius: 8))
        let after = try #require(ScreenBarGeometry.shoulderConnector(tray: tray,
            body: CGRect(x: 155, y: 159.99, width: 190, height: 40.01), trayRadius: 8, bodyRadius: 8))
        #expect(abs(before.boundingBoxOfPath.minY - after.boundingBoxOfPath.minY) < 0.1)
        #expect(before.contains(CGPoint(x: 150, y: 165)) == after.contains(CGPoint(x: 150, y: 165)))
    }

    @Test("connecting skin preserves native control clearance, the foot and its painted hit path")
    func shoulderContourAndHitRegion() throws {
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        view.updateLayout {
            view.configureWingLayout(geometry: geometry(), leftLimit: nil, rightLimit: nil)
            view.wings = ScreenBarWings(right: ScreenBarWingSlot(text: "Menu", symbol: "ellipsis"))
            view.islandFrame = CGRect(x: 155, y: 80, width: 190, height: 120)
        }
        let path = try #require(view.shoulderPath)
        let tray = try #require(view.trayRect)
        #expect(path.boundingBoxOfPath.maxY <= view.bounds.height)
        for depth: CGFloat in [1, 15, 31] {
            #expect(!path.contains(CGPoint(x: view.bounds.midX + 185 / 2 + 21,
                                          y: view.bounds.height - depth)))
        }
        #expect(!path.contains(CGPoint(x: path.boundingBoxOfPath.minX, y: path.boundingBoxOfPath.minY)))
        let body = NotchSilhouetteGeometry.body(of: try #require(view.islandFrame), notchWidth: 185, notchDepth: 32)
        #expect(view.housingRect?.width == body.width)
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let extraSkinPoint = try #require(
            stride(from: path.boundingBoxOfPath.minY + 0.5,
                   to: path.boundingBoxOfPath.maxY, by: 1).lazy.flatMap { y in
                stride(from: path.boundingBoxOfPath.minX + 0.5,
                       to: path.boundingBoxOfPath.maxX, by: 1).map { CGPoint(x: $0, y: y) }
            }.first { path.contains($0) && !body.contains($0) && !tray.contains($0) })
        var point = extraSkinPoint
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.extraHitTest = { view.shoulderPath?.contains($0) ?? false }
        defer { interaction.stop() }
        #expect(path.contains(point))
        #expect(!body.contains(point), "the fixture exercises the extra skin outside the native island body")
        #expect(!tray.contains(point), "the fixture exercises the connecting skin below the fixed ledge")
        #expect(view.nativeShoulderPath?.contains(point) == true)
        interaction.pointerMoved()
        #expect(interaction.hovering)
        var bandActions = 0
        interaction.onIslandExpand = { bandActions += 1 }
        interaction.onIslandCollapse = { bandActions += 1 }
        interaction.pointerDown(at: point, time: 0)
        interaction.pointerReleased(at: 0.1)
        #expect(bandActions == 0, "the native island owns the shoulder press")
        point = CGPoint(x: path.boundingBoxOfPath.minX, y: path.boundingBoxOfPath.minY)
        interaction.pointerMoved()
        #expect(!interaction.hovering)
        view.updateLayout { view.islandFrame = CGRect(x: 60, y: 0, width: 380, height: 200) }
        #expect(view.shoulderPath?.contains(point) != true)
        point = extraSkinPoint
        interaction.pointerMoved()
        #expect(!interaction.hovering)
    }

    @Test("bounds, slots and the presented shape publish in one geometry layout")
    func atomicLayoutUsesFinalBounds() {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        var layouts: [(CGSize, Bool)] = []
        view.onWingLayout = { layouts.append((view.bounds.size, $0)) }
        view.updateLayout {
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
            view.bandSpan = 250
            view.islandFrame = CGRect(x: 110, y: 20, width: 380, height: 300)
            view.configureWingLayout(geometry: geometry(), leftLimit: nil, rightLimit: nil)
            view.wings = wings()
            #expect(layouts.isEmpty, "intermediate old-bounds layouts must not publish")
        }
        #expect(layouts.count == 1)
        #expect(layouts.first?.0 == CGSize(width: 600, height: 320))
        #expect(layouts.first?.1 == false)
        #expect(view.bandRect.maxY == 20)
    }

    @Test("spring samples move the drawn foot within one stable canvas without another spring")
    func stableCanvasFollowsPresentedShape() throws {
        let canvas = NSRect(x: 0, y: 0, width: 500, height: 408)
        let view = ScreenBarView(frame: canvas)
        view.updateLayout {
            view.bandSpan = 250
            view.configureWingLayout(geometry: geometry(), leftLimit: nil, rightLimit: nil)
            view.wings = wings()
        }
        var animations: [Bool] = []
        view.onWingLayout = { animations.append($0) }
        let heights: [CGFloat] = [32, 57.9, 58, 58.1, 70, 120, 300, 120, 58.1, 58, 57.9, 50, 32]
        for height in heights {
            let width: CGFloat = height > 32 ? 380 : 185
            let shape = CGRect(x: (canvas.width - width) / 2, y: canvas.height - height,
                               width: width, height: height)
            view.updateLayout { view.islandFrame = shape }
            #expect(view.frame == canvas)
            let tray = try #require(view.trayRect)
            #expect(view.bandRect.maxY == min(shape.minY, tray.minY))
            let body = NotchSilhouetteGeometry.body(of: shape, notchWidth: 185, notchDepth: 32)
            #expect(view.housingRect?.width == max(body.width, tray.width))
        }
        #expect(animations.count == heights.count)
        #expect(animations.allSatisfy { !$0 })
    }

    @Test("changing wing claims during coupling never animates their geometry")
    func coupledClaimChangeHasNoSecondaryAnimation() {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        view.updateLayout {
            view.islandFrame = CGRect(x: 60, y: 20, width: 380, height: 300)
            view.configureWingLayout(geometry: geometry(), leftLimit: nil, rightLimit: nil)
            view.wings = wings()
        }
        var animations: [Bool] = []
        view.onWingLayout = { animations.append($0) }
        view.updateLayout {
            view.configureWingLayout(geometry: geometry(span: 300), leftLimit: 130, rightLimit: 370)
            view.wings = ScreenBarWings(left: nil, right: ScreenBarWingSlot(text: "Changed quota", provider: "codex", meter: 0.8))
        }
        #expect(animations == [false])
    }
}
