import Foundation
import Testing
@testable import JRBarCore

@Suite("The Dot's role")
struct DotRoleTests {
    @Test("an unknown or absent value reads as extend, the daemon's default")
    func parsing() {
        #expect(DotRole.parse(nil) == .extend)
        #expect(DotRole.parse("extend") == .extend)
        #expect(DotRole.parse("asks") == .asks)
        #expect(DotRole.parse("status") == .status)
        #expect(DotRole.parse("beacon") == .extend)
        #expect(DotRole.parse("") == .extend)
        #expect(DotRole.allCases.map(\.rawValue) == ["extend", "asks", "status"])
    }

    @Test("only the beacon has anything to say about completions")
    func completionsApply() {
        #expect(DotRole.asks.usesCompletions)
        #expect(!DotRole.extend.usesCompletions)
        #expect(!DotRole.status.usesCompletions)
        for role in DotRole.allCases {
            #expect(!role.label.isEmpty)
            #expect(role.explanation.count > 40, "\(role) explains itself")
        }
    }

    @Test("`role` decodes off the dot surface and nowhere else needs it")
    func surfaceDecodesRole() throws {
        let frame = """
        {"t":"lights","v":1,"surfaces":{
          "hardware":{"program":"off","led_count":8},
          "dot":{"program":"#FF9F0A 1200ms cosine\\noff 1200ms cosine\\nrepeat","led_count":2,
                 "anchor":1788982891.31,"brightness":0.8,"role":"asks","why":"waiting"}},
         "linked":true}
        """
        let message = try CoreCodec.decode(frame: Data(frame.utf8))
        guard case .lights(let lights) = message else { Issue.record("not lights"); return }
        #expect(lights.dot?.role == "asks")
        #expect(lights.hardware?.role == nil)
        #expect(DotRole.parse(lights.dot?.role) == .asks)
    }

    @Test("a dot surface with no role means the Dot is driving itself")
    func statusHasNoRole() throws {
        let frame = """
        {"t":"lights","v":1,"surfaces":{"dot":{"program":"off 200ms none","led_count":2}}}
        """
        let message = try CoreCodec.decode(frame: Data(frame.utf8))
        guard case .lights(let lights) = message else { Issue.record("not lights"); return }
        let readout = DotRoleReadout.make(chosen: .status, includeCompletions: false, dot: lights.dot)
        #expect(readout.rendersItself)
        #expect(readout.active == nil)
        #expect(!readout.settling)
        #expect(readout.headline == "Its own two-LED status code")
    }

    @Test("the extend readout names what the two bands are")
    func extendReadout() {
        let dot = CoreLightSurface(program: "0:#00E5FF 1400ms pulse", ledCount: 2, why: "working", role: "extend")
        let readout = DotRoleReadout.make(chosen: .extend, includeCompletions: false, dot: dot)
        #expect(readout.active == .extend)
        #expect(!readout.rendersItself)
        #expect(!readout.settling)
        #expect(readout.headline == "Extending the strip")
        #expect(readout.detail?.contains("0–3") == true)
    }

    @Test("the beacon reads its colour out of the why the role decides")
    func beaconStates() {
        func headline(_ why: String, program: String = "#FF9F0A 1200ms cosine", include: Bool = false) -> String {
            let dot = CoreLightSurface(program: program, ledCount: 2, why: why, role: "asks")
            return DotRoleReadout.make(chosen: .asks, includeCompletions: include, dot: dot).headline
        }
        #expect(headline("waiting").contains("amber"))
        #expect(headline("needs_you").contains("amber"))
        #expect(headline("failed").contains("red"))
        #expect(headline("completed", include: true).contains("green"))
        #expect(headline("idle", program: "off").contains("dark"))
    }

    @Test("a green beacon with completions off explains why it is on")
    func completionsHint() {
        let dot = CoreLightSurface(program: "#00FF66 1200ms cosine", ledCount: 2, why: "completed", role: "asks")
        let off = DotRoleReadout.make(chosen: .asks, includeCompletions: false, dot: dot)
        #expect(off.detail?.contains("Also glow for finished runs") == true)
        let on = DotRoleReadout.make(chosen: .asks, includeCompletions: true, dot: dot)
        #expect(on.detail?.contains("slowest cadence") == true)
    }

