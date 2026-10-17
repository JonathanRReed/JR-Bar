import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The divider planned against frames recorded from a real notched MacBook
/// Pro (1512 × 982, macOS 27.2) on 2026-10-07, with the apps' names
/// replaced by synthetic ones and every geometry left as read. The capture
/// is `AXExtrasMenuBar` per app: x, y, width, height, owner. Nothing here
/// touches the live bar; the frames are constants.
@Suite("Menu Bar — the divider against a recorded bar")
struct MenuBarRecordedBarTests {
    /// One AX row of the capture. "icon" is JR-Bar's own item in its slim
    /// slot; the system rows are MenuBarAgent's (Control Center items and
    /// the clock). The unnotarized-era layout this was read from had the
    /// agent hiding most apps, so a few frames are stale ghosts: wdav,
    /// wispr and shottr below stand where they were last drawn.
    private struct Row {
        var x: Double, y: Double, w: Double, h: Double
        var owner: String
    }

    private static let capture: [Row] = [
        Row(x: 1145, y: 0, w: 26, h: 33, owner: "MenuBarAgent"),
        Row(x: 1187, y: 0, w: 22, h: 33, owner: "MenuBarAgent"),
        Row(x: 1329, y: 0, w: 26, h: 33, owner: "MenuBarAgent"),
        Row(x: 1371, y: 0, w: 121, h: 33, owner: "MenuBarAgent"),
        Row(x: 1028, y: 4, w: 24, h: 24, owner: "Quokka"),
        Row(x: 1253, y: 4, w: 68, h: 24, owner: "Weather"),
        Row(x: 1216, y: 4, w: 39, h: 24, owner: "Passwords"),
        Row(x: 906, y: 4, w: 40, h: 24, owner: "Heron"),
        Row(x: 1104, y: 4, w: 34, h: 24, owner: "Otter"),
        Row(x: 988, y: 4, w: 34, h: 24, owner: "Finch"),
        Row(x: 952, y: 4, w: 30, h: 24, owner: "JR-Bar"),
    ]

    /// The windows of the same moment: the notch card (layer 25, 663–849)
    /// and the Screen Bar (531–980).
    private static let notch = CGRect(x: 663, y: 0, width: 186, height: 32)
    private static let screenBar = CGRect(x: 531, y: 0, width: 449, height: 38)
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    private static func items(_ rows: [Row] = capture) -> [MenuBarItem] {
        rows.enumerated().map { index, r in
            var item = MenuBarItem(id: "\(r.owner)\(r.owner == "MenuBarAgent" ? "#\(index)" : "")",
                                   ownerPID: r.owner == "JR-Bar" ? 500 : 600 + Int32(index),
                                   ownerName: r.owner,
                                   bounds: CGRect(x: r.x, y: r.y, width: r.w, height: r.h),
                                   title: nil, windowID: UInt32(index + 1))
            item.bundleID = r.owner == "MenuBarAgent" ? "com.apple.MenuBarAgent"
                : r.owner == "JR-Bar" ? "com.jonathanreed.jrbar" : "app.\(r.owner.lowercased())"
            return item
        }
    }

