import AppKit
import Testing
@testable import JRBarApp

@Suite("Menu Bar open menu")
struct MenuBarOpenMenuTests {
    private func window(pid: Int32 = 500, layer: Int = MenuBarItemLister.menuWindowLayer,
                        onscreen: Bool? = true) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
        ]
        if let onscreen {
            info[kCGWindowIsOnscreen as String] = NSNumber(value: onscreen)
        }
        return info
    }

    @Test("only an onscreen menu belonging to a hidden item holds its reveal")
    func visibleMenu() {
        #expect(MenuBarItemLister.menuOpen(ownerPIDs: [500], infos: [window()]))
        #expect(!MenuBarItemLister.menuOpen(ownerPIDs: [501], infos: [window()]))
        #expect(!MenuBarItemLister.menuOpen(ownerPIDs: [500], infos: [window(layer: 0)]))
    }

    @Test("retained closed menu windows do not hold a reveal")
    func retainedMenus() {
        #expect(!MenuBarItemLister.menuOpen(ownerPIDs: [500],
                                            infos: [window(onscreen: false)]))
        // optionAll omits the onscreen key for the retained menu observed
        // after dismissal, even though its popup layer and bounds remain.
        #expect(!MenuBarItemLister.menuOpen(ownerPIDs: [500],
                                            infos: [window(onscreen: nil)]))
        #expect(MenuBarItemLister.menuOpen(ownerPIDs: [500],
                                           infos: [window(onscreen: nil), window()]))
    }
}
