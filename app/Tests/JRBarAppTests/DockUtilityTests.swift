import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Dock utility's ownership: which halves run for which settings,
/// and the card copy that explains a shared chord.
@MainActor
struct DockUtilityTests {
    @Test("the key tap runs for the switcher alone and for the watcher's keys")
    func halves() {
        func halves(_ s: DockSettings) -> [Bool] {
            let h = DockUtility.halves(for: s)
            return [h.watcher, h.tap]
        }
        var s = DockSettings(enabled: true)
        #expect(halves(s) == [true, true])
        s.provider = .dockDoor
        #expect(halves(s) == [false, true],
                "DockDoor draws the previews; our ⌥⇥ keeps its tap")
        s.enhance.windowSwitcher = false
        #expect(halves(s) == [false, false])
        s.provider = .jrbar
        #expect(halves(s) == [true, true],
                "the watcher's preview keys still need the tap")
    }

    @Test("the watcher borrows the utility's switcher rather than owning one")
    func sharedSwitcher() {
        let utility = DockUtility()
        #expect(utility.enhance.switcher === utility.switcher)
    }

    @Test("a running rival names the chord it may share")
    func conflictNote() {
        #expect(DockUtility.conflictNote(running: [], windowChord: true, appChord: false) == nil)
        #expect(DockUtility.conflictNote(running: ["AltTab"], windowChord: true, appChord: false)
                == "AltTab is running and may also take ⌥⇥")
        #expect(DockUtility.conflictNote(running: ["AltTab", "Witch"], windowChord: true, appChord: true)
                == "AltTab and Witch are running and may also take ⌥⇥ or ⌘⇥")
        #expect(DockUtility.conflictNote(running: ["Witch"], windowChord: false, appChord: false) == nil)
    }

    @Test("a counterpart pick for the switcher has a probe; JR-Bar has none")
    func switcherProbes() {
        #expect(DockUtility.probe(for: .jrbar) == nil)
        for provider in DockSwitcherProvider.allCases where provider != .jrbar {
            #expect(DockUtility.probe(for: provider) != nil)
            #expect(!DockUtility.displayName(provider).isEmpty)
        }
    }

    @Test("the watcher's knobs stand down with the previews parked or handed off")
    func watcherKnobs() {
        var s = DockSettings(enabled: true)
        #expect(DockUtility.ownsPreviews(s))
        s.provider = .dockDoor
        #expect(!DockUtility.ownsPreviews(s), "DockDoor draws — our icon gestures would do nothing")
        s.provider = .jrbar
        s.enhance.hoverPreviews = false
        #expect(!DockUtility.ownsPreviews(s))
    }

    @Test("Never Preview adds an app once, from wherever it's asked")
    func excludeOnce() {
        #expect(DockEnhanceMath.excluding("com.a", from: []) == ["com.a"])
        #expect(DockEnhanceMath.excluding("com.a", from: ["com.b", "com.a"]) == ["com.b", "com.a"])
    }

    @Test("the exclusion menu names installed apps that aren't running, once each, never listed twice")
    func installedApps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ dir: String, _ file: String, id: String, name: String?) throws {
            let contents = root.appendingPathComponent(dir).appendingPathComponent(file)
                .appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
            if let name { plist["CFBundleName"] = name }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("A", "Zed.app", id: "dev.zed", name: "Zed")
        try makeApp("A", "Beta.app", id: "com.beta", name: nil)
        try makeApp("B", "Zed Copy.app", id: "dev.zed", name: "Zed Copy")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/notes.txt"),
                                                withIntermediateDirectories: true)
        let apps = DockInstalledApps.scan([root.appendingPathComponent("A"), root.appendingPathComponent("B"),
                                           root.appendingPathComponent("missing")])
        #expect(apps == [.init(name: "Beta", bundleID: "com.beta"), .init(name: "Zed", bundleID: "dev.zed")],
                "sorted by name, one row per bundle id, the file name when the plist names none")
        let menu = DockInstalledApps.notListed(apps, excluded: ["com.beta"], running: [])
        #expect(menu.map(\.bundleID) == ["dev.zed"])
        #expect(DockInstalledApps.notListed(apps, excluded: [], running: ["dev.zed"]).map(\.bundleID) == ["com.beta"])
    }
}
