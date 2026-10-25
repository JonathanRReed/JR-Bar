import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// JR-Bar has exactly one status item, and an upgrade from a build that drew
/// more tidies up after it once.
@Suite("One status item")
struct MenuBarOneItemTests {
    /// Every Swift file under `Sources`, by path relative to it. Read once.
    private static let scanned: [(path: String, text: String)]? = try? readSources()

    /// A literal search through Foundation: Swift's own `contains` is slow
    /// over nine megabytes in a debug build.
    private static func has(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: .literal) != nil
    }

    private static func sources() throws -> [(path: String, text: String)] {
        try #require(scanned)
    }

    private static func readSources() throws -> [(path: String, text: String)] {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sourcesRoot,
                                                          includingPropertiesForKeys: nil) else { return [] }
        var out: [(path: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(sourcesRoot.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test("one guarded factory creates the status item for its controller")
    func onlyTheIconCreatesAStatusItem() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "the scan found the sources")
        let makers = files.filter { Self.has($0.text, "NSStatusBar.system.statusItem(") }
        #expect(makers.map(\.path) == ["JRBarApp/DesktopServices.swift"])
        // Born in `init`, and again only by the recovery watchdog's `recreate`.
        let factory = try #require(makers.first?.text)
        #expect(factory.components(separatedBy: "NSStatusBar.system.statusItem(").count - 1 == 1)
        let callers = files.filter { Self.has($0.text, "desktop.makeStatusItem(") }
        #expect(callers.map(\.path) == ["JRBarApp/StatusItemController.swift"])
        let controller = try #require(callers.first?.text)
        #expect(controller.components(separatedBy: "desktop.makeStatusItem(").count - 1 == 2)
    }

    @Test("nothing writes Control Center's preferences but the one-time restore")
    func controlCenterIsOnlyTouchedByTheRestore() throws {
        let files = try Self.sources()
        let openers = files.filter { Self.has($0.text, "suiteName: \"com.apple.controlcenter\"") }
        #expect(openers.map(\.path) == ["JRBarApp/AppDelegate.swift"])
        let writers = files.filter { Self.has($0.text, "NSStatusItem Visible \\(name)") }
        #expect(writers.map(\.path) == ["JRBarCore/ControlCenterRestore.swift"])
        #expect(!files.contains { Self.has($0.text, "MenuBarCombinedItem") })
        #expect(!files.contains { Self.has($0.text, "setCoveredExtrasHidden") })
    }

    // MARK: The launch migration, on fake stores

    private final class Store: DefaultsStoring {
        var values: [String: Any]
        init(_ values: [String: Any] = [:]) { self.values = values }
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
        func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    }

    @MainActor
    @Test("a user who had the combined item on gets the restore, a log line and one notice")
    func migrationRestoresLogsAndSaysOnce() {
        let cc = Store(["NSStatusItem Visible Battery": false, "NSStatusItem Visible WiFi": false])
        let ours = Store([ControlCenterRestore.savedKey: ["Battery": true, "WiFi": true]])
        let notices = LaunchNotices()
        var logged: [String] = []
        var relaunched = 0
        var cleared = 0
        var opened = 0

        let outcome = OneItemMigration.run(
            retired: ["combined"], clearRetired: { cleared += 1 },
            controlCenter: cc, ours: ours, relaunchControlCenter: { relaunched += 1 },
            log: { logged.append($0) }, notices: notices, openSettings: { opened += 1 })

        #expect(outcome.restored == ["Battery", "WiFi"])
        #expect(cc.values["NSStatusItem Visible Battery"] as? Bool == true)
        #expect(cc.values["NSStatusItem Visible WiFi"] as? Bool == true)
        #expect(relaunched == 1)
        #expect(logged.count == 1)
        #expect(logged.first?.contains("put back Battery, WiFi") == true)
        #expect(notices.waiting.count == 1)
        let notice = notices.waiting[0]
        #expect(notice.key == OneItemMigration.noticeKey)
        #expect(notice.text.contains("Control Center's Battery, Wi-Fi items are back"))
        // Nothing is marked told until the panel shows it.
        #expect(cleared == 0)
        notice.onShown?()
        #expect(cleared == 1)
        notice.action()
        #expect(opened == 1)
    }

    @MainActor
    @Test("a launch with nothing to undo and nothing retired is silent")
    func migrationIsSilentWhenThereIsNothingToDo() {
        let cc = Store()
        let ours = Store()
        let notices = LaunchNotices()
        var logged: [String] = []
        OneItemMigration.run(retired: [], clearRetired: {}, controlCenter: cc, ours: ours,
                             relaunchControlCenter: {}, log: { logged.append($0) },
                             notices: notices, openSettings: {})
        #expect(logged.isEmpty)
        #expect(notices.waiting.isEmpty)
        #expect(cc.values.isEmpty)
    }

    @MainActor
    @Test("a retired agent item or spacer rows alone are said once, with no Control Center write")
    func migrationSaysRetiredExtrasWithoutTouchingControlCenter() {
        let cc = Store(["NSStatusItem Visible Battery": false])
        let notices = LaunchNotices()
        OneItemMigration.run(retired: ["agents", "spacers"], clearRetired: {}, controlCenter: cc,
                             ours: Store(), relaunchControlCenter: {}, log: { _ in },
                             notices: notices, openSettings: {})
        #expect(cc.values["NSStatusItem Visible Battery"] as? Bool == false)
        #expect(notices.waiting.count == 1)
        #expect(notices.waiting[0].text.contains("agent item is gone"))
    }

    @MainActor
    @Test("the retired items' saved slots go, and the icon's own record stays")
    func retiredPlacementsAreForgotten() throws {
        let suite = ScratchDefaults.suiteName("jrbar.tests.oneItemPlacements")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "NSStatusItem Preferred Position com.jonathanreed.jrbar."
        defaults.set(475.0, forKey: prefix + "menubar-combined")
        defaults.set(490.0, forKey: prefix + "menubar-agents")
        defaults.set(480.0, forKey: prefix + "menubar-spacer-s1")
        defaults.set(false, forKey: "NSStatusItem Visible com.jonathanreed.jrbar.menubar-combined")
        defaults.set(304.0, forKey: StatusItemController.preferredPositionKey)
        defaults.set(250.0, forKey: "NSStatusItem Preferred Position com.example.other")
        OneItemMigration.forgetRetiredItemPlacements(in: defaults)
        #expect(defaults.object(forKey: prefix + "menubar-combined") == nil)
        #expect(defaults.object(forKey: prefix + "menubar-agents") == nil)
        #expect(defaults.object(forKey: prefix + "menubar-spacer-s1") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.jonathanreed.jrbar.menubar-combined") == nil)
        #expect(defaults.double(forKey: StatusItemController.preferredPositionKey) == 304)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position com.example.other") == 250)
    }
}
