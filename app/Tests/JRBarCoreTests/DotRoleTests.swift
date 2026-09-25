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
        #expect(DotRole.parse("call") == .call, "the daemon's busylight role is no longer read as extend")
        #expect(DotRole.parse("beacon") == .extend)
        #expect(DotRole.parse("") == .extend)
        #expect(DotRole.allCases.map(\.rawValue) == ["extend", "asks", "call", "status"])
    }

    @Test("only the beacon, and the call light between calls, speak to completions")
    func completionsApply() {
        #expect(DotRole.asks.usesCompletions)
        #expect(DotRole.call.usesCompletions)
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

    @Test("the call light reads red on a call or in a meeting, and the beacon between")
    func callLight() {
        func readout(_ why: String, program: String = "#FF2D20", include: Bool = false) -> DotRoleReadout {
            let dot = CoreLightSurface(program: program, ledCount: 2, why: why, role: "call")
            return DotRoleReadout.make(chosen: .call, includeCompletions: include, dot: dot)
        }
        let onCall = readout("on_call")
        #expect(onCall.active == .call)
        #expect(!onCall.settling)
        #expect(onCall.headline == "Call light: steady red, on a call")
        #expect(onCall.detail?.contains("camera") == true)
        #expect(readout("in_meeting").headline == "Call light: steady red, in a meeting")
        // Between calls it is the beacon, and says what will turn it red.
        let waiting = readout("waiting", program: "#FF9F0A 1200ms cosine")
        #expect(waiting.headline.contains("amber"))
        #expect(waiting.detail?.hasSuffix("Steady red once a call has the mic or camera.") == true)
        #expect(readout("idle", program: "off").headline.contains("dark"))
        #expect(readout("completed", program: "#00FF66 1200ms cosine").detail?
                    .contains("Also glow for finished runs") == true)
        // The picker offers it, under a name of its own.
        #expect(DotRole.call.label == "Call light")
        #expect(DotRole.call.explanation.contains("camera"))
        // Nothing the app sends puts a meeting on the light; the picker
        // does not promise one.
        #expect(!DotRole.call.explanation.contains("meeting"))
    }

    @Test("a shut lid's beacon on an extend Dot is the rule working, not a choice in flight")
    func lidClosedBeacon() {
        // With the lid shut the daemon plays `extend` as the beacon and
        // echoes `asks` (docs/CORE-PROTOCOL.md, `auto:lid_closed`).
        let dot = CoreLightSurface(program: "#FF9F0A 1200ms cosine", ledCount: 2, why: "waiting", role: "asks")
        let shut = DotRoleReadout.make(chosen: .extend, includeCompletions: false, lidClosed: true, dot: dot)
        #expect(!shut.settling)
        #expect(shut.lidBeacon)
        #expect(shut.active == .asks)
        #expect(shut.headline.contains("amber"))
        #expect(shut.detail == "The lid is shut, so the strip and the band are out of sight: the Dot is the alert beacon until it opens.")
        // Lid open, the same frame is still a change on its way.
        let open = DotRoleReadout.make(chosen: .extend, includeCompletions: false, lidClosed: false, dot: dot)
        #expect(open.settling)
        #expect(!open.lidBeacon)
        #expect(open.detail == "The monitor has not picked this up yet.")
        // The lid never excuses any other mismatch.
        let status = CoreLightSurface(program: "off 200ms none", ledCount: 2)
        #expect(DotRoleReadout.make(chosen: .extend, includeCompletions: false, lidClosed: true, dot: status).settling)
        let extending = CoreLightSurface(program: "off", ledCount: 2, why: "idle", role: "extend")
        #expect(DotRoleReadout.make(chosen: .asks, includeCompletions: false, lidClosed: true, dot: extending).settling)
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
        #expect(pending.detail == "The monitor has not picked this up yet.")
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

    @Test("the daemon's dot_link states map to readouts the settings cannot express")
    func linkStates() {
        let dot = CoreLightSurface(program: "off 200ms none", ledCount: 2)
        // `no_strip`: changing the role is how you fix it, so it is a
        // steady state, not a settling one.
        let noStrip = DotRoleReadout.make(chosen: .extend, includeCompletions: false,
                                          link: CoreDotLink(state: "no_strip", role: "extend"), dot: dot)
        #expect(noStrip.headline == "Nothing to extend")
        #expect(noStrip.detail == "No strip is connected. Plug in the SidePulse, or pick Alert beacon or On its own, which need no strip.")
        #expect(!noStrip.settling)
        // `failed`: the error class is the detail.
        let failed = DotRoleReadout.make(chosen: .extend, includeCompletions: false,
                                         link: CoreDotLink(state: "failed", role: "extend", error: "DeviceWriteError"), dot: dot)
        #expect(failed.headline == "The Dot's last linked write failed")
        #expect(failed.detail == "DeviceWriteError")
        #expect(!failed.settling)
        // `off` is the unlinked readout; `no_dot` is the missing one.
        let off = DotRoleReadout.make(chosen: .asks, includeCompletions: false,
                                      link: CoreDotLink(state: "off"), dot: dot)
        #expect(off.unlinked)
        let noDot = DotRoleReadout.make(chosen: .extend, includeCompletions: false,
                                        link: CoreDotLink(state: "no_dot"), dot: nil)
        #expect(noDot.headline == "No Dot in the lights frame")
    }

    @Test("the extend readout's timing comes from the measured phase error, never a bare claim")
    func timingLine() {
        let dot = CoreLightSurface(program: "0:#00E5FF 1400ms pulse", ledCount: 2, why: "working", role: "extend")
        func detail(_ configure: (inout CoreDotLink) -> Void, skew: Double? = nil) -> String {
            var link = CoreDotLink(state: "linked", role: "extend")
            configure(&link)
            return DotRoleReadout.make(chosen: .extend, includeCompletions: false, link: link,
                                       linkedSkewMs: skew, linkedSkewFresh: skew != nil, dot: dot).detail ?? ""
        }
        // Nothing measured yet: nothing claimed, whatever the write gap said.
        let unmeasured = detail({ _ in }, skew: 11)
        #expect(!unmeasured.contains("In step"))
        #expect(!unmeasured.contains("ms of the strip"))
        // Measured and inside the tolerance, with the Dot's clock named.
        let held = detail({ $0.phaseErrorMs = -18.4; $0.clockRate = 0.9734; $0.clockSource = "measured"; $0.toleranceMs = 40 })
        #expect(held.contains("Within 18 ms of the strip; the Dot's clock runs 2.7% slow, corrected."))
        // Past the tolerance: the loop is on it, and says so.
        let drifting = detail({ $0.phaseErrorMs = 64; $0.clockRate = 0.9734; $0.clockSource = "measured"; $0.toleranceMs = 40 })
        #expect(drifting.contains("Re-syncing: 64 ms off the strip."))
        // Fresh reads broken: re-synced blind, and the reader is told why.
        let blind = detail({ $0.phaseErrorMs = 5; $0.clockSource = "frozen" })
        #expect(blind.contains("re-synced every minute"))
        // Correction off: only the start is on the beat.
        let off = detail({ $0.phaseErrorMs = 0; $0.clockRate = 1; $0.clockSource = "off" })
        #expect(off.contains("clock correction is off"))
        // Check sync running.
        let checking = detail({ $0.phaseErrorMs = 3; $0.checkUntil = Date().timeIntervalSince1970 + 30 })
        #expect(checking.contains("Checking sync"))
        // The period lock's fallbacks name what the two LEDs show instead.
        #expect(detail({ $0.rung = "average" }).contains("average"))
        #expect(detail({ $0.rung = "static" }).contains("A still colour"))
        let continuing = DotRoleReadout.make(chosen: .extend, includeCompletions: false,
                                             link: { var link = CoreDotLink(state: "linked", role: "extend"); link.rung = "continue"; return link }(),
                                             dot: dot)
        #expect(continuing.headline == "Continuing the strip")
        for text in [unmeasured, held, drifting, blind, off, checking] {
            #expect(!text.contains("In step") && !text.contains("Kept in step"))
        }
        // `linked_skew_at` still decides whether an old skew is fresh.
        let now = Date().timeIntervalSince1970
        #expect(CoreLights(linkedSkewMs: 11, linkedSkewAt: now).isLinkedSkewFresh)
        #expect(!CoreLights(linkedSkewMs: 11, linkedSkewAt: now - 31 * 60).isLinkedSkewFresh)
    }

    @Test("the real lights frame carries the link's timing and the device receipts")
    func realLightsTiming() throws {
        guard case .lights(let lights) = try CoreFixtures.message("real_lights.json") else {
            Issue.record("not lights"); return
        }
        let link = try #require(lights.dotLink)
        #expect(link.phaseErrorMs == 18.4)
        #expect(link.clockRate == 0.9734)
        #expect(link.clockSource == "measured")
        #expect(link.toleranceMs == 40)
        #expect(link.syncWritesHour == 3)
        #expect(link.rotation == "exact")
        #expect(link.style == "mirror" && link.rung == "brightest")
        let receipt = try #require(lights.deviceReceipts["sidepulse:pro:serial:67"])
        #expect(receipt.foreignWrites == 1 && !receipt.paused)
        #expect(DeviceReceiptWords.line(receipt, deviceName: "SidePulse")?.contains("Another app wrote") == true)
        var paused = receipt
        paused.paused = true
        #expect(DeviceReceiptWords.line(paused, deviceName: "SidePulse")?.contains("stopped rewriting") == true)
        #expect(DeviceReceiptWords.line(nil, deviceName: "SidePulse") == nil)
        // A daemon that sends none of it still decodes.
        let bare = try JSONDecoder().decode(CoreDotLink.self, from: Data(#"{"state":"linked"}"#.utf8))
        #expect(bare.phaseErrorMs == nil && bare.clockRate == nil)
    }

    @Test("the eject guard reads as what it protects, not whether it is installed")
    func ejectGuardWords() {
        let never = EjectGuardReading.parse(.object([
            "installed": .bool(true), "protects": .bool(false), "protects_mounted": .bool(false),
            "running": .bool(false), "runs": .number(0), "mounted_volume_uuid": .string("5E1F0C2A-7B3D-4C8E-9A61-0D2F4B6C8E10"),
        ]))
        #expect(never?.words.contains("never run") == true)
        #expect(never?.canProtect == true)
        let guarding = EjectGuardReading(installed: true, protects: true, protectsMounted: true, running: true,
                                         volumeUUID: "B293", mountedVolumeUUID: "B293")
        #expect(guarding.words.hasPrefix("Protecting this SidePulse"))
        #expect(!guarding.canProtect)
        #expect(guarding.canRelease, "a protected card refuses Finder's Eject: the card offers the way back")
        #expect(guarding.words.contains("Stop protecting"))
        #expect(!EjectGuardReading(installed: true, protects: true, volumeUUID: "7F02", mountedVolumeUUID: "B293").canRelease)
        #expect(EjectGuardReading(installed: false).words.hasPrefix("Not installed"))
        #expect(!EjectGuardReading(installed: false).canProtect, "nothing mounted, nothing to protect")
        #expect(EjectGuardReading.parse(.object(["protects": .bool(true)])) == nil)
    }

    @Test("an eject guard that is not protecting says why, and only what is true")
    func ejectGuardWhyNot() {
        // Told nothing, but it did run once: not "never run".
        let ranOnce = EjectGuardReading(installed: true, runs: 2, mountedVolumeUUID: "B293")
        #expect(!ranOnce.words.contains("never run"))
        #expect(ranOnce.words.contains("not told which SidePulse"))
        // Told which SidePulse, but launchd has not loaded it: not "never
        // told".
        let unloaded = EjectGuardReading.parse(.object([
            "installed": .bool(true), "protects": .bool(false), "loaded": .bool(false),
            "runs": .number(0), "volume_uuid": .string("B293"), "mounted_volume_uuid": .string("B293"),
        ]))
        #expect(unloaded?.loaded == false)
        #expect(unloaded?.words.contains("not loaded") == true)
        #expect(unloaded?.words.contains("never told") == false)
        // Loaded with a volume but not kept alive.
        let idle = EjectGuardReading(installed: true, volumeUUID: "B293", mountedVolumeUUID: "B293", loaded: true)
        #expect(idle.words.contains("not kept running"))
    }

    @Test("dot_link decodes; a daemon that sends none falls back to the setting")
    func dotLinkDecoding() throws {
        let frame = """
        {"t":"lights","v":1,"surfaces":{"dot":{"program":"off 200ms none","led_count":2}},
         "devices_linked":true,"linked_skew_ms":11.0,"linked_skew_at":1788982891.31,
         "dot_link":{"state":"linked","role":"extend","error":null}}
        """
        let message = try CoreCodec.decode(frame: Data(frame.utf8))
        guard case .lights(let lights) = message else { Issue.record("not lights"); return }
        #expect(lights.dotLink == CoreDotLink(state: "linked", role: "extend"))
        #expect(lights.linkedSkewAt == 1788982891.31)
        // The old-daemon path: link nil, so `devices_linked` and the role
        // on the surface decide — a pending role is still "not picked up".
        let dot = CoreLightSurface(program: "off 200ms none", ledCount: 2)
        let readout = DotRoleReadout.make(chosen: .asks, includeCompletions: false, linked: true, link: nil, dot: dot)
        #expect(readout.settling)
        #expect(readout.detail == "The monitor has not picked this up yet.")
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
        for path in ["linked_follow_brightness", "dot_extend_style", "dot_extend_side",
                     "linked_dot_phase_trim_ms", "linked_dot_clock_correction", "linked_sync_tolerance_ms"] {
            #expect(devices.contains(path), "\(path) resets with the Devices page")
        }
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
