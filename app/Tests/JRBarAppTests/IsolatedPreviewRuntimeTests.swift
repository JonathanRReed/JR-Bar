import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Isolated preview configuration")
struct IsolatedPreviewRuntimeTests {
    private let bundleID = "com.jonathanreed.jrbar.preview.v114"

    private func environment(root: URL) -> [String: String] {
        ["JRBAR_ISOLATED_PREVIEW": "1", "XDG_STATE_HOME": root.appending(path: "state").path,
         "JRBAR_CORE_SOCKET": root.appending(path: "mock.sock").path]
    }

    @Test("ordinary launches keep their current behavior")
    func normalLaunch() throws {
        #expect(try IsolatedPreviewRuntime.read(bundleID: "com.jonathanreed.jrbar", environment: [:]) == nil)
    }

    @Test("preview paths and preferences have a separate identity")
    func validPreview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jrbar-native-preview-fixture")
        let configuration = try IsolatedPreviewRuntime.read(bundleID: bundleID, environment: environment(root: root))
        let preview = try #require(configuration)
        #expect(preview.file("app-state.json").path.hasSuffix("/state/jrbar/app-state.json"))
        let state = preview.reviewState()
        #expect(state.showScreenBar && state.toys.notch.enabled && state.toys.notch.islandEnabled)
        #expect(!state.toys.notch.mediaEnabled && !state.toys.notch.calendar && !state.toys.notch.reminders)
        #expect(!state.toys.notch.mirror && !state.toys.notch.audioVisualizer)
        #expect(!state.toys.notch.lyricsConsented && !state.toys.notch.meetingAlerts)
        #expect(!state.utilities.dock.enabled && state.utilities.menuBar.enabled)
        #expect(state.utilities.menuBar.itemSpacing == 0 && !state.utilities.menuBar.itemSpacingManaged)
        #expect(state.utilities.menuBar.triggerRules.isEmpty)
    }

    @Test("preview state rejects descendant symlinks", arguments: [false, true])
    func rejectsStateSymlink(fileLink: Bool) throws {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appending(path: "jrbar-native-preview-\(UUID().uuidString)")
        let outside = temporary.appending(path: "jrbar-preview-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let state = root.appending(path: "state")
        let parent = fileLink ? state.appending(path: "jrbar") : state
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = parent.appending(path: fileLink ? "app-state.json" : "jrbar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: IsolatedPreviewRuntime.Failure.self) {
            try IsolatedPreviewRuntime.read(bundleID: bundleID, environment: environment(root: root))
        }
    }

    @Test("a requested preview rejects production identity and paths")
    func rejectsUnsafeConfiguration() {
        let root = FileManager.default.temporaryDirectory.appending(path: "jrbar-native-preview-fixture")
        let safe = environment(root: root)
        #expect(throws: IsolatedPreviewRuntime.Failure.self) {
            try IsolatedPreviewRuntime.read(bundleID: "com.jonathanreed.jrbar", environment: safe)
        }
        for change in [["JRBAR_ISOLATED_PREVIEW": "0"], ["XDG_STATE_HOME": "/Users/example/state"],
                       ["JRBAR_CORE_SOCKET": "/Users/example/.local/state/jrbar/core.sock"],
                       ["JRBAR_CORE_EXEC": "real-daemon"], ["JRBAR_LOGIN_ITEM": "on"],
                       ["XDG_STATE_HOME": "relative/state"]] {
            let changed = safe.merging(change, uniquingKeysWith: { _, new in new })
            #expect(throws: IsolatedPreviewRuntime.Failure.self) {
                try IsolatedPreviewRuntime.read(bundleID: bundleID, environment: changed)
            }
        }
    }

    @MainActor
    @Test("native sources can stay off while the Notch UI runtime remains available")
    func sourceGateDoesNotDisableUIRuntime() {
        let core = CoreModel()
        let toys = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                             nativeSourcesEnabled: false)
        toys.notch.runtimeEnabled = true
        toys.notch.sensorsWantedForPresence = { true }
        toys.notch.syncSensorMonitor()
        #expect(toys.notch.runtimeEnabled)
        #expect(!toys.notch.nativeSourcesEnabled && !toys.notch.sensorsReading)
        toys.shutdown()
    }
}
