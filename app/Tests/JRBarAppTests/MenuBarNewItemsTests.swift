import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Where an app new to the menu bar goes, and which apps a spacing
/// relaunch would quit and reopen.
@Suite("Menu Bar — new items and the spacing relaunch")
struct MenuBarNewItemsTests {
    private func item(_ id: String, owner: String, bundle: String?, pid: pid_t = 900,
                      overflow: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: owner,
                    bounds: CGRect(x: 1000, y: 6.5, width: 24, height: 24), title: nil, windowID: 0,
                    isNativeOverflowControl: overflow, bundleID: bundle)
    }

    @Test("a newcomer stays where macOS put it, or goes straight to Shown or Hidden")
    func newcomerSection() {
        #expect(MenuBarUtility.newcomerSection(.asPlaced) == nil, "the ear asks")
        #expect(MenuBarUtility.newcomerSection(.shown) == .shown)
        #expect(MenuBarUtility.newcomerSection(.hidden) == .hidden)
    }

    @Test("a relaunch lists someone else's apps once each, by name — never Apple's, never ours, never the system's")
    func relaunchCandidates() {
        var items = [
            item("Zoom", owner: "zoom.us", bundle: "us.zoom.xos"),
            item("iStat Menus#0", owner: "iStat Menus", bundle: "com.bjango.istatmenus"),
            item("iStat Menus#1", owner: "iStat Menus", bundle: "com.bjango.istatmenus"),
            item("Weather", owner: "Weather", bundle: "com.apple.weather.menu"),
            item("clock", owner: "Control Center", bundle: "com.apple.controlcenter"),
            item("helper", owner: "helper", bundle: nil),
            item("«", owner: "MenuBarAgent", bundle: "com.apple.MenuBarAgent", overflow: true),
        ]
        if let own = Bundle.main.bundleIdentifier {
            items.append(item("meter", owner: "jrbar-core", bundle: own + ".core"))
        }
        let apps = MenuBarUtility.relaunchCandidates(items)
        #expect(apps.map(\.bundleID) == ["com.bjango.istatmenus", "us.zoom.xos"])
        #expect(apps.map(\.name) == ["iStat Menus", "zoom.us"])
    }
}
