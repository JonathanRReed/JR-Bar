import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar utility's phases 2–3 surfaces (docs/UTILITIES.md):
/// live-tile math, cover appearance mapping, profiles, and the
/// combined control plan. All pure functions of plain inputs — no
/// screen, no status item, no capture.
@Suite("Menu Bar — surfaces")
struct MenuBarSurfacesTests {
    private func item(_ id: String, owner: String = "App", x: Double, y: Double = 0,
                      w: Double = 24, h: Double = 24) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: h),
                    title: nil, windowID: 0)
    }

    /// The menu bar strip in Quartz coordinates.
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 24)

    // MARK: Live tiles — rect math and throttle

    @Test("an on-row item's capture rect is its bounds clipped to the row band")
    func tileCaptureRect() {
        let item = item("A", x: 200)
        #expect(MenuBarTileMath.captureRect(of: item, row: row)
                == CGRect(x: 200, y: 0, width: 24, height: 24))
    }

    @Test("a parked item has no pixels to capture — nil, not a fake")
    func tileCaptureRectParked() {
        let parked = item("P", x: 7, y: 970)
        #expect(MenuBarTileMath.captureRect(of: parked, row: row) == nil)
        #expect(MenuBarTileMath.capturableItems(
            [item("A", x: 100), parked], row: row).map(\.id) == ["A"])
    }

    @Test("an item half off the row's band still clips to a capturable sliver")
    func tileCaptureRectClipped() {
        // Straddles the band's bottom edge — the overlap is what shows.
        let straddler = item("S", x: 100, y: 20, h: 24)
        #expect(MenuBarTileMath.captureRect(of: straddler, row: row)
                == CGRect(x: 100, y: 20, width: 24, height: 4))
        // Entirely below: nothing.
        let below = item("B", x: 100, y: 40, h: 24)
        #expect(MenuBarTileMath.captureRect(of: below, row: row) == nil)
    }

    @Test("pixel size is whole pixels, never zero")
    func tilePixelSize() {
        let (w, h) = MenuBarTileMath.pixelSize(
            for: CGRect(x: 0, y: 0, width: 24, height: 24), scale: 2)
        #expect(w == 48 && h == 24 * 2)
        let tiny = MenuBarTileMath.pixelSize(
            for: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), scale: 1)
        #expect(tiny.width == 1 && tiny.height == 1)
    }

    @Test("a fresh capture is not re-captured inside the interval")
    func tileThrottle() {
        let now = Date()
        #expect(MenuBarTileMath.needsRefresh(lastCapturedAt: nil, now: now, interval: 0.5))
        #expect(!MenuBarTileMath.needsRefresh(lastCapturedAt: now.addingTimeInterval(-0.2),
                                              now: now, interval: 0.5))
        #expect(MenuBarTileMath.needsRefresh(lastCapturedAt: now.addingTimeInterval(-0.6),
                                             now: now, interval: 0.5))
    }

    @MainActor
    @Test("a refresh pass captures only due on-row items and drops ones that left")
    func tileRefreshPass() async {
        let tiles = MenuBarLiveTiles()
        let provider = CGDataProvider(data: Data(repeating: 255, count: 4 * 16) as CFData)!
        let cg = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil,
                         shouldInterpolate: false, intent: .defaultIntent)!
        var captured: [CGRect] = []
        tiles.capture = { rect in captured.append(rect); return cg }
        tiles.rowRects = { [self.row] }
        tiles.itemsProvider = { [
            self.item("A", x: 100), self.item("B", x: 200),
            self.item("P", x: 7, y: 970),   // parked — never captured
        ] }
        await tiles.refreshOnce()
        #expect(Set(tiles.images.keys) == ["A", "B"])
        #expect(captured.count == 2)
        // A second pass inside the interval captures nothing — the
        // throttle is what makes 2 Hz honest.
        await tiles.refreshOnce()
        #expect(captured.count == 2)
        // B leaves the bar — its tile drops with it.
        tiles.itemsProvider = { [self.item("A", x: 100)] }
        await tiles.refreshOnce()
        #expect(Set(tiles.images.keys) == ["A"])
        tiles.stop()
    }

    @MainActor
    @Test("an uncapturable ghost keeps the icon fallback — no empty-bar screenshot")
    func tileRefreshSkipsGhosts() async {
        let tiles = MenuBarLiveTiles()
        var captured: [CGRect] = []
        tiles.capture = { rect in captured.append(rect); return nil }
        tiles.rowRects = { [self.row] }
        // "G" is a concealed item's ghost — on-row frame, no pixels.
        tiles.isCapturable = { $0.id != "G" }
        tiles.itemsProvider = { [
            self.item("A", x: 100), self.item("G", x: 200),
        ] }
        await tiles.refreshOnce()
        #expect(captured.map(\.minX) == [100])
        tiles.stop()
    }

    // MARK: Appearance — settings → cover look

    @Test("defaults reproduce the shipping cover — menubar material, no tint, square, no separator")
    func appearanceDefaults() {
        let a = MenuBarCoverAppearance(settings: MenuBarSettings())
        #expect(a.material == .blend)
        #expect(a.effectMaterial == .menu)
        #expect(a.tintColor == nil)
        #expect(a.roundness == 0)
        #expect(!a.separator)
    }

    @Test("materials map to real visual-effect materials")
    func appearanceMaterials() {
        func material(_ m: MenuBarSettings.CoverMaterial) -> NSVisualEffectView.Material {
            MenuBarCoverAppearance(settings: MenuBarSettings(coverMaterial: m)).effectMaterial
        }
        #expect(material(.blend) == .menu)
        #expect(material(.menu) == .menu)
        #expect(material(.hud) == .hudWindow)
        #expect(material(.popover) == .popover)
        #expect(material(.sheet) == .sheet)
    }

    @Test("hex parsing is exact and garbage is no tint")
    func appearanceHex() {
        let c = MenuBarCoverAppearance.tintComponents("#FF8000")
        #expect(c != nil && c!.r == 1.0 && c!.g > 0.49 && c!.g < 0.51 && c!.b == 0)
        #expect(MenuBarCoverAppearance.tintComponents("") == nil)
        #expect(MenuBarCoverAppearance.tintComponents("#FF00") == nil)
        #expect(MenuBarCoverAppearance.tintComponents("notacolor") == nil)
        let back = MenuBarCoverAppearance.hex(from: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(back == "#FF0000")
    }

    @Test("opacity and roundness clamp through the settings init")
    func appearanceClamps() {
        let a = MenuBarCoverAppearance(settings: MenuBarSettings(
            coverTint: "#FF0000", coverTintOpacity: 4, coverRoundness: 99))
        #expect(a.tintColor != nil)
        #expect(a.tintColor!.alphaComponent == 1)
        #expect(a.roundness == MenuBarSettings.coverRoundnessRange.upperBound)
        let nan = MenuBarCoverAppearance(settings: MenuBarSettings(
            coverTintOpacity: .nan, coverRoundness: .nan))
        #expect(nan.tintOpacity == MenuBarSettings.defaultCoverTintOpacity)
        #expect(nan.roundness == 0)
    }

    // MARK: Profiles — capture / apply / save / rename / delete

    @Test("capture snapshots sections plus the appearance, reveal style, spacing and spacers")
    func profileCapture() {
        var settings = MenuBarSettings(enabled: true,
                                       rehideSeconds: 9, rehideMode: .untilClick,
                                       revealStyle: .inline,
                                       coverMaterial: .hud,
                                       coverTint: "#112233", coverTintOpacity: 0.5,
                                       coverRoundness: 6, showCoverSeparator: true,
                                       itemSpacing: 8,
                                       spacers: [MenuBarSettings.Spacer(id: "s1", label: "•", width: 40)])
        settings.sections = ["A": .hidden]
        let profile = MenuBarProfiles.capture(name: "Work", from: settings, id: "p1")
        #expect(profile.name == "Work")
        #expect(profile.sections == ["A": .hidden])
        #expect(profile.coverMaterial == .hud)
        #expect(profile.coverTint == "#112233")
        #expect(profile.coverTintOpacity == 0.5)
        #expect(profile.coverRoundness == 6)
        #expect(profile.showCoverSeparator)
        #expect(profile.revealStyle == .inline)
        #expect(profile.rehideMode == .untilClick)
        #expect(profile.rehideSeconds == 9)
        #expect(profile.itemSpacing == 8)
        #expect(profile.spacers == [MenuBarSettings.Spacer(id: "s1", label: "•", width: 40)])
    }

    @Test("applying a profile replaces sections and appearance; None resets to defaults")
    func profileApply() {
        var settings = MenuBarSettings(enabled: true, revealOnHover: false,
                                       coverMaterial: .hud)
        settings.sections = ["A": .alwaysHidden]
        let profile = MenuBarSettings.Profile(
            id: "p1", name: "Clean", sections: ["B": .hidden],
            coverMaterial: .popover, coverTint: "#FF0000", coverTintOpacity: 0.8,
            coverRoundness: 10, showCoverSeparator: true,
            revealStyle: .inline, rehideMode: .untilClick, rehideSeconds: 12,
            itemSpacing: 4,
            spacers: [MenuBarSettings.Spacer(id: "s1", label: "|")])
        MenuBarProfiles.apply(profile, to: &settings)
        #expect(settings.sections == ["B": .hidden])
        #expect(settings.coverMaterial == .popover)
        #expect(settings.coverTint == "#FF0000")
        #expect(settings.coverRoundness == 10)
        #expect(settings.showCoverSeparator)
        #expect(settings.revealStyle == .inline)
        #expect(settings.rehideMode == .untilClick)
        #expect(settings.rehideSeconds == 12)
        #expect(settings.itemSpacing == 4)
        #expect(settings.spacers.map(\.id) == ["s1"])
        // Reveal gestures are not the profile's business.
        #expect(!settings.revealOnHover)
        #expect(settings.enabled)

        MenuBarProfiles.apply(nil, to: &settings)
        #expect(settings.sections.isEmpty)
        #expect(settings.coverMaterial == .menu)
        #expect(settings.coverTint.isEmpty)
        #expect(!settings.showCoverSeparator)
        #expect(settings.revealStyle == .bar)
        #expect(settings.rehideMode == .timed)
        #expect(settings.rehideSeconds == MenuBarSettings.defaultRehideSeconds)
        #expect(settings.itemSpacing == 0)
        #expect(settings.spacers.isEmpty)
    }

    @Test("save-as overwrites a same-named profile, appends a new one")
    func profileSave() {
        var settings = MenuBarSettings(enabled: true)
        settings.sections = ["A": .hidden]
        let first = MenuBarProfiles.saveCurrent(as: "Work", in: &settings)
        #expect(first != nil)
        #expect(settings.profiles.count == 1)

        // Same name, new contents → same id, replaced.
        settings.sections = ["A": .hidden, "B": .alwaysHidden]
        let second = MenuBarProfiles.saveCurrent(as: "work", in: &settings)
        #expect(second == first)
        #expect(settings.profiles.count == 1)
        #expect(settings.profiles[0].sections == ["A": .hidden, "B": .alwaysHidden])

        // Unusable names save nothing.
        #expect(MenuBarProfiles.saveCurrent(as: "   ", in: &settings) == nil)
        #expect(MenuBarProfiles.saveCurrent(as: "none", in: &settings) == nil)
        #expect(settings.profiles.count == 1)
    }

    @Test("rename keeps the profile, delete drops it, and a missing id is a no-op")
    func profileRenameDelete() {
        var settings = MenuBarSettings(enabled: true,
                                       profiles: [MenuBarSettings.Profile(id: "p1", name: "One")])
        MenuBarProfiles.rename(id: "p1", to: "Renamed", in: &settings)
        #expect(settings.profiles[0].name == "Renamed")
        MenuBarProfiles.rename(id: "p1", to: "", in: &settings)
        #expect(settings.profiles[0].name == "Renamed", "a bad rename is a no-op")
        MenuBarProfiles.delete(id: "missing", in: &settings)
        #expect(settings.profiles.count == 1)
        MenuBarProfiles.delete(id: "p1", in: &settings)
        #expect(settings.profiles.isEmpty)
    }

    @Test("profiles persist through the settings' Codable round trip")
    func profileCodable() throws {
        var settings = MenuBarSettings(enabled: true)
        _ = MenuBarProfiles.saveCurrent(as: "Trip", in: &settings)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(MenuBarSettings.self, from: data)
        #expect(back.profiles == settings.profiles)
        #expect(back.coverMaterial == settings.coverMaterial)
    }

    // MARK: The hidden-items submenu

    @Test("the hidden-items submenu lists the toggle, the bar, then hidden items in order")
    func combinedMenuEntries() {
        var plan = MenuBarHidePlan()
        plan.hidden = [item("H1", x: 100), item("H2", x: 200)]
        plan.alwaysHidden = [item("D", x: 50)]
        let entries = MenuBarCombinedMenu.entries(plan: plan, hiddenRevealed: false)
        #expect(entries[0].kind == .toggleHidden(revealed: false))
        #expect(entries[0].title == "Reveal Hidden Items")
        #expect(entries[1].kind == .openBar)
        #expect(entries[2].kind == .separator)
        #expect(entries[3].kind == .item(id: "H1", section: .hidden))
        #expect(entries[5].kind == .item(id: "D", section: .alwaysHidden))
        #expect(entries[5].title.hasSuffix("— always hidden"))

        // Revealed state flips the toggle's title; an empty plan drops
        // the separator and the list entirely.
        #expect(MenuBarCombinedMenu.entries(plan: plan, hiddenRevealed: true)[0].title
                == "Hide Items Again")
        #expect(MenuBarCombinedMenu.entries(plan: MenuBarHidePlan(),
                                            hiddenRevealed: false).count == 2)
    }

    @MainActor
    @Test("applying a profile writes sections and appearance through the store path")
    func utilityApplyProfile() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true, profiles: [
            MenuBarSettings.Profile(id: "p1", name: "Focus",
                                    sections: ["X": .alwaysHidden],
                                    coverMaterial: .hud,
                                    revealStyle: .inline, itemSpacing: 4),
        ])
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft }
        utility.applyProfile(id: "p1")
        #expect(state.sections == ["X": .alwaysHidden])
        #expect(state.coverMaterial == .hud)
        #expect(state.revealStyle == .inline)
        #expect(state.itemSpacing == 4)
        // "None" is a real apply — everything back to the open state.
        utility.applyProfile(id: MenuBarProfiles.noneID)
        #expect(state.sections.isEmpty)
        #expect(state.revealStyle == .bar)
        #expect(state.itemSpacing == 0)
    }

    @MainActor
    @Test("save-as through the utility persists a profile the picker can apply")
    func utilitySaveProfile() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true, coverMaterial: .popover)
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft }
        let id = utility.saveProfileAs("Evening")
        #expect(id != nil)
        #expect(state.profiles.count == 1)
        #expect(state.profiles[0].coverMaterial == .popover)
        #expect(utility.saveProfileAs("none") == nil)
        utility.deleteProfile(id: id!)
        #expect(state.profiles.isEmpty)
    }
}
