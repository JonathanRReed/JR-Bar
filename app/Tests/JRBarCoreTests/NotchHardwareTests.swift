import Foundation
import Testing
@testable import JRBarCore

/// The notch's geometry is a pure function of injected screen metrics:
/// no NSScreen, no real display. Every case below stands in a display
/// the way AppKit reports it.
@Suite("Notch hardware")
struct NotchHardwareTests {
    /// A notched laptop: both menu-bar areas flank a centred gap of
    /// `gap` points, `depth` tall, at `scale`.
    private func laptop(width: CGFloat, height: CGFloat, gap: CGFloat, depth: CGFloat,
                        scale: CGFloat = 2, origin: CGPoint = .zero,
                        globalAux: Bool = true) -> NotchScreenMetrics {
        let side = (width - gap) / 2
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let base = globalAux ? origin : .zero
        return NotchScreenMetrics(
            frame: frame, safeAreaTop: depth,
            auxLeft: CGRect(x: base.x, y: base.y + height - depth, width: side, height: depth),
            auxRight: CGRect(x: base.x + side + gap, y: base.y + height - depth,
                             width: side, height: depth),
            backingScale: scale, isBuiltIn: true)
    }

    private func onPixels(_ value: CGFloat, scale: CGFloat) -> Bool {
        let scaled = value * scale
        return abs(scaled - scaled.rounded()) < 1e-6
    }