    @MainActor
    private final class Host: MenuBarBoundaryHost {
        var frame: CGRect?
        var boundaryFrame: CGRect? { frame }
        var boundaryGlyphLength: CGFloat = 30
        var spacers: [CGFloat] = []
        init(frame: CGRect) { self.frame = frame }
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    /// The recorded bar through the real hider: the icon's frame is the
    /// recorded one, the fit edge is the guess the app makes on this
    /// screen (the notch's right edge plus the room macOS keeps).
    @MainActor
    private func planned() -> (MenuBarItemHider, Host) {
        let icon = Self.capture.last.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) } ?? .zero
        let host = Host(frame: icon)
        let hider = MenuBarItemHider()
        hider.rowRect = { self.row }
        hider.listItems = { Self.items() }
        hider.controlFrames = { MenuBarControlFrames(hidden: host.frame, hiddenGlyph: 30) }
        hider.guessedFitEdge = { Self.notch.maxX + MenuBarItemHider.fitInset }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "recorded" }
        hider.shuttersSuppressed = true
        hider.spacerCeiling = { MenuBarItemHider.spacerCeiling(screenWidth: 1512) }
        hider.setControlLength = { _, length in host.setBoundarySpacer(max(30, length - 30)) }
        return (hider, host)
    }

    @MainActor
    @Test("the fit edge is 903 on this screen and the spacer reaches from it to the icon's right edge")
    func spacerOnTheRecordedBar() {
        let (hider, host) = planned()
        #expect(hider.fitEdge == 903, "the notch's right edge, 849, plus the 54 pt macOS keeps for its «")
        hider.reconcile()
        hider.reconcile()
        // 982 − 903 = 79 pt of item, 30 of it the icon.
        #expect(host.spacers.last == 49)
        #expect(MenuBarItemHider.spacerCeiling(screenWidth: 1512) == 732, "far under the width macOS drops")
    }

    @MainActor
    @Test("left of the icon is hidden, right of it is shown, and the system's own items stay shown")
    func sidesOnTheRecordedBar() {
        let (hider, _) = planned()
        hider.reconcile()
        let plan = hider.lastPlan
        #expect(plan.hidden.map(\.ownerName) == ["Heron"])
        #expect(Set(plan.shown.map(\.ownerName)) == ["Finch", "Quokka", "Otter", "Passwords", "Weather", "MenuBarAgent", "JR-Bar"])
        // The icon itself is the boundary, never on the hidden side.
        #expect(!plan.hidden.contains { $0.ownerName == "JR-Bar" })
        // One app left of the icon: the first gesture is not "drag the icon".
        #expect(!MenuBarUtility.iconIsLeftmost(icon: CGRect(x: 952, y: 4, width: 30, height: 24),
                                               plan: plan, row: row))
        let content = MenuBarPositionContent.make(plan: plan, rows: [row])
        #expect(content.hidden.map(\.name) == ["Heron"])
        #expect(content.shown.map(\.name) == ["Finch", "Quokka", "Otter", "Passwords", "Weather"])
        #expect(content.parked == 0)
    }

    @MainActor
    @Test("with the icon leftmost nothing is left of it, and the first gesture is to drag the icon")
    func iconLeftmostOnTheRecordedBar() {
        var rows = Self.capture
        rows.removeAll { $0.owner == "Heron" }
        let (hider, _) = planned()
        hider.listItems = { Self.items(rows) }
        hider.reconcile()
        #expect(hider.lastPlan.hidden.isEmpty)
        #expect(MenuBarUtility.iconIsLeftmost(icon: CGRect(x: 952, y: 4, width: 30, height: 24),
                                              plan: hider.lastPlan, row: row))
    }

    @Test("the ear stops short of the divider's item, so the Screen Bar never paves the icon or the drop zone")
    func earYieldsToTheDivider() {
        let island = CGRect(x: Self.notch.minX, y: 0, width: Self.notch.width, height: 32)
        var rows = Self.capture
        rows.removeAll { $0.owner == "Heron" }
        let items = Self.items(rows)
        // Without the divider's frame the nearest foreign item on the
        // right flank sets the limit, and the wing covers the icon.
        let blind = MenuBarUtility.earLimits(items: items, island: island, row: row,
                                             concealedApps: [:], sections: [:], revealed: [], ourPID: 500)
        #expect(blind.right == 988, "the wing would run to the first foreign item, over the icon at 952–982")
        // With it, the wing ends where the item (spacer included) begins.
        let item = CGRect(x: 903, y: 4, width: 79, height: 24)
        let aware = MenuBarUtility.earLimits(items: items, island: island, row: row,
                                             concealedApps: [:], sections: [:], revealed: [], ourPID: 500,
                                             divider: item)
        #expect(aware.right == 903)
        #expect(aware.left == nil)
        // An icon parked off the row limits nothing.
        let parked = CGRect(x: 903, y: -33, width: 79, height: 24)
        #expect(MenuBarUtility.earLimits(items: items, island: island, row: row, concealedApps: [:],
                                         sections: [:], revealed: [], ourPID: 500, divider: parked).right == 988)
        // The Screen Bar of the capture ran 531–980: it did cover 952–982.
        #expect(Self.screenBar.maxX > 952)
    }

    // MARK: A crowded bar

    /// Every listed app of the recorded session shown at once, packed
    /// right to left from the system items: macOS keeps what fits right of
    /// the notch and parks the rest at the bottom of the capture.
    private func crowded() -> MenuBarHidePlan {
        let widths: [Double] = [40, 34, 34, 24, 34, 30, 36, 28, 34, 30, 26, 34, 32, 30]
        var plan = MenuBarHidePlan()
        // System items and two apps hold the right end (as recorded).
        plan.shown = Self.items(Array(Self.capture.prefix(4)))
        plan.shown += Self.items([Row(x: 1253, y: 4, w: 68, h: 24, owner: "Weather"),
                                  Row(x: 1216, y: 4, w: 39, h: 24, owner: "Passwords")])
        // The rest are parked by macOS, stacked under the « at y 970.
        plan.hidden = widths.enumerated().map { index, w in
            var item = MenuBarItem(id: "Parked\(index)", ownerPID: 700 + Int32(index), ownerName: "Parked\(index)",
                                   bounds: CGRect(x: 880, y: 970, width: w, height: 24), title: nil, windowID: 90)
            item.bundleID = "app.parked\(index)"
            return item
        }
        return plan
    }

    @Test("a bar with no room for the icon says how many items macOS holds and how few must leave")
    func roomHelpOnACrowdedBar() {
        let help = MenuBarUtility.roomHelp(plan: crowded(), rows: [row], glyph: 30, ourPID: 500)
        // The clock is the widest item on the row, wider than the 38 pt the icon needs.
        #expect(help == "macOS is holding 14 items in its « overflow. Quit or switch off at least 1 menu bar item to give the JR-Bar icon a place.")
        // A bar of nothing but narrow items needs more than one to leave.
        var narrow = crowded()
        narrow.shown = Self.items([Row(x: 1000, y: 4, w: 14, h: 24, owner: "A"),
                                   Row(x: 1020, y: 4, w: 12, h: 24, owner: "B"),
                                   Row(x: 1040, y: 4, w: 10, h: 24, owner: "C")])
        let many = MenuBarUtility.roomHelp(plan: narrow, rows: [row], glyph: 30, ourPID: 500)
        #expect(many.contains("at least 3 menu bar items"))
        // Our own item and the native « never count as something to remove.
        var own = crowded()
        own.shown = Self.items([Row(x: 952, y: 4, w: 79, h: 24, owner: "JR-Bar")])
        let none = MenuBarUtility.roomHelp(plan: own, rows: [row], glyph: 30, ourPID: 500)
        #expect(none.contains("at least 1 menu bar item"), "nothing to free is still a plain answer, not a crash")
    }
}
