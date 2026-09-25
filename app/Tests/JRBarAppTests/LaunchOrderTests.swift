import Foundation
import Testing

/// The daemon is spawned before the app builds its surfaces: it takes
/// seconds to be ready, and a second of construction used to sit in
/// front of it. Launching the app in a test would put a status item in
/// the real menu bar, so this reads the launch's source order instead.
@Suite("Launch order")
struct LaunchOrderTests {
    static func launchSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/AppDelegate.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "func applicationDidFinishLaunching"))
        return String(text[start.lowerBound...])
    }

    @Test("the supervisor starts before the status item, the Screen Bar and the stores")
    func supervisorFirst() throws {
        let launch = try Self.launchSource()
        let supervise = try #require(launch.range(of: "startCoreSupervision(core: core, store: store)"))
        for surface in ["StatusItemController()", "ScreenBarController()", "SettingsStore(core: core)",
                        "ToysStore(core: core", "UtilitiesStore(core: core"] {
            let built = try #require(launch.range(of: surface), "\(surface) is no longer built at launch")
            #expect(supervise.lowerBound < built.lowerBound, "\(surface) is built before the daemon is spawned")
        }
    }
}