    @Test("a choice the core has not picked up yet is called out, and status is not")
    func settling() {
        let extending = CoreLightSurface(program: "off", ledCount: 2, why: "idle", role: "extend")
        let pending = DotRoleReadout.make(chosen: .asks, includeCompletions: false, dot: extending)
        #expect(pending.settling)
        #expect(pending.detail == "The core has not picked this up yet.")
        // The daemon reports `status` by leaving the key off, so the frame
        // with no role and the picker on Status agree.
        let own = CoreLightSurface(program: "off 200ms none", ledCount: 2)
        #expect(!DotRoleReadout.make(chosen: .status, includeCompletions: false, dot: own).settling)
        // …and the same frame with the picker on Extend has not landed yet.
        #expect(DotRoleReadout.make(chosen: .extend, includeCompletions: false, dot: own).settling)
    }

    @Test("unlinked, no role is in effect whatever the key says")
    func unlinked() {
        let dot = CoreLightSurface(program: "off 200ms none", ledCount: 2)
        let readout = DotRoleReadout.make(chosen: .asks, includeCompletions: false, linked: false, dot: dot)
        #expect(readout.unlinked)
        #expect(!readout.settling, "an unlinked Dot is not waiting for the core to catch up")
        #expect(readout.headline == "Its own two-LED status code")
        #expect(readout.detail?.contains("not linked") == true)
        // Linked is the default, and the same frame then reads as pending.
        #expect(DotRoleReadout.make(chosen: .asks, includeCompletions: false, dot: dot).unlinked == false)
    }

    @Test("no dot surface at all says so instead of guessing")
    func noDot() {
        let readout = DotRoleReadout.make(chosen: .extend, includeCompletions: false, dot: nil)
        #expect(readout.active == nil)
        #expect(!readout.rendersItself)
        #expect(readout.headline == "No Dot in the lights frame")
    }

    @Test("both keys are in the Devices catalogue")
    func catalogued() {
        let devices = SettingsKey.keys(on: .devices).map(\.path)
        #expect(devices.contains("dot_role"))
        #expect(devices.contains("dot_role_include_completions"))
        #expect(devices.contains("linked_dot_scale"))
        #expect(SettingsKey.all.first { $0.path == "dot_role" }?.kind == .string)
        #expect(SettingsKey.all.first { $0.path == "dot_role_include_completions" }?.kind == .bool)
    }
}

@Suite("The Dot's role against the mock", .serialized)
struct DotRoleMockTests {
    @Test("writing dot_role republishes lights with the role the Dot is playing")
    @MainActor
    func roleRoundTrip() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        // --start-at 2 opens the Codex permission ask, so the beacon has
        // something to be amber about.
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "60", "--start-at", "2"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.isLive && model.lights != nil && model.settings != nil })

        // The default: the Dot extends the strip and says so.
        #expect(SettingsDocument(model.settings!.document).string("dot_role") == "extend")
        #expect(await MockCoreIntegrationTests.wait { model.lights?.dot?.role == "extend" })
        #expect(model.lights?.dot?.ledCount == 2)

        // The beacon: amber while the ask is open.
        #expect(try await model.setSetting("dot_role", value: "asks").ok)
        #expect(await MockCoreIntegrationTests.wait { model.lights?.dot?.role == "asks" })
        let beacon = try #require(model.lights?.dot)
        #expect(beacon.why == "waiting")
        #expect(beacon.program.contains("#FF9F0A"))
        #expect(DotRoleReadout.make(chosen: .asks, includeCompletions: false, dot: beacon).headline.contains("amber"))

        // Status: the Dot renders itself and the frame carries no role.
        #expect(try await model.setSetting("dot_role", value: "status").ok)
        #expect(await MockCoreIntegrationTests.wait { model.lights?.dot != nil && model.lights?.dot?.role == nil })
        #expect(DotRoleReadout.make(chosen: .status, includeCompletions: false, dot: model.lights?.dot).rendersItself == true)

        // The completions switch is a plain bool the daemon keeps.
        #expect(try await model.setSetting("dot_role_include_completions", value: true).ok)
        #expect(await MockCoreIntegrationTests.wait {
            SettingsDocument(model.settings!.document).bool("dot_role_include_completions") == true
        })
    }
}
