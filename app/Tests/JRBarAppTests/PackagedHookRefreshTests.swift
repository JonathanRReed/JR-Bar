import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Packaged hook refresh")
struct PackagedHookRefreshTests {
    @Test("only a connected supervised peer can receive the upgrade refresh")
    func refreshRequiresConnectedMatchingPeer() {
        #expect(PackagedHookRefresh.peerMatches(connected: true, peerPID: 42,
                                               supervisor: .running(pid: 42)))
        #expect(!PackagedHookRefresh.peerMatches(connected: false, peerPID: 42,
                                                supervisor: .running(pid: 42)))
    }

    @Test("upgrade refresh waits for the supervised peer, including its hello")
    func upgradeWaitsForExpectedPeer() {
        #expect(!PackagedHookRefresh.peerMatches(connected: true, peerPID: 41,
                                                supervisor: .running(pid: 42)))
        #expect(!PackagedHookRefresh.peerMatches(connected: true, peerPID: nil,
                                                supervisor: .running(pid: 42)))
        #expect(!PackagedHookRefresh.peerMatches(connected: true, peerPID: 42, supervisor: .idle))
        #expect(!PackagedHookRefresh.peerMatches(connected: true, peerPID: 42, supervisor: nil))
    }

    @Test("fresh setup stamps without installing providers, and an unchanged build does nothing")
    func freshAndUnchanged() {
        #expect(PackagedHookRefresh.action(previous: nil, current: "new", coreLive: true) == .stampOnly)
        #expect(PackagedHookRefresh.action(previous: "new", current: "new", coreLive: true) == .none)
    }

    @Test("an upgrade waits for a live core before asking it to refresh its own integrations")
    func upgradeWaitsForCore() {
        #expect(PackagedHookRefresh.action(previous: "old", current: "new", coreLive: false) == .wait)
        #expect(PackagedHookRefresh.action(previous: "old", current: "new", coreLive: true) == .refresh)
    }

    @Test("the build stamp names the bundle's shim, so moving the app refreshes the hooks")
    func stampFollowsTheBundle() {
        let home = CoreSupervisor.BundledCore(
            executable: "/Users/x/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core",
            hookShim: "/Users/x/Applications/JR-Bar.app/Contents/Helpers/jrbar-hook", version: "1.0", commit: "abc")
        let system = CoreSupervisor.BundledCore(
            executable: "/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core",
            hookShim: "/Applications/JR-Bar.app/Contents/Helpers/jrbar-hook", version: "1.0", commit: "abc")
        #expect(home.buildStamp != system.buildStamp)
        #expect(home.buildStamp.hasPrefix("1.0@abc@"))
        #expect(PackagedHookRefresh.action(previous: "1.0@abc", current: home.buildStamp, coreLive: true) == .refresh)
        #expect(PackagedHookRefresh.action(previous: home.buildStamp, current: system.buildStamp, coreLive: false) == .wait)
    }

    @Test("a rebuilt version refreshes owned hooks even with the same dirty commit and location")
    func stampFollowsBuildNumber() {
        let previous = CoreSupervisor.BundledCore(executable: "/fixture/core", hookShim: "/fixture/shim",
                                                  version: "1.0", commit: "abc-dirty", buildNumber: "41")
        var next = previous
        next.buildNumber = "42"
        #expect(previous.buildStamp != next.buildStamp)
        #expect(PackagedHookRefresh.action(previous: previous.buildStamp, current: next.buildStamp,
                                          coreLive: false) == .wait)
        #expect(PackagedHookRefresh.action(previous: previous.buildStamp, current: next.buildStamp,
                                          coreLive: true) == .refresh)
        #expect(PackagedHookRefresh.action(previous: next.buildStamp, current: next.buildStamp,
                                          coreLive: true) == .none)
    }

    @Test("the old stamp upgrades once while a fresh setup still installs no providers")
    func legacyStampUpgradesOnce() {
        let core = CoreSupervisor.BundledCore(executable: "/fixture/core", hookShim: "/fixture/shim",
                                              version: "1.0", commit: "abc", buildNumber: "42")
        #expect(PackagedHookRefresh.action(previous: "1.0@abc@/fixture/shim", current: core.buildStamp,
                                          coreLive: true) == .refresh)
        #expect(PackagedHookRefresh.action(previous: core.buildStamp, current: core.buildStamp,
                                          coreLive: true) == .none)
        #expect(PackagedHookRefresh.action(previous: nil, current: core.buildStamp,
                                          coreLive: true) == .stampOnly)
    }

    @Test("the bundled-core loader reads the build number from Info.plist")
    func loaderCarriesBuildNumber() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("jrbar-stamp-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        let executable = helpers.appendingPathComponent("jrbar-core.app/Contents/MacOS/jrbar-core")
        let shim = helpers.appendingPathComponent("jrbar-hook")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        for path in [executable, shim] {
            try Data().write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let core = try #require(CoreSupervisor.bundledCore(bundlePath: bundle.path, info: [
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "42", "JRBarCommit": "abc-dirty",
        ]))
        #expect(core.buildNumber == "42")
        #expect(core.buildStamp.hasSuffix("@build=42"))
        let unstamped = try #require(CoreSupervisor.bundledCore(bundlePath: bundle.path, info: [:]))
        #expect(unstamped.buildNumber == nil)
        #expect(unstamped.buildStamp.hasSuffix("@build=?"))
    }

    @Test("a build stamp requires every selected provider to succeed, including an honest empty selection")
    func batchCompletion() {
        let completed = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([.string("claude"), .string("codex")]),
            "results": .object([
                "claude": .object(["ok": .bool(true)]),
                "codex": .object(["ok": .bool(true)]),
            ]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: completed) == ["claude", "codex"])
        let partial = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([.string("claude"), .string("codex")]),
            "results": .object(["claude": .object(["ok": .bool(true)])]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: partial) == nil)
        let empty = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([]), "results": .object([:]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: empty) == [])
        #expect(PackagedHookRefresh.completedProviders(in: CoreReply(id: "r", ok: false)) == nil)
        #expect(PackagedHookRefresh.completedProviders(in: CoreReply(id: "r", ok: true)) == nil)
    }
}
