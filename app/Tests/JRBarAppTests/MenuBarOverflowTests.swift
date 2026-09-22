import AppKit
import Testing
@testable import JRBarApp

@Suite("Menu Bar item overflow geometry")
struct MenuBarOverflowTests {
    @MainActor
    @Test func crowdedPanelContentFillsNarrowGlassViewport() throws {
        let items = (0..<500).map { index in
            MenuBarItem(
                id: "item-\(index)", ownerPID: 500, ownerName: "App \(index)",
                bounds: CGRect(x: CGFloat(index * 24), y: 0, width: 24, height: 24),
                title: nil, windowID: CGWindowID(index + 1))
        }
        let tiles = MenuBarLiveTiles()
        let model = MenuBarBarModel()
        model.items = items
        model.parkedIDs = []
        let screen = NSRect(x: 0, y: 0, width: 640, height: 480)
        let intendedFrame = MenuBarBarLayout.frame(
            itemCount: items.count, menuBarDepth: 24, on: screen)
        let panel = MenuBarBarPanel(
            model: model, tiles: tiles,
            onTrigger: { _ in }, onRevealItem: { _ in })

        panel.setFrame(intendedFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()

        let glass = try #require(panel.contentView as? NSGlassEffectView)
        let hosted = try #require(glass.contentView)
        let expectedBounds = CGRect(origin: .zero, size: intendedFrame.size)
        #expect(panel.frame == intendedFrame)
        #expect(glass.frame == expectedBounds)
        #expect(hosted.frame == glass.bounds,
                "the real GeometryReader and ScrollView must fill the glass viewport")
    }

    @Test func fiveHundredItemsClampToNarrowScreenViewport() {
        let screen = NSRect(x: 0, y: 0, width: 640, height: 480)
        let frame = MenuBarBarLayout.frame(itemCount: 500, menuBarDepth: 24, on: screen)

        #expect(frame.width == screen.width - 2 * MenuBarBarLayout.edgeMargin)
        #expect(frame.minX == screen.minX + MenuBarBarLayout.edgeMargin)
        #expect(frame.maxX == screen.maxX - MenuBarBarLayout.edgeMargin)
        #expect(MenuBarBarLayout.contentSize(itemCount: 500).width > frame.width,
                "the viewport should clamp while the scrollable row keeps its capped content width")
    }

    @Test func negativeOriginScreenUsesThatScreensOwnEdges() {
        let screen = NSRect(x: -1_920, y: 40, width: 1_280, height: 1_080)
        let frame = MenuBarBarLayout.frame(itemCount: 500, menuBarDepth: 32, on: screen)

        #expect(frame.minX >= screen.minX + MenuBarBarLayout.edgeMargin)
        #expect(frame.maxX == screen.maxX - MenuBarBarLayout.edgeMargin)
        #expect(frame.maxY == screen.maxY - 32 - MenuBarBarLayout.barGap)
    }

    @Test func emptyStateHasReadableWidth() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = MenuBarBarLayout.contentSize(itemCount: 0)
        let frame = MenuBarBarLayout.frame(itemCount: 0, menuBarDepth: 24, on: screen)

        #expect(size.width == 128)
        #expect(frame.width == 128)
        #expect(frame.maxX == screen.maxX - MenuBarBarLayout.edgeMargin)
    }

    @Test func extremeItemCountNeverEscapesNormalScreen() {
        let screen = NSRect(x: 240, y: 120, width: 1_440, height: 900)
        let frame = MenuBarBarLayout.frame(
            itemCount: Int.max, menuBarDepth: 24, on: screen)

        #expect(frame.minX >= screen.minX + MenuBarBarLayout.edgeMargin)
        #expect(frame.maxX <= screen.maxX - MenuBarBarLayout.edgeMargin)
        #expect(frame.width <= screen.width - 2 * MenuBarBarLayout.edgeMargin)
        #expect(frame.minY >= screen.minY)
        #expect(frame.maxY <= screen.maxY)
    }
}
