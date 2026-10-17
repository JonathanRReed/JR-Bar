import AppKit
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Keep Awake saved hold cleanup", .serialized)
struct KeepAwakePersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func power(state: String = "off", failure: String = "clear_failed") throws -> CorePower {
        var hold: [String: Any] = ["state": state, "active": state != "off", "persistence_error": failure]
        if state == "manual" { hold["lease"] = ["kind": "indefinite"] }
        if state == "agents" { hold["agents"] = 2 }
        let data = try JSONSerialization.data(withJSONObject: ["hold": hold])
        return try JSONDecoder().decode(CorePower.self, from: data)
    }

    @Test("cleanup stays available after the manual hold has stopped")
    func cleanupMenuIsReachable() throws {
        let reading = KeepAwakeReading(power: try power())
        let items = KeepAwakeMenu.items(durations: [3600], reading: reading, displayOn: false,
                                        monitorLive: true, now: now)
        let cleanup = try #require(items.first { $0.choice == .turnOff })
        #expect(cleanup.enabled)
        #expect(cleanup.title == "Retry saved hold cleanup")
        #expect(!reading.leaseInForce)
        let offline = KeepAwakeMenu.items(durations: [3600], reading: reading, displayOn: false,
                                          monitorLive: false, now: now)
        #expect(offline.first { $0.choice == .turnOff }?.enabled == false)
    }

    @Test("cleanup uses the existing release action without a local assertion", arguments: ["menu", "off"])
    func cleanupRoutesToRelease(route: String) async throws {
        let suite = ScratchDefaults.suiteName("KeepAwakePersistenceTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        var requests: [CoreAwakeRequest?] = []
        state.sendLease = { request in requests.append(request); return .taken }
        state.takeAssertion = { _ in Issue.record("cleanup must not start a power assertion"); return nil }
        state.noteDaemonHold(try power().hold, live: true)
        let store = SystemTogglesStore(state: state)
        if route == "menu" { KeepAwakeMenu.perform(.turnOff, on: store, now: now) }
        else { store.set(.keepAwake, on: false) }
        for _ in 0..<10_000 {
            if !requests.isEmpty && !store.applying.contains(.keepAwake) { break }
            await Task.yield()
        }
        try #require(requests.count == 1)
        #expect(requests[0] == nil)
        #expect(!store.applying.contains(.keepAwake))
        #expect(!store.isOn[.keepAwake, default: false])
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func savedHoldWarningsRender() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        for (state, failure) in [("off", "clear_failed"), ("manual", "save_failed"), ("agents", "clear_failed")] {
            let value = try power(state: state, failure: failure)
            let reading = KeepAwakeReading(power: value)
            for dark in [false, true] {
                application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Devices").font(.headline)
                        Spacer()
                        KeepAwakeFooter(power: value)
                    }
                    Text(reading.chipHelp(now: now)).font(.callout)
                    HStack {
                        ForEach(KeepAwakeMenu.items(durations: [], reading: reading, displayOn: false,
                                                   monitorLive: true, now: now).filter { $0.choice == .turnOff }) { item in
                            Button(item.title) {}.disabled(!item.enabled)
                        }
                        Spacer()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                let bitmap = try SettingsRenderProofTests.snapshot(view, size: CGSize(width: 520, height: 280), dark: dark)
                let directory = SettingsRenderProofTests.directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("keepawake-persistence-\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
