import AppKit
import JRBarCore
import QuartzCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock preview latency", .serialized)
struct DockPreviewLatencyTests {
    private final class ImmediateLane: DockPreviewLane {
        func run<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer,
                                   then: @escaping @MainActor @Sendable (Answer) -> Void) {
            then(work())
        }
    }

    private final class Monitor: AlcoveMediaMonitor {
        override func start() { Issue.record("benchmark started a real reader") }
        override func stop() {}
    }

    /// Times controller preparation, with AX and presentation replaced by synchronous fixtures.
    /// The paired off/on batches isolate native-card setup from host drift.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_DOCK_LATENCY"] == "1"),
          arguments: ["test.synthetic", "com.apple.iCal", "com.apple.Music"])
    func showToPresent(_ bundleID: String) {
        let window = DockPreviewWindow(id: 1, title: "Synthetic window", minimized: false,
            fullScreen: nil, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            thumbnail: nil, element: nil, windowID: 1)
        let ax = DockPreviewAX(lane: ImmediateLane(), read: { _, _ in ([window], false) })
        var settings = DockEnhanceSettings()
        let preferences = DockEnhancePreferences()
        preferences.read = { settings }
        let controller = DockEnhanceController(preferences: preferences)
        let calendar = DockCalendarPreview(reader: ShelfCalendarReader(fetch: { _ in
            Issue.record("benchmark fetched Calendar"); return []
        }))
        calendar.authorization = { .fullAccess }
        calendar.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        controller.nativePreviews = DockNativePreviews(feed: MediaFeed(monitor: Monitor()), calendar: calendar)
        controller.ax = ax
        controller.running = true
        controller.apps = DockTileApps(forTile: { _, _ in
            DockTileApp(pid: 4100, name: "Synthetic", bundleID: bundleID,
                        bundleURL: nil, icon: nil, isTerminated: false)
        }, forPID: { _ in nil })
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
            frame: CGRect(x: 100, y: 900, width: 60, height: 60), title: "Synthetic",
            url: nil, kind: .app)
        var presentations = 0
        controller.presenter = { _, _ in presentations += 1 }
        for batch in 0..<5 {
            for enabled in [false, true] {
                settings.calendarPreview = enabled
                settings.mediaPreview = enabled
                var samples: [Double] = []
                for _ in 0..<250 {
                    let start = CACurrentMediaTime()
                    controller.showPreview(for: tile)
                    samples.append((CACurrentMediaTime() - start) * 1_000)
                    #expect(controller.preview.windows.map(\.title) == ["Synthetic window"])
                    controller.hidePreview()
                }
                samples.sort()
                print("DOCK_LATENCY bundle=\(bundleID) enabled=\(enabled) batch=\(batch) n=\(samples.count) p50_ms=\(samples[125]) p95_ms=\(samples[237])")
            }
        }
        #expect(presentations == 2500)
        #expect(!calendar.running && controller.nativePreviews.feed.readerCount == 0)
    }
}
