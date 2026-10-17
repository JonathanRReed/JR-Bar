import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The island's real window carrying a move on a stage, driven tick by
/// tick by hand. The window sits far outside any display, so nothing is
/// drawn where a person could see it; what is proved is the contract
/// the rest of the app leans on: the window is set once for the whole
/// move, the shape moves inside it, the Screen Bar couples to the
/// shape and not the stage, the move lands with the window exactly the
/// shape again, and a cancel at any tick strikes the stage.
@Suite("Notch island stage")
@MainActor
struct NotchIslandStageTests {
    private let idle = CGRect(x: 5663, y: 5950, width: 185, height: 32)
    private let card = CGRect(x: 5596, y: 5560, width: 320, height: 422)

    private func makeWindow() -> (NotchIslandWindow, NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let window = NotchIslandWindow(toy: toy)
        window.drivesSpringByHand = true
        window.surroundingsOverride = .init(bounds: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), floor: nil)
        window.setFrame(idle, display: false)
        window.orderFrontRegardless()
        return (window, toy, store)
    }

    @Test("instant frame changes update the shape while shoulders reserve input")
    func instantFrameChangeWithShoulders() {
        let (window, toy, store) = makeWindow()
        defer { window.setShoulderInput(nil); window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        let shoulder = CGRect(x: idle.minX - 28, y: idle.minY, width: 28, height: idle.height)
        window.setShoulderInput(CGPath(rect: shoulder, transform: nil))
        #expect(window.presentedFrame == idle)
        #expect(toy.stage.shape != nil)

        window.applyFrame(card, animated: false)
        #expect(window.presentedFrame == card)
        #expect(window.frame == card)
        #expect(toy.stage.shape == nil)

        window.applyFrame(idle, animated: false)
        #expect(window.presentedFrame == idle)
        #expect(window.frame.contains(shoulder))
        #expect(toy.stage.shape == NotchStage.local(idle, in: window.frame))
        #expect(!window.isAnimating)
    }

    @Test("an interrupted instant landing publishes the final shape before its completion")
    func instantLandingCompletionUsesFinalShape() {
        let (window, _, store) = makeWindow()
        defer { window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true)
        window.advanceSpring(by: 1.0 / 120)
        var completedFrame: CGRect?
        window.onMorphEnded = { completedFrame = window.presentedFrame }

        window.applyFrame(idle, animated: false)
        #expect(completedFrame == idle)
        #expect(window.presentedFrame == idle)
        #expect(!window.isAnimating)
    }

    @Test("the band sees a spring tick only after its content clock")
    func coupledGeometryFollowsContentTick() {
        let (window, _, store) = makeWindow()
        defer { window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: idle.height, open: card.height))
        var contentTick = false
        var published = false
        var publishedBeforeContent = false
        window.onTick = { _ in contentTick = true }
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: window, queue: nil) { _ in
            MainActor.assumeIsolated {
                published = true
                publishedBeforeContent = !contentTick
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        window.advanceSpring(by: 1.0 / 120)
        #expect(contentTick && published)
        #expect(!publishedBeforeContent)
    }

    @Test("a stationary shoulder canvas preserves the body's shadow and a pull lifts it")
    func shoulderCanvasKeepsBodyShadow() {
        let (window, _, store) = makeWindow()
        defer { window.setShoulderInput(nil); window.cancelPull(); window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: false)
        let body = window.presentedFrame
        let patch = CGRect(x: body.minX - 20, y: body.maxY - 60, width: 25, height: 10)
        window.setShoulderInput(CGPath(rect: patch, transform: nil))
        if NotchIslandWindow.shadowEnabled {
            #expect(window.shadowPanel?.isCast == true)
            #expect(window.shadowPanel?.frame == NotchShadow.frame(for: body))
            window.beginPullFrame()
            #expect(window.shadowPanel?.isCast == false)
            window.movePullFrame(12)
            window.endPullFrame(.retreat)
            #expect(window.shadowPanel?.isCast == true)
            #expect(window.shadowPanel?.frame == NotchShadow.frame(for: window.presentedFrame))
        }
    }

    @Test("a shoulder pull moves the presented body rather than its wider input canvas")
    func shoulderPullUsesPresentedBody() {
        let (window, toy, store) = makeWindow()
        defer { window.setShoulderInput(nil); window.cancelPull(); window.orderOut(nil); withExtendedLifetime(store) {} }
        let body = window.presentedFrame
        let patch = CGRect(x: body.minX - 20, y: body.minY + 2, width: 25, height: 10)
        window.setShoulderInput(CGPath(rect: patch, transform: nil))
        #expect(window.frame.width > body.width)
        window.beginPullFrame()
        #expect(toy.pullActive)
        window.movePullFrame(12)
        #expect(window.presentedFrame.width == body.width)
        #expect(window.presentedFrame.height == body.height + 12)
        #expect(window.presentedFrame.maxY == body.maxY)
        window.endPullFrame(.retreat)
        #expect(!toy.pullActive)
    }

    @Test("painted shoulders share the native input window and leave body controls untouched")
    func shoulderInputUsesNativeStage() throws {
        let (window, toy, store) = makeWindow()
        defer { window.setShoulderInput(nil); window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        toy.island = window
        let shape = window.presentedFrame
        let patch = CGRect(x: shape.minX - 20, y: shape.minY + 2, width: 25, height: 10)
        window.setShoulderInput(CGPath(rect: patch, transform: nil))
        #expect(window.frame.contains(patch))
        #expect(window.presentedFrame == shape)
        let path = try #require(toy.shoulderInputPath)
        let point = CGPoint(x: patch.minX + 5 - window.frame.minX,
            y: window.frame.maxY - patch.midY)
        #expect(path.contains(point))
        let center = CGPoint(x: shape.midX - window.frame.minX, y: window.frame.maxY - shape.midY)
        #expect(!path.contains(center))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let inParent = view.convert(local, to: view.superview)
        #expect(view.hitTest(inParent) != nil)
        let outside = CGPoint(x: point.x, y: 5)
        let outsideLocal = CGPoint(x: outside.x, y: view.isFlipped ? outside.y : view.bounds.height - outside.y)
        #expect(view.hitTest(view.convert(outsideLocal, to: view.superview)) == nil)
        window.setShoulderInput(nil)
        #expect(toy.shoulderInputPath == nil && window.frame == shape && toy.stage.shape == nil)
        window.setShoulderInput(CGPath(rect: patch, transform: nil))
        toy.island = nil
        #expect(toy.shoulderInputPath == nil && window.frame == shape)
        window.orderOut(nil)
        window.setShoulderInput(CGPath(rect: patch, transform: nil))
        #expect(toy.shoulderInputPath == nil && window.frame == shape)
    }

    @Test("the reused hosting view draws the shape at its spring position from the first grow frame")
    func renderedGrowKeepsItsAnchor() throws {
        let (window, toy, store) = makeWindow()
        defer { window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        toy.expand(held: true)
        toy.stage.cardWidth = card.width
        toy.stage.cardHeight = card.height
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: idle.height, open: card.height))
        let view = try #require(window.contentView)
        for dt in [0.0, 1.0 / 120, 0.03, 0.06, 0.12] {
            window.advanceSpring(by: dt)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let shape = try #require(toy.stage.shape)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            let row = min(bitmap.pixelsHigh - 1, Int(shape.midY * scaleY))
            var lo = Int.max, hi = -1
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: row))
                if color.alphaComponent > 0.9 && color.redComponent < 0.2 {
                    lo = min(lo, x); hi = max(hi, x)
                }
            }
            try #require(hi >= lo, "no opaque shape at tick \(dt)")
            let center = CGFloat(lo + hi + 1) / (2 * scaleX)
            #expect(abs(center - shape.midX) <= 1, "tick \(dt): rendered \(center), spring \(shape.midX)")
        }
    }

    private func checkRenderedBounds(_ window: NotchIslandWindow, shape: CGRect, phase: String) throws {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let sx = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let row = min(bitmap.pixelsHigh - 1, Int(shape.midY * sy))
        let column = min(bitmap.pixelsWide - 1, Int(shape.midX * sx))
        var left = Int.max, right = -1, top = Int.max, bottom = -1
        for x in 0..<bitmap.pixelsWide {
            if let c = bitmap.colorAt(x: x, y: row), c.alphaComponent > 0.9 {
                left = min(left, x); right = max(right, x)
            }
        }
        for y in 0..<bitmap.pixelsHigh {
            if let c = bitmap.colorAt(x: column, y: y), c.alphaComponent > 0.9 {
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        try #require(right >= left && bottom >= top,
                     "\(phase): shape \(shape), view \(view.bounds), opaque x \(left)...\(right), y \(top)...\(bottom)")
        let center = CGFloat(left + right + 1) / (2 * sx)
        let width = CGFloat(right - left + 1) / sx
        let height = CGFloat(bottom - top + 1) / sy
        #expect(abs(center - shape.midX) <= 1, "\(phase): rendered center \(center), expected \(shape.midX)")
        #expect(width >= shape.width - 9 && width <= shape.width + 1, "\(phase): rendered width \(width), expected \(shape.width)")
        #expect(abs(CGFloat(top) / sy - shape.minY) <= 1, "\(phase): rendered top \(top), expected \(shape.minY)")
        #expect(abs(height - shape.height) <= 1, "\(phase): rendered height \(height), expected \(shape.height)")
    }

    @Test("a wider retarget and stage cancellation keep rendered bounds on both axes")
    func renderedRetargetAndCancelKeepBounds() throws {
        let (window, toy, store) = makeWindow()
        defer { window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        toy.expand(held: true)
        toy.stage.cardWidth = card.width
        toy.stage.cardHeight = card.height
        window.applyFrame(card, animated: true)
        for _ in 0..<3 { window.advanceSpring(by: 1.0 / 120) }
        let stageWidth = window.frame.width
        let wide = CGRect(x: card.midX - 240, y: card.maxY - 500, width: 480, height: 500)
        window.applyFrame(wide, animated: true)
        #expect(window.frame.width > stageWidth)
        try checkRenderedBounds(window, shape: try #require(toy.stage.shape), phase: "retarget before tick")
        window.advanceSpring(by: 1.0 / 120)
        try checkRenderedBounds(window, shape: try #require(toy.stage.shape), phase: "retarget first tick")
        window.cancelSpring()
        #expect(toy.stage.shape == nil)
        try checkRenderedBounds(window, shape: CGRect(origin: .zero, size: window.frame.size), phase: "cancelled stage")
    }

    @Test("a rendered fold keeps its center and top edge through the landed window")
    func renderedFoldKeepsBounds() throws {
        let (window, toy, store) = makeWindow()
        defer { window.cancelSpring(); window.orderOut(nil); withExtendedLifetime(store) {} }
        toy.expand(held: true)
        toy.stage.cardWidth = card.width
        toy.stage.cardHeight = card.height
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: idle.height, open: card.height))
        var growTicks = 0
        while toy.stage.shape != nil, growTicks < 400 {
            window.advanceSpring(by: 1.0 / 120)
            growTicks += 1
        }
        toy.collapseFromBand()
        toy.stage.setOpenness(1, expanded: false)
        toy.stage.showContent(level: 1, expanded: false)
        window.applyFrame(idle, animated: true, flip: NotchMorph(rest: idle.height, open: card.height))
        for dt in [0.0, 1.0 / 120, 0.03, 0.06, 0.12] {
            window.advanceSpring(by: dt)
            let shape = toy.stage.shape ?? CGRect(origin: .zero, size: window.frame.size)
            try checkRenderedBounds(window, shape: shape, phase: "fold tick \(dt)")
        }
        var ticks = 0
        while toy.stage.shape != nil, ticks < 400 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(window.frame == idle)
        try checkRenderedBounds(window, shape: CGRect(origin: .zero, size: idle.size), phase: "landed fold")
    }

    @Test("a grow holds one stage for the whole move and ends as the shape")
    func growCarriedOnAStage() throws {
        let (window, toy, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        let morph = NotchMorph(rest: idle.height, open: card.height)
        window.applyFrame(card, animated: true, flip: morph)
        let stage = window.frame
        #expect(NotchStage.holds(stage, idle) && NotchStage.holds(stage, card))
        #expect(stage.maxY == idle.maxY, "hung from the top edge")
        var frames = Set<String>()
        var ticks = 0
        var last: CGFloat = -1
        var shapeHeights: [CGFloat] = []
        while toy.stage.shape != nil || ticks == 0, ticks < 400 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
            if let local = toy.stage.shape {
                frames.insert("\(window.frame)")
                #expect(window.frame == stage, "the window is not resized per tick")
                #expect(local.minY >= -0.01 && local.maxX <= stage.width + 0.5 && local.minX >= -0.5,
                        "the shape stays inside its stage: \(local)")
                shapeHeights.append(window.presentedFrame.height)
                #expect(toy.stage.openness >= last - 1e-6 || ticks > 20, "openness climbs with the grow")
                last = toy.stage.openness
            }
        }
        #expect(frames.count == 1, "one window frame for the whole move: \(frames.count)")
        #expect(window.frame == card, "landed: the window is exactly the shape")
        #expect(toy.stage.shape == nil, "no stage left behind")
        #expect(window.presentedFrame == window.frame)
        #expect(shapeHeights.count > 15 && shapeHeights.contains { $0 > card.height })
    }

    @Test("in flight the shape moves between device pixels, and it lands on them")
    func smoothInFlightSnappedAtRest() {
        let (window, _, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true)
        var offGrid = 0
        for _ in 0..<12 {
            window.advanceSpring(by: 1.0 / 120)
            let height = window.presentedFrame.height
            if abs(height * 2 - (height * 2).rounded()) > 0.01 { offGrid += 1 }
        }
        #expect(offGrid > 6, "a grid-snapped edge steps in half points; this one is smooth: \(offGrid)")
        var ticks = 0
        while window.presentedFrame != card || window.frame != card, ticks < 600 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(window.frame == card)
        #expect(window.frame.height * 2 == (window.frame.height * 2).rounded())
    }

    @Test("the Screen Bar's read is the shape in flight, not the stage")
    func couplingReadsTheShape() {
        let (window, _, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: 32, open: 422))
        for _ in 0..<6 { window.advanceSpring(by: 1.0 / 120) }
        let shape = window.presentedFrame
        #expect(shape.height > idle.height && shape.height < card.height)
        #expect(shape != window.frame)
        #expect(ScreenBarGeometry.islandScreenRect == shape)
    }

    @Test("the Screen Bar can reserve one canvas for every tick of a morph")
    func couplingCanvasStaysFixed() throws {
        let (window, _, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true)
        let canvas = try #require(ScreenBarGeometry.islandStageScreenRect)
        var ticks = 0
        while window.isAnimating, ticks < 400 {
            #expect(ScreenBarGeometry.islandStageScreenRect == canvas)
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(ticks < 400)
        #expect(ScreenBarGeometry.islandStageScreenRect == nil)
        #expect(ScreenBarGeometry.islandScreenRect == card)
    }

    @Test("a closing card keeps its page and full layout until the fold lands")
    func departingCardKeepsLayout() {
        let (window, toy, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        toy.island = window
        toy.cardModel.show(.shelf)
        toy.expand(held: true)
        var ticks = 0
        while window.isAnimating, ticks < 500 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(toy.cardModel.pinned && toy.cardModel.page == .shelf)
        toy.collapseIsland()
        #expect(!toy.islandExpanded)
        #expect(window.isAnimating)
        #expect(toy.cardModel.pinned && toy.cardModel.page == .shelf)
        ticks = 0
        while window.isAnimating, ticks < 500 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(ticks < 500)
        #expect(!toy.cardModel.pinned && toy.cardModel.page == .now)
    }

    @Test("a reversal mid-grow retargets inside the same stage and folds home")
    func reversal() {
        let (window, toy, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: 32, open: 422))
        let stage = window.frame
        for _ in 0..<12 { window.advanceSpring(by: 1.0 / 120) }
        let mid = window.presentedFrame
        window.applyFrame(idle, animated: true, flip: NotchMorph(rest: 32, open: 422))
        #expect(window.frame == stage, "the stage already holds the way home")
        #expect(window.presentedFrame == mid, "the retarget itself moves nothing")
        var ticks = 0
        while toy.stage.shape != nil || ticks == 0, ticks < 400 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
        #expect(window.frame == idle && toy.stage.shape == nil)
    }

    @Test("a cancel at any tick strikes the stage where the shape stands")
    func cancelLands() {
        let (window, toy, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: 32, open: 422))
        for _ in 0..<9 { window.advanceSpring(by: 1.0 / 120) }
        let shape = window.presentedFrame
        window.cancelSpring()
        // (A window parked off every display sits on a one-point grid, so
        // the shape's half points round out by up to a point.)
        #expect(abs(window.frame.width - shape.width) <= 1 && abs(window.frame.height - shape.height) <= 1,
                "the window is the shape again")
        #expect(toy.stage.shape == nil)
        let landed = window.frame
        window.advanceSpring(by: 1.0 / 120)
        #expect(window.frame == landed, "and nothing keeps moving it")
    }

    @Test("a retarget past the stage widens it without moving the shape")
    func retargetPastTheStage() {
        let (window, _, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        let small = CGRect(x: 5640, y: 5920, width: 232, height: 62)
        window.applyFrame(small, animated: true)
        for _ in 0..<4 { window.advanceSpring(by: 1.0 / 120) }
        let before = window.presentedFrame
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: 62, open: 422))
        #expect(NotchStage.holds(window.frame, card))
        #expect(window.presentedFrame == before, "the shape stays put as the stage grows around it")
    }

    @Test("with the old per-tick resize switched back on the window follows the shape")
    func legacyFollowsTheShape() {
        UserDefaults.standard.set(false, forKey: "jrbar.notchStagedMotion")
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.notchStagedMotion") }
        let (window, toy, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        window.applyFrame(card, animated: true, flip: NotchMorph(rest: 32, open: 422))
        for _ in 0..<8 { window.advanceSpring(by: 1.0 / 120) }
        #expect(window.frame == window.presentedFrame)
        #expect(toy.stage.shape == nil)
        #expect(window.frame.height > idle.height)
    }
}
