import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Enhance mode's pure machinery (the hover debounce, the AX↔AppKit
/// geometry, the thumbnail match), the icon rasterizer, and
/// `AppleDockControl`'s `autohide-delay` save/restore with its
/// crash-safe persistence — kept because a Mac the old Replace bar
/// left hidden must still get Apple's Dock back.
@MainActor
@Suite struct DockEnhanceTests {

    // MARK: Hover debounce

    @Test func aRestedIconOpensThePanel() {
        var tracker = DockHoverTracker()
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0.24, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0.26, delay: 0.25) == .show("Safari"))
        #expect(tracker.shown == "Safari")
    }

    @Test func aQuickPassDoesNotOpen() {
        var tracker = DockHoverTracker()
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.1, delay: 0.25) == .none)
        #expect(tracker.shown == nil, "each icon restarts the rest clock")
    }

    @Test func leavingPastTheGraceCloses() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.shown == "Safari")
        #expect(tracker.note(hovered: nil, pointerInPanel: false,
                             now: 0.3, delay: 0.1) == .none,
                "inside the grace, the panel holds")
        #expect(tracker.note(hovered: nil, pointerInPanel: false,
                             now: 0.3 + DockHoverTracker.grace + 0.01, delay: 0.1) == .hide)
        #expect(tracker.shown == nil)
    }

    @Test func thePointerOnThePanelKeepsItOpen() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.note(hovered: nil, pointerInPanel: true,
                             now: 1.0, delay: 0.1) == .none,
                "hovering the preview is not leaving")
        #expect(tracker.shown == "Safari")
    }

    @Test func movingToAnotherIconRetargets() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.3, delay: 0.1) == .none)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.41, delay: 0.1) == .show("Mail"),
                "the rested new icon takes the panel over — no flicker")
    }

    // MARK: Geometry

    @Test func axAndAppKitCoordinatesFlip() {
        #expect(DockEnhanceMath.axPoint(CGPoint(x: 100, y: 50), mainScreenHeight: 1000)
                == CGPoint(x: 100, y: 950))
        #expect(DockEnhanceMath.appKitRect(CGRect(x: 10, y: 900, width: 20, height: 30),
                                           mainScreenHeight: 1000)
                == CGRect(x: 10, y: 70, width: 20, height: 30))
    }

    @Test func theDockEdgeIsTheNearestScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 200, y: 0, width: 1000, height: 70),
                                         screen: screen) == .bottom)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 0, y: 200, width: 70, height: 500),
                                         screen: screen) == .left)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 1370, y: 200, width: 70, height: 500),
                                         screen: screen) == .right)
    }

    @Test func thePanelOpensOffTheDockTowardTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let item = CGRect(x: 700, y: 0, width: 40, height: 40)
        let size = CGSize(width: 200, height: 100)
        let bottom = DockEnhanceMath.panelFrame(anchor: item, edge: .bottom,
                                                size: size, screen: screen, gap: 10)
        #expect(bottom == CGRect(x: 620, y: 50, width: 200, height: 100),
                "centred on the icon, floating above it")
        let right = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 1400, y: 400, width: 40, height: 40), edge: .right,
            size: size, screen: screen, gap: 10)
        #expect(right.origin.x == 1190, "a right-edge dock opens left of it")
    }

    @Test func thePanelStaysOnScreenAtTheEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 0, y: 0, width: 40, height: 40), edge: .bottom,
            size: CGSize(width: 300, height: 100), screen: screen, gap: 10)
        #expect(frame.minX >= screen.minX, "an edge icon clamps the panel inside")
        #expect(frame.maxX <= screen.maxX + 1)
    }

    // MARK: autohide-delay save/restore

    /// The full-fidelity fake — the delay verbs exist so a bool-only
    /// fake can't fake the new behaviour.
    private final class FakeDefaults: AppleDockDefaults {
        var bools: [String: Bool] = [:]
        var doubles: [String: Double] = [:]
        var removed: [String] = []
        func boolValue(forKey key: String) -> Bool? { bools[key] }
        func setBool(_ value: Bool, forKey key: String) { bools[key] = value }
        func doubleValue(forKey key: String) -> Double? { doubles[key] }
        func setDouble(_ value: Double, forKey key: String) { doubles[key] = value }
        func removeValue(forKey key: String) {
            bools[key] = nil
            doubles[key] = nil
            removed.append(key)
        }
    }

    private func freshPersistence(_ name: String) -> UserDefaults {
        let suite = "DockEnhanceTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func hidingPinsTheRevealDelayToo() {
        let defaults = FakeDefaults()
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("hidePins"))
        control.restartDock = {}

        control.setAppleDockHidden(true)

        #expect(defaults.bools["autohide"] == true)
        #expect(defaults.doubles["autohide-delay"] == AppleDockControl.hiddenDelay,
                "autohide alone leaves the edge one hover away — the delay seals it")
        #expect(control.savedDelay == .absent, "the key wasn't there — restore removes ours")
    }

    @Test func restoreHandsBackASavedDelay() {
        let defaults = FakeDefaults()
        defaults.doubles["autohide-delay"] = 0.4
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("delayValue"))
        control.restartDock = {}

        control.setAppleDockHidden(true)
        #expect(control.restore() == true)

        #expect(defaults.doubles["autohide-delay"] == 0.4)
        #expect(defaults.removed.isEmpty, "a real value restores as a write, not a removal")
    }

    @Test func restoreRemovesADelayThatWasAbsent() {
        let defaults = FakeDefaults()
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("delayAbsent"))
        control.restartDock = {}

        control.setAppleDockHidden(true)
        #expect(control.restore() == true)

        #expect(defaults.doubles["autohide-delay"] == nil)
        #expect(defaults.removed == ["autohide-delay"],
                "absent restores as absent — we don't leave a 0 behind")
    }

    @Test func aCrashCantStrandTheDockHidden() {
        let suite = freshPersistence("crashSafe")
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = false
        let first = AppleDockControl(defaults: defaults, persistence: suite)
        first.restartDock = {}
        first.setAppleDockHidden(true)
        // …process dies before restore runs.

        let second = AppleDockControl(defaults: defaults, persistence: suite)
        second.restartDock = {}
        #expect(second.savedAutohide == false,
                "the saved value survives into the next launch")
        #expect(second.restore() == true)
        #expect(defaults.bools["autohide"] == false)
    }

    // MARK: Replace-mode hide policy

    @Test func anAlreadyPinnedDockIsNotRestartedAgain() {
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = true
        defaults.doubles["autohide-delay"] = AppleDockControl.hiddenDelay
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("alreadyPinned"))
        var restarts = 0
        control.restartDock = { restarts += 1 }

        control.setAppleDockHidden(true)

        #expect(restarts == 0, "nothing changed — don't bounce the Dock for it")
        #expect(control.savedAutohide == true, "still saved so restore stays armed")
    }

    @Test func reassertRepinsADriftedDockOnce() {
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = false
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("reassert"))
        var restarts = 0
        control.restartDock = { restarts += 1 }

        control.setAppleDockHidden(true)
        defaults.bools["autohide"] = false // the relaunched Dock lost the write

        control.reassertPinned()
        #expect(defaults.bools["autohide"] == true)
        #expect(defaults.doubles["autohide-delay"] == AppleDockControl.hiddenDelay)
        #expect(restarts == 2)

        control.reassertPinned()
        #expect(restarts == 2, "the values hold — the re-assert is a no-op")
    }

    @Test func reassertWithoutALiveHideDoesNothing() {
        let defaults = FakeDefaults()
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("reassertIdle"))
        var restarts = 0
        control.restartDock = { restarts += 1 }

        control.reassertPinned()

        #expect(defaults.bools.isEmpty && defaults.doubles.isEmpty,
                "no hide is live — the re-assert invents no writes")
        #expect(restarts == 0)
    }

    @Test func restoreHandsBackTheUsersOwnAutohideAndDelay() {
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = true
        defaults.doubles["autohide-delay"] = 0.4
        let control = AppleDockControl(defaults: defaults,
                                       persistence: freshPersistence("ownValues"))
        control.restartDock = {}

        control.setAppleDockHidden(true)
        #expect(control.restore() == true)

        #expect(defaults.bools["autohide"] == true)
        #expect(defaults.doubles["autohide-delay"] == 0.4,
                "restore means THEIR values, not our pin")
    }

    // MARK: Icon resolution

    private func solidImage(pixels: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage() }
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(rep)
        return image
    }

    @Test func rasterizeHitsRetinaPixelsWhenTheSourceCan() {
        let image = DockIconResolver.rasterized(solidImage(pixels: 512),
                                                pointSize: 56, scale: 2)
        #expect(image.size == NSSize(width: 56, height: 56),
                "the asset is sized in points…")
        #expect(image.representations.map(\.pixelsWide).max() == 112,
                "…and its bitmap is the full 2×")
    }

    @Test func rasterizeNeverUpscalesASmallRep() {
        let image = DockIconResolver.rasterized(solidImage(pixels: 32),
                                                pointSize: 56, scale: 2)
        #expect(image.representations.map(\.pixelsWide).max() == 32,
                "a 32 px icon stays a 32 px asset — no smear")
    }

    // MARK: Enhance preferences

    @Test func enhancePrefsRideTheSettings() {
        var settings = DockEnhanceSettings()
        let prefs = DockEnhancePreferences()
        prefs.read = { settings }
        prefs.write = { settings = $0 }
        #expect(prefs.previewDelay == DockEnhancePreferences.defaultDelay)
        #expect(prefs.showThumbnails == true)
        prefs.previewDelay = 0.6
        prefs.showThumbnails = false
        #expect(settings.previewDelay == 0.6)
        #expect(settings.showThumbnails == false,
                "a card write lands in the persisted settings struct")
        prefs.previewDelay = 99
        #expect(settings.previewDelay == DockEnhanceSettings.delayRange.upperBound,
                "an out-of-range delay clamps through the settings write")
    }

    @Test func legacyEnhanceDefaultsMigrateIntoTheSettings() {
        // The migration reads `.standard`, so plant the keys there and
        // always clean up after.
        defer {
            UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
            UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
        }
        UserDefaults.standard.set(0.7, forKey: DockEnhancePreferences.legacyDelayKey)
        UserDefaults.standard.set(false, forKey: DockEnhancePreferences.legacyThumbnailsKey)
        var stored = DockSettings()
        let utility = DockUtility()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }
        utility.applySettings()
        #expect(stored.enhance.previewDelay == 0.7)
        #expect(stored.enhance.showThumbnails == false)
        #expect(UserDefaults.standard.object(forKey: DockEnhancePreferences.legacyDelayKey) == nil,
                "the legacy key is removed after the fold")
    }

    @Test func legacyMigrationLeavesCleanSettingsAlone() {
        UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
        UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
        var stored = DockSettings()
        var writes = 0
        let utility = DockUtility()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0; writes += 1 }
        utility.applySettings()
        #expect(writes == 0, "no legacy keys, no write")
    }

    // MARK: Thumbnail matching

    @Test func thumbnailsMatchByFrameFirstThenTitle() {
        let rows: [(frame: CGRect?, title: String)] = [
            (CGRect(x: 100, y: 100, width: 800, height: 600), "Untitled window"),
            (CGRect(x: 100, y: 100, width: 800, height: 600), "Untitled window"),
            (nil, "Notes — Groceries"),
        ]
        // An exact frame wins the first matching row.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 101, y: 99, width: 800, height: 601), scTitle: nil, rows: rows) == 0)
        // No frame match → title.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 0, y: 0, width: 300, height: 300),
            scTitle: "Notes — Groceries", rows: rows) == 2)
        // Neither → nothing, never a guess.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 0, y: 0, width: 300, height: 300), scTitle: "", rows: rows) == nil)
    }

    @Test func cardSizesAreSixteenByTen() {
        let small = DockEnhanceMath.cardSize(large: false)
        let large = DockEnhanceMath.cardSize(large: true)
        #expect(small.width / small.height == 1.6)
        #expect(large.width / large.height == 1.6)
        #expect(large.width > small.width)
    }

    @Test func hoverIdentityPrefersTheTileURL() {
        let element = AXUIElementCreateSystemWide()
        let byURL = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                               title: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let byTitle = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                                 title: "Safari", url: nil)
        let bySlot = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                                title: nil, url: nil)
        #expect(byURL.hoverID == "/Applications/Safari.app")
        #expect(byTitle.hoverID == "Safari")
        #expect(bySlot.hoverID == "dock-item@10")
    }

    @Test func permissionsAreCachedNotPolled() {
        let controller = DockEnhanceController()
        controller.refreshPermissions(force: true)
        let first = controller.accessibilityTrusted
        controller.refreshPermissions()
        #expect(controller.accessibilityTrusted == first)
        #expect(DockEnhanceController.permissionTTL >= 1,
                "a TCC probe is an IPC round trip; the tick must not pay it 20× a second")
    }
}
