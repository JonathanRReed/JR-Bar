import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Notched wings keep a symmetric silhouette while either side has content.
@Suite("Screen Bar ear claim")
@MainActor
struct ScreenBarEarTests {

    @Test func unchangedQuotaDoesNotRelayoutOnEveryLightingUpdate() async throws {
        let core = CoreModel()
        // Mid-bucket: a starved runner reads the wings seconds later, and
        // the "resets in" hour must not have rolled over when it does —
        // two days lands mid-bucket in the day-scaled wording.
        var state = CoreState(usage: CoreUsage(providers: [CoreProviderUsage(
            id: "codex", windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: 42,
                resetsAt: Date().timeIntervalSince1970 + 174_600)])]))
        core.apply(.state(state))
        let store = PanelStore(core: core, screenBarShown: false)
        let first = store.screenBarWings
        #expect(first.right?.meter == 0.42)
        #expect(first.right?.text.contains("resets in") == true)
        try await Task.sleep(for: .milliseconds(10))
        #expect(store.screenBarWings == first,
                "subsecond clock changes must not invalidate an unchanged ring")
        state.usage?.providers[0].windows[0].usedPct = 50
        core.apply(.state(state))
        #expect(store.screenBarWings != first, "real usage changes must still update the ring")
    }

    /// A window-sized view with a measured right claim — the geometry a
    /// notched screen answers when the right flank has room.
    private func makeView() -> ScreenBarView {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 64))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 500,
            leftExtent: 132, rightExtent: 132)
        return view
    }

    /// The strip's end-cap tuck under the resting 8 pt corner.
    private static let restingInset = ScreenBarGeometry.stripEndInset(cornerRadius: 8)
    /// …and under a grown card's full corner.
    private static let grownInset = ScreenBarGeometry.stripEndInset(
        cornerRadius: NotchSilhouetteGeometry.maximumExpandedRadius)

    @Test func lightSitsBelowTheWholeNotchAndWings() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.islandFrame = CGRect(x: 157.5, y: 32, width: 185, height: 32)
        view.relayout()
        let tray = try #require(view.trayRect)
        #expect(view.bandRect.maxY <= tray.minY,
                "the wings must not cut through the light")
        // Ear to ear, its caps tucked inside the silhouette's corners.
        #expect(view.bandRect.minX == tray.minX + Self.restingInset)
        #expect(abs(view.bandRect.maxX - (tray.maxX - Self.restingInset)) < 1e-9)
    }

    @Test func standaloneWingsDoNotCoverTheLight() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.relayout()
        let tray = try #require(view.trayRect)
        #expect(view.bandRect.maxY <= tray.minY)
        #expect(view.bandRect.minX == tray.minX + Self.restingInset)
        #expect(abs(view.bandRect.maxX - (tray.maxX - Self.restingInset)) < 1e-9)
    }

    @Test func aGrownCardKeepsTheLightAtItsFoot() {
        let view = makeView()
        view.frame.size.height = 320
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.islandFrame = CGRect(x: 60, y: 20, width: 380, height: 300)
        view.relayout()
        #expect(view.bandRect.maxY == 20)
        // The footlight sits inside the card's round foot, not past it:
        // under the card's body, which stands in from its frame by the
        // shoulder's width.
        let body = NotchSilhouetteGeometry.body(of: view.islandFrame!, notchWidth: view.wingGeometry.notchWidth,
                                                notchDepth: view.wingGeometry.notchDepth)
        #expect(body.width < 380, "the body is narrower than the frame")
        #expect(view.bandRect.minX == body.minX + Self.grownInset)
        #expect(view.bandRect.width == body.width - 2 * Self.grownInset)
        #expect(view.bandRect.minY >= 0)
    }

    @Test func wideNotchWingsDoNotWidenAGrownCardFootlight() {
        let view = makeView()
        view.frame.size.height = 320
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 300, notchDepth: 32, bandSpan: 328,
            leftExtent: 100, rightExtent: 100)
        view.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Working", provider: "claude"),
            right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.islandFrame = CGRect(x: 90, y: 20, width: 320, height: 300)
        view.relayout()
        let body = NotchSilhouetteGeometry.body(of: view.islandFrame!, notchWidth: 300, notchDepth: 32)
        #expect(view.bandRect.minX == body.minX + Self.grownInset)
        #expect(view.bandRect.width == body.width - 2 * Self.grownInset)
    }

    @Test func theEarCollapsesWithNoSlot() {
        let view = makeView()
        #expect(view.rightWingRect == nil, "no slot means no ear — the claim is honest")
    }

    @Test func theEarCentersItsFullMarkInsideTheNativeMenuRow() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.relayout()
        let ear = try #require(view.rightWingRect)
        let tray = try #require(view.trayRect)
        #expect(ear.height == ScreenBarGeometry.wingSeatHeight)
        #expect(ear.midY == view.bounds.height - 16)
        #expect(view.bounds.height - ear.midY == 16)
        #expect(tray.minY == view.bounds.height - 32 - ScreenBarGeometry.wingEarDrop)
    }

    @Test func aMenuTitleAtTheBezelKeepsTheRightEarVisible() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        let left = try #require(view.leftWingRect)
        let right = try #require(view.rightWingRect)
        let tray = try #require(view.trayRect)
        view.rightEarLimit = 342.5 + 4
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        #expect(view.trayRect == tray)
        view.rightEarLimit = nil
        #expect(view.leftWingRect == left && view.rightWingRect == right)
    }

    @Test func theLeftEarPersistsBesideTheLastMenuTitle() throws {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 64))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 500,
            leftExtent: 60, rightExtent: 60)
        view.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Working", provider: "claude"), right: nil)
        let left = try #require(view.leftWingRect)
        let right = try #require(view.rightWingRect)
        let tray = try #require(view.trayRect)
        view.leftEarLimit = 157.5 - 20
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        view.leftEarLimit = 157.5 - 8
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        #expect(view.trayRect == tray)
    }

    @Test func aContentSlotKeepsBothEarsCompactAndBalanced() {
        let view = makeView()
        var wings = ScreenBarWings()
        wings.right = ScreenBarWingSlot(text: "track", visualizer: true)
        view.wings = wings
        #expect(view.rightWingRect?.width == 19)
        #expect(view.leftWingRect?.width == 19, "the empty peer keeps the silhouette balanced")
    }

    @Test func secondaryMarksKeepTheCompactWingsBalanced() throws {
        let view = makeView()
        let mark = ScreenBarWingSlot(text: "Working", provider: "codex")
        view.wings = ScreenBarWings(left: nil, right: mark)
        let left = try #require(view.leftWingRect)
        let right = try #require(view.rightWingRect)
        let tray = try #require(view.trayRect)
        var dressed = mark
        dressed.accessory = ScreenBarWingAccessory(symbol: ScreenBarEarMarks.leaseSymbol)
        dressed.sensors = NotchSensorState(microphoneInUse: true, cameraInUse: true)
        view.wings = ScreenBarWings(left: mark, right: dressed)
        #expect(view.leftWingRect?.width == 19)
        #expect(view.rightWingRect?.width == 19)
        #expect(view.trayRect?.width == tray.width)
        view.wings = ScreenBarWings.withSensors(NotchSensorState(cameraInUse: true), on: .empty)
        #expect(view.leftWingRect?.width == left.width)
        #expect(view.rightWingRect?.width == right.width)
        #expect(view.trayRect?.width == tray.width)
        view.wings = .empty
        #expect(view.leftWingRect == nil && view.rightWingRect == nil)
        #expect(view.trayRect == nil)
    }

    @Test func changingMenuClearanceKeepsBothEarsBalancedAndVisible() throws {
        let view = makeView()
        view.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "claude"),
                                    right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        let left = try #require(view.leftWingRect)
        let right = try #require(view.rightWingRect)
        let tray = try #require(view.trayRect)
        #expect(left.width == right.width)
        view.configureWingLayout(geometry: view.wingGeometry, leftLimit: 157.5 - 20, rightLimit: 342.5 + 50)
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        view.rightEarLimit = 342.5 + 11
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        #expect(view.trayRect == tray)
        view.rightEarLimit = nil
        #expect(view.leftWingRect == left && view.rightWingRect == right)
        #expect(view.trayRect == tray)
    }

    @Test func missingPeerClaimSuppressesBothEars() {
        let view = makeView()
        view.wings = ScreenBarWings(left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.wingGeometry.leftExtent = 0
        #expect(view.leftWingRect == nil && view.rightWingRect == nil)
    }

    @Test func notchlessSlotsDoNotReserveAnEmptyPeer() {
        let view = makeView()
        view.wingGeometry = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 0, bandSpan: 213,
                                                  leftExtent: 120, rightExtent: 120)
        view.wings = ScreenBarWings(left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        #expect(view.leftWingRect == nil)
        #expect(view.rightWingRect != nil)
        #expect(view.trayRect == nil)
    }

}
