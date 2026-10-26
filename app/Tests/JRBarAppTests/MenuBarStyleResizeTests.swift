import AppKit
import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

@Suite("Menu bar icon width changes")
@MainActor
struct MenuBarStyleResizeTests {
    private final class Host: MenuBarBoundaryHost {
        var boundaryGlyphLength: CGFloat = 39
        var spacer: CGFloat = 0
        var boundaryFrame: CGRect? { CGRect(x: 1123 - spacer - boundaryGlyphLength, y: 4,
                                            width: spacer + boundaryGlyphLength, height: 24) }
        func setBoundarySpacer(_ length: CGFloat) { spacer = length }
        var onBoundaryClick: (@MainActor () -> Void)?
        var onBoundaryWidthChange: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    @Test("every style fits its painted content inside the divider's standing width", arguments: StatusIconStyle.allCases)
    func stylesAndLiveCounts(style: StatusIconStyle) throws {
        let host = Host()
        host.boundaryGlyphLength = 200
        let utility = MenuBarUtility()
        utility.settings = { MenuBarSettings(enabled: true) }
        utility.host = host
        let hider = utility.hider
        hider.rowRect = { CGRect(x: 0, y: 0, width: 1512, height: 33) }
        hider.listItems = { [] }
        hider.listingIsComplete = { true }
        hider.listingIsScanned = { false }
        hider.pointerHolds = { false }
        hider.guessedFitEdge = { 902 }
        hider.edgeKey = { "style-resize" }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.spacerCeiling = { .infinity }
        hider.shuttersSuppressed = true
        var time = Date(timeIntervalSince1970: 1_000)
        hider.now = { time += MenuBarItemHider.writeCooldown * 2; return time }
        defer { hider.stop() }
        hider.reconcile()
        hider.reconcile()
        let assigned = try #require(hider.assignedLengths[.hidden])
        for count in [0, 1, 6, 12, 2, 0] {
            let meters = (0..<min(count, StatusIconRenderer.maxMeters)).map {
                StatusMeter(id: "fixture-\($0)", name: "Provider \($0)", glyph: .symbol("circle"), fraction: 0.42)
            }
            let sessions = (0..<count).map { SessionDot(id: "fixture-\($0)", state: .working) }
            let plan = StatusItemController.plan(style: style, meters: meters,
                meterOverflow: max(0, count - StatusIconRenderer.maxMeters), sessionDots: sessions,
                labelText: count == 0 ? "quiet" : "\(count) working")
            host.boundaryGlyphLength = StatusItemController.paintedLength(
                imageWidth: StatusIconRenderer.size(for: plan.spec).width, label: plan.label)
            let notify = try #require(host.onBoundaryWidthChange)
            notify()
            #expect(host.spacer >= 0)
            #expect(host.spacer + host.boundaryGlyphLength <= max(assigned, host.boundaryGlyphLength),
                    "changing style or provider count must spend spacer room before growing the native item")
            let boundary = try #require(host.boundaryFrame)
            #expect(boundary.minX <= 903,
                    "shorter icons must grow the spacer immediately so items on its left stay beyond the fit edge")
            hider.reconcile()
        }
        hider.reveal([.hidden])
        host.boundaryGlyphLength = 18
        host.onBoundaryWidthChange?()
        #expect(host.spacer == 0, "a revealed divider must stay folded after another width change")
    }

    @Test func theMeterCapIsSix() {
        #expect(StatusIconRenderer.maxMeters == 6)
    }
}
