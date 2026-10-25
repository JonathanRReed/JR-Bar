import AppKit
import ApplicationServices
import Foundation

// Standalone, read-only inventory. Compile with the production observer and
// listing loop. Never creates a JR-Bar status item or connects to core.sock.
struct MenuBarItem: Equatable { let owner: pid_t; let count: Int }
@MainActor
enum MenuBarItemLister {
    static let activityChanged = Notification.Name("jrbar.live-listing-activity")
    static var barActivity: UInt64 = 0
    static func noteBarActivity() {
        barActivity &+= 1
        NotificationCenter.default.post(name: activityChanged, object: nil)
    }
    static func sameListing(_ a: [MenuBarItem], _ b: [MenuBarItem]) -> Bool { a == b }
}

@main
struct LiveListingProbe {
    @MainActor static func main() {
        guard AXIsProcessTrusted() else {
            print("ERROR accessibility_not_trusted; no live scan rate measured")
            exit(1)
        }
        let apps = NSWorkspace.shared.runningApplications
        let meterPresent = apps.contains { ["eu.exelban.Stats", "com.bjango.istatmenus.status"].contains($0.bundleIdentifier ?? "") }
        print("live_width_meter_process_present=\(meterPresent) duration_seconds=180")
        let observer = MenuBarInventoryObserver()
        let wait = MenuBarListingWait()
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarItemLister.activityChanged, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { wait.activityChanged() } }
        let start = ProcessInfo.processInfo.systemUptime
        var times: [TimeInterval] = []
        var failures = 0
        var ownerCount = 0
        var running = true
        Task { @MainActor in
            let loop = MenuBarListingLoop(
                visible: { true }, trusted: { AXIsProcessTrusted() },
                scan: {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    times.append(elapsed)
                    var items: [MenuBarItem] = []
                    for app in NSWorkspace.shared.runningApplications {
                        let element = AXUIElementCreateApplication(app.processIdentifier)
                        AXUIElementSetMessagingTimeout(element, 0.1)
                        var value: CFTypeRef?
                        let result = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &value)
                        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
                        let bar = value as! AXUIElement
                        var children: CFTypeRef?
                        let childResult = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children)
                        if childResult != .success { failures += 1 }
                        items.append(MenuBarItem(owner: app.processIdentifier, count: (children as? [AXUIElement])?.count ?? 0))
                    }
                    items.sort { $0.owner < $1.owner }
                    ownerCount = items.count
                    observer.watch(pids: Set(items.map(\.owner)))
                    print("scan_seconds=\(String(format: "%.3f", elapsed)) owners=\(ownerCount) signals=\(MenuBarItemLister.barActivity)")
                    fflush(stdout)
                    return items
                }, activity: { MenuBarItemLister.barActivity }, afterScan: {},
                sleep: { await wait.wait($0) }, keepGoing: { running })
            await loop.run()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print("elapsed_seconds=\(elapsed) scans=\(times.count) scans_per_minute=\(Double(times.count) * 60 / elapsed) signals=\(MenuBarItemLister.barActivity) child_read_failures=\(failures) owners=\(ownerCount)")
            observer.stop()
            NotificationCenter.default.removeObserver(token)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            running = false
            wait.signal()
        }
        CFRunLoopRun()
    }
}