    @Test func fourteenInchDefaultModeMeasuresTheRealNotch() {
        // The numbers a 14-inch MacBook Pro reports at 1512 x 982.
        let metrics = NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            auxLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
            auxRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            backingScale: 2, isBuiltIn: true)
        let hardware = NotchHardware.resolve(metrics, simulated: false)
        #expect(hardware.kind == .notched)
        #expect(hardware.hasSlot)
        // 185 pt of hardware plus one device pixel (0.5 pt) each side.
        #expect(hardware.rect == CGRect(x: 663, y: 950, width: 186, height: 32))
        #expect(hardware.centerX == 756)
        #expect(hardware.depth == 32)
    }

    @Test func slotWidthFollowsTheAreasNotAConstant() {
        let a = NotchHardware.resolve(laptop(width: 1512, height: 982, gap: 185, depth: 32),
                                      simulated: false)
        let b = NotchHardware.resolve(laptop(width: 1728, height: 1117, gap: 200, depth: 32),
                                      simulated: false)
        #expect(a.width == 186)
        #expect(b.width == 201)
        #expect(a.width != b.width)
    }

    @Test func everyEdgeLandsOnWholePixelsAndCoversTheHardware() {
        // Scaled modes put the gap between pixels: 230.4 pt wide, 37.6 deep.
        for scale: CGFloat in [1, 2] {
            for (width, gap, depth) in [(CGFloat(1800), CGFloat(230.4), CGFloat(37.6)),
                                        (1280, 185.3, 32),
                                        (1512, 185, 32),
                                        (1920, 211.7, 38)] {
                let metrics = laptop(width: width, height: 1169, gap: gap, depth: depth, scale: scale)
                let rawLeft = metrics.auxLeft!.maxX
                let rawRight = metrics.auxRight!.minX
                let hardware = NotchHardware.resolve(metrics, simulated: false)
                let rect = hardware.rect
                for edge in [rect.minX, rect.maxX, rect.minY, rect.maxY, rect.width, rect.height] {
                    #expect(onPixels(edge, scale: scale))
                }
                // Never a hairline short of the hardware, never a pixel more
                // than one past it.
                #expect(rect.minX <= rawLeft && rect.maxX >= rawRight)
                #expect(rawLeft - rect.minX <= 2 / scale)
                #expect(rect.maxX - rawRight <= 2 / scale)
                #expect(rect.maxY == metrics.frame.maxY)
                #expect(rect.height >= depth && rect.height - depth < 1 / scale + 1e-9)
            }
        }
    }

    @Test func floatNoiseDoesNotGrowAPixel() {
        let grid = NotchPixelGrid.snapOut(
            CGRect(x: 663.5 + 1e-12, y: 950, width: 185 - 2e-12, height: 32), scale: 2)
        #expect(grid == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(NotchPixelGrid.snapOut(grid, scale: 2) == grid)
    }

    @Test func nonRetinaScaleBleedsAWholePoint() {
        let hardware = NotchHardware.resolve(
            laptop(width: 1440, height: 900, gap: 180, depth: 30, scale: 1), simulated: false)
        #expect(hardware.rect == CGRect(x: 629, y: 870, width: 182, height: 30))
    }

    @Test func aDepthWithoutAGapIsNotANotch() {
        // A screen mid-reconfiguration reports its inset before the areas.
        var metrics = laptop(width: 1512, height: 982, gap: 185, depth: 32)
        metrics.auxLeft = nil
        metrics.auxRight = nil
        let hardware = NotchHardware.resolve(metrics, simulated: false)
        #expect(hardware.kind == .builtInNotchless)
        #expect(!hardware.hasSlot)
        #expect(hardware.depth == 0)
        #expect(hardware.width == 0)
    }

    @Test func areasThatTouchAreNotANotch() {
        var metrics = laptop(width: 1512, height: 982, gap: 185, depth: 32)
        metrics.auxRight = CGRect(x: 663.5, y: 950, width: 848.5, height: 32)
        #expect(NotchHardware.resolve(metrics, simulated: false).kind == .builtInNotchless)
    }

    @Test func depthFallsBackToTheAreasWhenTheInsetIsMissing() {
        var metrics = laptop(width: 1512, height: 982, gap: 185, depth: 32)
        metrics.safeAreaTop = 0
        let hardware = NotchHardware.resolve(metrics, simulated: false)
        #expect(hardware.kind == .notched)
        #expect(hardware.depth == 32)
    }

    @Test func externalAndNotchlessLaptopFloatAsAPill() {
        let external = NotchScreenMetrics(
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), backingScale: 1, isBuiltIn: false)
        let air = NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScale: 2, isBuiltIn: true)
        let a = NotchHardware.resolve(external, simulated: false)
        let b = NotchHardware.resolve(air, simulated: false)
        #expect(a.kind == .external && b.kind == .builtInNotchless)
        for hardware in [a, b] {
            #expect(!hardware.hasSlot)
            #expect(hardware.rect == .zero)
        }
    }

    @Test func simulatedNotchCentresOnTheScreenAndOnlyWhereThereIsNone() {
        let external = NotchScreenMetrics(
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), backingScale: 1, isBuiltIn: false)
        let simulated = NotchHardware.resolve(external, simulated: true)
        #expect(simulated.kind == .simulated)
        #expect(simulated.width == NotchHardware.simulatedWidth)
        #expect(simulated.centerX == -1280)
        #expect(simulated.rect.maxY == 1440)
        #expect(simulated.depth == NotchHardware.simulatedDepth)
        // A real notch is never replaced by the synthetic one.
        let real = NotchHardware.resolve(laptop(width: 1512, height: 982, gap: 185, depth: 32),
                                         simulated: true)
        #expect(real.kind == .notched)
        #expect(real.width == 186)
    }

    @Test func twoDisplaysResolveIndependently() {
        let builtIn = laptop(width: 1512, height: 982, gap: 185, depth: 32)
        let external = NotchScreenMetrics(
            frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), backingScale: 1)
        let screens = [builtIn, external].map { NotchHardware.resolve($0, simulated: false) }
        #expect(screens[0].kind == .notched)
        #expect(screens[1].kind == .external)
        #expect(screens[0].rect.maxX <= external.frame.minX)
    }

    @Test func aNotchedScreenArrangedAwayFromTheOriginKeepsItsNotchAtItsOwnTop() {
        // The same panel, a monitor arranged to its left: its frame starts
        // at x = 2560, and the areas arrive in global or screen-local
        // coordinates — both land the notch on the panel's own centre.
        for globalAux in [true, false] {
            let metrics = laptop(width: 1512, height: 982, gap: 185, depth: 32,
                                 origin: CGPoint(x: 2560, y: -300), globalAux: globalAux)
            let hardware = NotchHardware.resolve(metrics, simulated: false)
            let expectedCenter: CGFloat = 2560 + 756
            #expect(abs(hardware.centerX - expectedCenter) < 1e-9)
            #expect(hardware.rect.maxY == 682)
            #expect(hardware.width == 186)
        }
    }

    @Test func aScreenLeftOfTheOriginMapsLocalAreasToo() {
        let metrics = laptop(width: 1512, height: 982, gap: 185, depth: 32,
                             origin: CGPoint(x: -1512, y: 0), globalAux: false)
        #expect(NotchHardware.resolve(metrics, simulated: false).centerX == -756)
    }

    @Test func bareIdleFrameIsExactlyTheHardware() {
        for scale: CGFloat in [1, 2] {
            let metrics = laptop(width: 1800, height: 1169, gap: 230.4, depth: 37.6, scale: scale)
            let hardware = NotchHardware.resolve(metrics, simulated: false)
            let size = NotchIslandLayout.idleSize(slotWidth: hardware.width, notchDepth: hardware.depth,
                                                  leftShoulder: 0, rightShoulder: 0)
            let placed = NotchIslandLayout.frame(screenFrame: metrics.frame, centerX: hardware.centerX,
                                                 size: size)
            let settled = NotchIslandLayout.settled(placed, scale: scale, over: hardware.rect)
            #expect(settled == hardware.rect)
        }
    }

    @Test func aFrameNeverDipsUnderTheNotch() {
        let notch = CGRect(x: 663, y: 950, width: 186, height: 32)
        // A fold mid-flight a hair narrower and shallower than the hardware.
        let thin = CGRect(x: 664.3, y: 951.2, width: 183.1, height: 30.8)
        let settled = NotchIslandLayout.settled(thin, scale: 2, over: notch)
        #expect(settled.contains(notch))
        // A card hanging well below keeps its own shape.
        let card = CGRect(x: 586, y: 800, width: 340, height: 182)
        #expect(NotchIslandLayout.settled(card, scale: 2, over: notch) == card)
        // Slid off the notch (a pull) it is not forced back.
        let slid = CGRect(x: 586, y: 700, width: 340, height: 182)
        #expect(NotchIslandLayout.settled(slid, scale: 2, over: notch) == slid)
        // No notch, nothing to cover.
        #expect(NotchIslandLayout.settled(thin, scale: 2, over: nil).contains(thin))
    }

    @Test func aBogusScaleIsOne() {
        for scale: CGFloat in [0, -2, .nan, .infinity] {
            #expect(NotchPixelGrid.sanitized(scale) == 1)
        }
    }

    @Test func topFlareGrowsWithTheBodyAndVanishesAtTheHardware() {
        let notch: CGFloat = 186
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: notch, height: 32),
            notchWidth: notch, notchDepth: 32) == 0)
        // No notch width, no depth, no shoulders.
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: 340, height: 200),
            notchWidth: 0, notchDepth: 32) == 0)
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: 180, height: 24),
            notchWidth: notch, notchDepth: 0) == 0)
        var previous: CGFloat = 0
        for width in stride(from: notch, through: 340, by: 1) {
            let flare = NotchSilhouetteGeometry.topFlare(size: CGSize(width: width, height: 120),
                notchWidth: notch, notchDepth: 32)
            #expect(flare >= previous && flare - previous <= 0.5 + 1e-9)
            #expect(flare <= NotchSilhouetteGeometry.maximumTopFlare)
            previous = flare
        }
        #expect(previous == NotchSilhouetteGeometry.maximumTopFlare)
    }

    @Test func topFlareNeverOutgrowsASmallBody() {
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: 220, height: 3),
            notchWidth: 186, notchDepth: 32) <= 1.5)
        #expect(NotchSilhouetteGeometry.topFlare(size: .zero, notchWidth: 186, notchDepth: 32) == 0)
    }

    @Test("floored keeps a shape between pixels but never under the notch; settled snaps it")
    func flooredVersusSettled() {
        let notch = CGRect(x: 663, y: 950, width: 186, height: 32)
        let between = CGRect(x: 640.3, y: 940.1, width: 232.4, height: 41.9)
        let floored = NotchIslandLayout.floored(between, over: notch)
        #expect(floored == between.union(notch) && floored.minX == 640.3, "smooth, and over the hardware")
        let small = CGRect(x: 670.2, y: 952.7, width: 150.3, height: 29.4)
        #expect(NotchIslandLayout.floored(small, over: notch) == small.union(notch))
        let low = CGRect(x: 640.3, y: 700.1, width: 232.4, height: 100.3)
        #expect(NotchIslandLayout.floored(low, over: notch) == low, "a shape well below the notch is left alone")
        let settled = NotchIslandLayout.settled(between, scale: 2, over: notch)
        #expect(settled.minX * 2 == (settled.minX * 2).rounded() && settled.height * 2 == (settled.height * 2).rounded())
    }
}
