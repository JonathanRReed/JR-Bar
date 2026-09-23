import AppKit
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// What the utility refuses to offer where it cannot work — Arrange under
/// the concealer, the extra status items macOS does not draw — and the
/// safety gates around them.
@Suite("Menu Bar — gates under the concealer")
struct MenuBarGateTests {
    @MainActor
    private final class NullBackend: MenuBarConcealBackend {
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            MenuBarAssertionToken(NSObject())
        }
        func invalidate(_ token: MenuBarAssertionToken) {}
    }

    @Test("Arrange only exists for the spacer engine")
    func arrangeGate() {
        #expect(MenuBarUtility.arrangeAvailable(concealing: false))
        #expect(!MenuBarUtility.arrangeAvailable(concealing: true))
    }

    @MainActor
    @Test("under the concealer the palette's Arrange row has no order to drive and arrangeNow is a no-op")
    func arrangeNoOpUnderConcealer() async {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false, arrangeOrder: ["A", "B"])
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        #expect(utility.menuBarArrangeOrder(for: utility.actions) == ["A", "B"])
        utility.concealer = MenuBarConcealer(backend: NullBackend())
        #expect(!utility.arrangeAvailable)
        #expect(utility.menuBarArrangeOrder(for: utility.actions).isEmpty)
        #expect(await utility.actions.arrangeMenuBar() == .alreadyInOrder)
        utility.arrangeNow()
        #expect(!utility.arranging, "no run starts — the cursor never moves")
        utility.concealer = nil
    }

    // MARK: Extras

    @Test("spacers stand down under the concealer — macOS draws none of our items there")
    func spacerGate() {
        #expect(MenuBarUtility.spacersDrawable(concealing: false))
        #expect(!MenuBarUtility.spacersDrawable(concealing: true))
    }

    @Test("Control Center's items hide only after the face has stood a settle window")
    func gateSettles() {
        var gate = MenuBarDrawnGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(gate.step(wanted: true, drawn: true, now: t0) == nil)
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(2)) == nil)
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(3)) == true)
        #expect(gate.hidden)
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(4)) == nil)
    }

    @Test("a face that vanishes brings them back after the settle window; a flicker never flips")
    func gateRestores() {
        var gate = MenuBarDrawnGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = gate.step(wanted: true, drawn: true, now: t0)
        _ = gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(3))
        // A one-pass flicker off and back on changes nothing.
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(4)) == nil)
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(5)) == nil)
        #expect(gate.hidden)
        // Gone for the settle window: restored.
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(6)) == nil)
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(9)) == false)
        #expect(!gate.hidden)
    }

    @Test("a flapping face cannot thrash Control Center: hides are at least the minimum interval apart")
    func gateThrottlesHides() {
        var gate = MenuBarDrawnGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = gate.step(wanted: true, drawn: true, now: t0)
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(3)) == true)
        _ = gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(4))
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(7)) == false)
        _ = gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(8))
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(11)) == nil,
                "settled, but only 8 s since the last hide")
        #expect(gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(13)) == true)
    }

    @Test("turning the item off restores at once; never drawn means never hidden")
    func gateOff() {
        var gate = MenuBarDrawnGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(gate.step(wanted: true, drawn: false, now: t0) == nil)
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(60)) == nil)
        #expect(!gate.hidden)
        _ = gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(61))
        _ = gate.step(wanted: true, drawn: true, now: t0.addingTimeInterval(64))
        #expect(gate.step(wanted: false, drawn: true, now: t0.addingTimeInterval(65)) == false)
        #expect(gate.release() == false)
    }

    @Test("after a crash that left Control Center's items hidden, a face that never draws gives them back")
    func gateAfterCrash() {
        var gate = MenuBarDrawnGate(hidden: true)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(gate.step(wanted: true, drawn: false, now: t0) == nil)
        #expect(gate.step(wanted: true, drawn: false, now: t0.addingTimeInterval(3)) == false)
        // With the item off the originals come back at once.
        var off = MenuBarDrawnGate(hidden: true)
        #expect(off.step(wanted: false, drawn: false, now: t0) == false)
    }

    // MARK: The compound face

    @Test("the compound face's segments sit right of the face and take their own clicks")
    func compoundClicks() {
        let segments: [(id: String, width: CGFloat)] = [("agents", 50), ("combined", 40)]
        let click = { (x: CGFloat, secondary: Bool) in
            MenuBarIconMirror.click(atX: x, chevronWidth: 14, faceWidth: 30,
                                    accessories: segments, secondary: secondary)
        }
        #expect(click(5, false) == .chevron)
        #expect(click(20, false) == .face)
        #expect(click(50, false) == .accessory("agents"))
        #expect(click(100, false) == .accessory("combined"))
        #expect(click(100, true) == .menu, "secondary is the item's menu anywhere")
        #expect(MenuBarIconMirror.panelWidth(faceWidth: 30, hiddenCount: 2, accessoryWidths: [50, 40])
                == 30 + MenuBarIconMirror.chevronZone + 90)
        let panel = NSRect(x: 100, y: 0, width: 134, height: 24)
        #expect(MenuBarIconMirror.faceFrame(in: panel, chevronWidth: 14, accessoryWidth: 90)
                == NSRect(x: 114, y: 0, width: 30, height: 24))
    }

    @MainActor
    @Test("a mirror wearing segments widens by them, speaks them, and routes their clicks")
    func mirrorWearsSegments() {
        let mirror = MenuBarIconMirror()
        var face = MenuBarIconFace()
        face.length = 24
        face.accessibilityLabel = "JR-Bar"
        mirror.update(face: face)
        let bare = mirror.panelWidth
        face.accessories = [MenuBarFaceAccessory(
            id: "agents", image: MenuBarUtility.agentDotImage(tintHex: "#00E5FF"), title: "Working",
            toolTip: "Agents — Working", accessibilityLabel: "Agents: Working", signature: "w")]
        mirror.update(face: face)
        #expect(mirror.panelWidth > bare + 10)
        #expect(mirror.accessoryView(id: "agents") != nil)
        #expect(mirror.contentView?.accessibilityLabel() == "JR-Bar, Agents: Working")
        var clicked: String?
        mirror.onAccessoryClick = { id, _ in clicked = id }
        mirror.route(.accessory("agents"), from: mirror.contentView!)
        #expect(clicked == "agents")
        face.accessories = []
        mirror.update(face: face)
        #expect(mirror.panelWidth == bare)
        #expect(mirror.accessoryView(id: "agents") == nil)
    }
}
