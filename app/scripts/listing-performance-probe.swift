import Foundation

struct MenuBarItem: Equatable { let id: Int }
enum MenuBarItemLister {
    static func sameListing(_ a: [MenuBarItem], _ b: [MenuBarItem]) -> Bool { a == b }
}

@main
struct ListingProbe {
    @MainActor static func main() async {
        var now: TimeInterval = 0
        var scans: [TimeInterval] = []
        var waits: [TimeInterval] = []
        let loop = MenuBarListingLoop(
            visible: { true }, trusted: { true },
            scan: { scans.append(now); return [MenuBarItem(id: 1)] },
            activity: { 0 }, afterScan: {},
            sleep: { interval in waits.append(interval); now += interval },
            keepGoing: { now < 600 })
        await loop.run()
        let gap = scans[scans.count - 1] - scans[scans.count - 2]
        print("virtual_seconds=600 scans=\(scans.count) steady_scans_per_minute=\(60 / gap) steady_wait_wakes_per_minute=\(60 / waits.last!)")
    }
}
