import JRBarTestSupport
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Render proof for the firmware update: the Firmware group on the Devices
/// page in each state it can be in, and the sheet at each stage, in light
/// and dark. Each state is reached through the real store and a fake
/// daemon link, not painted by hand. Off by default; set
/// `JRBAR_RENDER_PROOF=1` and `JRBAR_RENDER_PROOF_DIR=<a scratch folder>`
/// to write the PNGs (default `/tmp/jrbar-audit/firmware`).
@Suite("Firmware render proof", .renderProofAppearance)
@MainActor
struct FirmwareRenderProofTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit/firmware", isDirectory: true)
    }

    // MARK: Fixtures

    private static func statusText(model: String = "pro", version: String, latest: String, available: Bool?,
                                   canUpdate: Bool, mounted: Bool = true, whyNot: String? = nil,
                                   cached: Bool = false) -> String {
        let isPro = model == "pro"
        let id = isPro ? "SPP-000067" : "SPD-000010"
        let name = isPro ? "SidePulse Pro" : "SidePulse Dot"
        let notes = isPro
            ? #"["Better white balance and mixed colours through the diffuser: the firmware now applies calibrated red, green and blue gains.","Dim colours keep more of their detail: brightness and colour balance are applied together.","Animations and startup programs work as before.","More reliable updates, and files survive a restart."]"#
            : #"["Better drive identification when several Dots are plugged in.","Programs up to 512 bytes, and lower power use while the LEDs are off."]"#
        let size = isPro ? 137_875 : 20_480
        let slot = isPro ? #"{"name":"B","has_image":false,"valid":true,"version":"none"}"# : "null"
        let active = isPro ? #""A""# : "null"
        let why = whyNot.map { #"{"code":"device_busy","message":"\#($0)"}"# } ?? "null"
        let availableText = available.map { $0 ? "true" : "false" } ?? "null"
        return """
        {"catalog":[{"model":"\(model)","name":"\(name)","version":"\(latest)","notes":\(notes),
          "package":{"host":"raw.githubusercontent.com","name":"x.zip","bytes":\(size),"cached":\(cached)},
          "drive":"\(isPro ? "SidePulse" : "PulseDot")","image_bytes":\(size - 800)}],
         "devices":[{"id":"\(id)","name":"\(name)","root":"/Volumes/X","mounted":\(mounted),"model":"\(model)",
          "serial":"\(id)","version":"\(version)","active_slot":\(active),"build":null,"uptime_ms":1000,
          "latest":"\(latest)","update_available":\(availableText),"can_update":\(canUpdate),"why_not":\(why),
          "other_slot":\(slot),"colour_note":false}],
         "job":null,"download_host":"raw.githubusercontent.com"}
        """
    }

    private struct Rig {
        let firmware: FirmwareStore
        let link: FakeFirmwareLink
        let entry: SettingsStore.DeviceEntry
        let settings: SettingsStore
    }

    private static func rig(model: String = "pro", status: String) async -> Rig {
        let link = FakeFirmwareLink()
        link.statusText = status
        let firmware = FirmwareStore { name, args in try await link.send(name, args) }
        let isPro = model == "pro"
        let entry = SettingsStore.DeviceEntry(index: 0, id: isPro ? "SPP-000067" : "SPD-000010",
                                              name: isPro ? "SidePulse Pro" : "SidePulse Dot", kind: model)
        await firmware.refresh()
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-fw-proof.sock")
        core.handle(.connected)
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array([.object(["id": .string(entry.id), "name": .string(entry.name)])]),
                "devices_linked": .bool(true), "dot_role": .string("asks"),
            ]))))
        core.apply(.state(CoreState(devices: [CoreDevice(id: entry.id, kind: model,
            connected: firmware.status?.devices.first?.mounted == true)])))
        let settings = SettingsStore(core: core)
        return Rig(firmware: firmware, link: link, entry: entry, settings: settings)
    }

    private static func job(model: String = "pro", phase: String, outcome: String? = nil,
                            _ over: [String: JSONValue] = [:]) -> JSONValue {
        var overrides = over
        if model == "dot" {
            overrides["device"] = "SPD-000010"
            overrides["model"] = "dot"
            overrides["name"] = "SidePulse Dot"
            overrides["serial"] = "SPD-000010"
            overrides["from_version"] = overrides["from_version"] ?? "1.1.2"
            overrides["to_version"] = overrides["to_version"] ?? "1.1.14"
        }
        return FakeFirmwareLink.jobValue(phase: phase, outcome: outcome, updatedAt: 150, overrides: overrides)
    }

    /// Starts an update through the sheet, then lets the daemon report `value`.
    /// `afterStatus` is what the device reports once the daemon reads it back.
    private static func advance(_ rig: Rig, to value: JSONValue, afterStatus: String? = nil) async {
        let device = rig.entry.id
        rig.firmware.openSheet(deviceID: device, settingsID: rig.entry.id)
        await rig.firmware.startUpdate(deviceID: device)
        if let afterStatus { rig.link.statusText = afterStatus }
        rig.link.job = value
        await rig.firmware.observe(stateJob: FirmwareJob(value))
    }

    // MARK: Cards

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the firmware PNGs"))
    func cards() async throws {
        let upToDate = await Self.rig(status: Self.statusText(version: "1.1.0", latest: "1.1.0", available: false, canUpdate: false))
        let upToDateDot = await Self.rig(model: "dot", status: Self.statusText(
            model: "dot", version: "1.1.14", latest: "1.1.14", available: false, canUpdate: false))
        let available = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        available.settings.setFold("firmware:notes:SPP-000067", open: true)
        let availableDot = await Self.rig(model: "dot", status: Self.statusText(
            model: "dot", version: "1.1.2", latest: "1.1.14", available: true, canUpdate: true, cached: true))
        let busy = await Self.rig(status: Self.statusText(
            version: "1.0.2", latest: "1.1.0", available: true, canUpdate: false,
            whyNot: "The device looks busy: it is playing a program. Wait a minute and try again."))
        let offline = await Self.rig(status: Self.statusText(
            version: "1.0.2", latest: "1.1.0", available: nil, canUpdate: false, mounted: false))
        let running = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(running, to: Self.job(phase: "downloading", ["phase_label": "Downloading the update",
            "download": ["bytes": 98_304, "total": 137_875]]))
        let shots: [(String, Rig)] = [("card-up-to-date", upToDate), ("card-up-to-date-dot", upToDateDot), ("card-update-available", available),
                                      ("card-update-available-dot", availableDot), ("card-device-busy", busy),
                                      ("card-offline", offline), ("card-running", running)]
        for (name, rig) in shots {
            for dark in [false, true] {
                let view = Form {
                    DeviceCard(store: rig.settings, device: rig.entry, firmware: rig.firmware)
                }
                .formStyle(.grouped)
                .disclosureGroupStyle(SettingsDisclosureStyle())
                .environment(rig.settings)
                try Self.write(view, name: name, dark: dark, width: 620,
                               fixedHeight: name == "card-update-available" ? 600 : 420)
            }
        }
    }

    // MARK: Sheets

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the firmware PNGs"))
    func sheets() async throws {
        var shots: [(String, Rig)] = []

        let uncached = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        uncached.firmware.openSheet(deviceID: "SPP-000067", settingsID: "SPP-000067")
        shots.append(("sheet-confirm-uncached-pro", uncached))

        let cached = await Self.rig(model: "dot", status: Self.statusText(
            model: "dot", version: "1.1.2", latest: "1.1.14", available: true, canUpdate: true, cached: true))
        cached.firmware.openSheet(deviceID: "SPD-000010", settingsID: "SPD-000010")
        shots.append(("sheet-confirm-cached-dot", cached))

        let refused = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        refused.link.updateReply = CoreReply(id: "2", ok: false, error: CoreReplyError(
            code: "refused", message: "This Mac is on battery at 22%. Plug in the charger first: a Mac that shuts down in the middle of an update could leave the device needing a recovery."))
        refused.firmware.openSheet(deviceID: "SPP-000067", settingsID: "SPP-000067")
        await refused.firmware.startUpdate(deviceID: "SPP-000067")
        shots.append(("sheet-confirm-refused", refused))

        let starting = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        starting.link.holdUpdate = true
        starting.firmware.openSheet(deviceID: "SPP-000067", settingsID: "SPP-000067")
        let pending = Task { await starting.firmware.startUpdate(deviceID: "SPP-000067") }
        var turns = 0
        while !starting.firmware.isStarting, turns < 1000 {
            await Task.yield()
            turns += 1
        }
        #expect(starting.firmware.isStarting)
        shots.append(("sheet-starting", starting))

        let downloading = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(downloading, to: Self.job(phase: "downloading", ["phase_label": "Downloading the update",
            "download": ["bytes": 98_304, "total": 137_875]]))
        shots.append(("sheet-running-downloading", downloading))

        let restarting = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(restarting, to: Self.job(phase: "restarting", ["phase_label": "Waiting for the device to restart",
            "source": "cache"]))
        shots.append(("sheet-running-restarting", restarting))

        let proDone = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(proDone, to: Self.job(phase: "done", outcome: "updated", [
            "message": "The SidePulse Pro now runs firmware 1.1.0.", "finished_at": 172.0, "new_slot": "B",
            "previous_firmware": ["version": "1.0.2", "slot": "A", "valid": true, "firmware": "1.0.2"],
            "colour_check": true, "removed_sidecars": ["._FIRMWARE.BIN"], "restarted": true,
        ]), afterStatus: Self.statusText(version: "1.1.0", latest: "1.1.0", available: false, canUpdate: false))
        shots.append(("sheet-success-pro", proDone))

        let dotDone = await Self.rig(model: "dot", status: Self.statusText(
            model: "dot", version: "1.1.2", latest: "1.1.14", available: true, canUpdate: true, cached: true))
        await Self.advance(dotDone, to: Self.job(model: "dot", phase: "done", outcome: "updated", [
            "message": "The SidePulse Dot now runs firmware 1.1.14.", "finished_at": 160.0, "source": "cache",
        ]), afterStatus: Self.statusText(model: "dot", version: "1.1.14", latest: "1.1.14", available: false, canUpdate: false))
        shots.append(("sheet-success-dot", dotDone))

        let failed = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(failed, to: Self.job(phase: "done", outcome: "failed", [
            "code": "bad_hash", "finished_at": 112.0,
            "message": "The download did not match the fingerprint JR-Bar expects, so it was thrown away.",
            "what_to_do": "Try again later. If it keeps happening, tell the maker of the device.",
        ]))
        shots.append(("sheet-failed", failed))

        let unconfirmed = await Self.rig(status: Self.statusText(version: "1.0.2", latest: "1.1.0", available: true, canUpdate: true))
        await Self.advance(unconfirmed, to: Self.job(phase: "done", outcome: "unconfirmed", [
            "code": "no_return", "finished_at": 232.0, "restarted": false,
            "message": "The device's drive did not come back within two minutes.",
            "what_to_do": "Check the device and reconnect it, then press Check firmware to see which firmware it reports.",
        ]))
        shots.append(("sheet-unconfirmed", unconfirmed))

        for (shot, rig) in shots {
            for dark in [false, true] {
                let device = rig.entry.name
                let view = FirmwareSheetContent(firmware: rig.firmware, fallbackName: device, isLive: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                try Self.write(view, name: shot, dark: dark, width: 540, fixedHeight: nil)
            }
        }
        starting.link.release()
        await pending.value
    }

    // MARK: Rendering

    private static func write<V: View>(_ view: V, name: String, dark: Bool, width: CGFloat,
                                       fixedHeight: CGFloat?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let sized = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width)
        var height = fixedHeight ?? 10
        let probe = NSHostingView(rootView: sized.fixedSize(horizontal: false, vertical: true))
        probe.appearance = appearance
        if fixedHeight == nil {
            height = ceil(probe.fittingSize.height)
        }
        let size = CGSize(width: width, height: max(height, 40))
        let hosting = NSHostingView(rootView: sized.frame(height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
