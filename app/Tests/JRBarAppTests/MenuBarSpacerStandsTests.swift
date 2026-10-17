import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The spacer the divider writes stays written. Every settings write
/// re-applies the utility, and re-applying used to put the 30 pt floor over
/// the spacer while the hider still believed its length stood, so nothing
/// wrote it again and every item left of the icon was drawn (seen live,
/// 2026-10-08, 24 s after launch, at the first positional record).
@Suite("Menu Bar — the spacer stays written")
struct MenuBarSpacerStandsTests {
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    private func item(_ id: String, x: Double) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: 500, ownerName: id,
                               bounds: CGRect(x: x, y: 4, width: 28, height: 24), title: nil, windowID: 1)
        item.bundleID = "app.\(id.lowercased())"
        return item
    }

    @MainActor
    private final class Host: MenuBarBoundaryHost {
        var boundaryFrame: CGRect? { CGRect(x: 1084, y: 4, width: 39, height: 24) }
        var boundaryGlyphLength: CGFloat = 39
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    @MainActor
    @Test("native reveal folds the actual spacer and reapplying keeps it folded", arguments: [false, true])
    func nativeRevealFoldsHostSpacer(tight: Bool) {
        let utility = MenuBarUtility()
        let host = Host()
        utility.settings = { MenuBarSettings(enabled: true, revealStyle: .inline) }
        utility.host = host
        let hider = utility.hider
        hider.listingIsComplete = { true }
        hider.rowRect = { self.row }
        hider.listItems = { [self.item("Left", x: 1000)] }
        hider.guessedFitEdge = { 902 }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "native-reveal" }
        hider.spacerCeiling = { tight ? host.boundaryGlyphLength : .infinity }
        hider.pointerHolds = { false }
        hider.shuttersSuppressed = true
        var time = Date()
        hider.now = { time += MenuBarItemHider.writeCooldown * 2; return time }
        defer { hider.stop() }
        hider.reconcile()
        hider.reconcile()
        #expect(host.spacers.last == (tight ? 30 : 182))
        utility.reveal.onReveal()
        #expect(hider.revealed == [.hidden])
        #expect(hider.assignedLengths[.hidden] == host.boundaryGlyphLength)
        #expect(host.spacers.last == 0, "the native status item must fold, not retain a 30-point floor")
        #expect(!utility.bar.isOpen)
        utility.installBoundary()
        #expect(host.spacers.last == 0, "settings writes must not reopen a revealed spacer")
        hider.hide()
        #expect(host.spacers.last == (tight ? 30 : 182))
        var forced: Set<MenuBarItemSection> = [.hidden]
        hider.forcedReveal = { forced }
        hider.reconcile()
        #expect(host.spacers.last == 0)
        utility.installBoundary()
        #expect(host.spacers.last == 0)
        forced = []
        hider.reconcile()
        #expect(host.spacers.last == (tight ? 30 : 182))
    }

    @MainActor
    @Test("re-applying the utility keeps the spacer the hider wrote instead of folding it to the floor")
    func reapplyKeepsTheSpacer() {
        let utility = MenuBarUtility()
        let host = Host()
        utility.settings = { MenuBarSettings(enabled: true) }
        utility.host = host
        let hider = utility.hider
        hider.listingIsComplete = { true }
        let items = [item("Left", x: 1000), item("Right", x: 1130)]
        hider.rowRect = { self.row }
        hider.listItems = { items }
        hider.guessedFitEdge = { 902 }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "stands" }
        hider.shuttersSuppressed = true
        hider.spacerCeiling = { .infinity }
        var t = Date()
        hider.now = { t += MenuBarItemHider.writeCooldown * 2; return t }
        hider.onPlan = { [weak utility] plan in utility?.lastPlan = plan }
        // Before anything is written the host wears the floor.
        utility.installBoundary()
        #expect(host.spacers.last == MenuBarUtility.boundaryAffordance)
        // Two agreeing passes: the boundary's right edge (1123) less the fit
        // edge (902) is 221, 182 of it past the icon's own 39 pt.
        hider.reconcile()
        hider.reconcile()
        #expect(host.spacers.last == 182)
        // Every settings write lands here (the positional record is one).
        utility.installBoundary()
        #expect(host.spacers.last == 182,
                "the floor over a standing spacer drew every item left of the icon")
        // A control reinstalled by a new host starts from the floor again.
        let second = Host()
        utility.host = second
        hider.controlsReinstalled()
        utility.installBoundary()
        #expect(second.spacers.last == MenuBarUtility.boundaryAffordance)
    }

    @Test("the standing spacer is the length less the icon, never under the floor")
    func standingSpacerRule() {
        #expect(MenuBarUtility.standingSpacer(assigned: nil, glyph: 45) == 30)
        #expect(MenuBarUtility.standingSpacer(assigned: 45, glyph: 45) == 30)
        #expect(MenuBarUtility.standingSpacer(assigned: 159, glyph: 45) == 114)
        #expect(MenuBarUtility.standingSpacer(assigned: 20, glyph: 45) == 30)
    }
}
