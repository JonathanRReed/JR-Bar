import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings export and import: what travels and what stays, the file
/// round-trips, a stranger's file is refused by name, and an import
/// writes only what this monitor knows and what actually changes.
@Suite struct SettingsTransferTests {
    private let document: JSONValue = .object([
        "global_brightness_scale": .number(0.6),
        "claude_plan_limits_enabled": .bool(true),
        "claude_plan_limits_consent_version": .number(2),
        "cloud_ingest_token_path": .string("/Users/j/.local/state/jrbar/cloud-ingest.token"),
        "devices": .array([.object(["id": .string("pro-1"), "brightness": .number(0.4)])]),
    ])

    private func sample() -> SettingsBundle {
        var utilities = UtilitiesState()
        utilities.dataHoarderEnabled = true
        return SettingsBundle.make(
            document: document, schema: 3, utilities: utilities, toys: ToysState(),
            defaults: [
                "panelHotkeyEnabled": NSNumber(value: true),
                "hotkeyChord.panel": "38:2304",
                "sound.volume": NSNumber(value: 0.5),
                "systemToggleStrip": ["awake", "dark"],
                "effectStudioSelection": "calm",
                "NSStatusItem Preferred Position jrbar": NSNumber(value: 120),
                "jrbar.askReplyDrafts.v1": "draft",
            ],
            appVersion: "0.9.9 (build 1801, 1800c0a)", now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func whatTravelsAndWhatStays() {
        let bundle = sample()
        #expect(Set(bundle.monitor.keys) == ["global_brightness_scale", "claude_plan_limits_enabled",
                                             "claude_plan_limits_consent_version"])
        #expect(bundle.devices?.arrayValue?.count == 1)
        #expect(bundle.preferences["panelHotkeyEnabled"] == .bool(true), "a bool stays a bool")
        #expect(bundle.preferences["sound.volume"] == .number(0.5))
        #expect(bundle.preferences["hotkeyChord.panel"] == .string("38:2304"))
        #expect(bundle.preferences["systemToggleStrip"] == .array([.string("awake"), .string("dark")]))
        #expect(bundle.preferences["effectStudioSelection"] == nil)
        #expect(bundle.preferences["NSStatusItem Preferred Position jrbar"] == nil)
        #expect(bundle.preferences["jrbar.askReplyDrafts.v1"] == nil)
        #expect(bundle.categories == [.monitor, .devices, .utilities, .toys, .preferences])
        #expect(bundle.summary(of: .monitor) == "3 settings")
        #expect(bundle.summary(of: .devices) == "1 device")
        #expect(!SettingsBundle.Category.devices.onByDefault)
        #expect(SettingsBundle.Category.monitor.onByDefault)
    }

    @Test func theFileRoundTrips() throws {
        let bundle = sample()
        let data = try bundle.encoded()
        let read = try SettingsBundle.read(data)
        #expect(read == bundle)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "jrbar-settings""#))
        #expect(!text.contains("cloud-ingest.token"), "a daemon fact never travels")
    }

    @Test func aStrangersFileIsRefusedByName() {
        #expect(throws: SettingsBundle.ReadError.notJSON) { try SettingsBundle.read(Data("nope".utf8)) }
        #expect(throws: SettingsBundle.ReadError.notABundle) {
            try SettingsBundle.read(Data(#"{"global_brightness_scale": 1}"#.utf8))
        }
        #expect(throws: SettingsBundle.ReadError.newerVersion(9)) {
            try SettingsBundle.read(Data(#"{"format": "jrbar-settings", "version": 9}"#.utf8))
        }
    }

    @Test func aReadFileDropsWhatNeverTravels() throws {
        let json = #"""
        {"format": "jrbar-settings", "version": 1,
         "monitor": {"cloud_ingest_token_path": "/x", "devices": [], "dim_when_idle": true},
         "preferences": {"sound.volume": 0.3, "jrbar.lead": 4}}
        """#
        let read = try SettingsBundle.read(Data(json.utf8))
        #expect(read.monitor == ["dim_when_idle": .bool(true)])
        #expect(read.preferences == ["sound.volume": .number(0.3)])
    }

    @Test func anImportWritesOnlyKnownChangedKeysConsentFirst() {
        var bundle = sample()
        bundle.monitor["from_a_newer_monitor"] = .bool(true)
        let current: JSONValue = .object([
            "global_brightness_scale": .number(0.6),
            "claude_plan_limits_enabled": .bool(false),
            "claude_plan_limits_consent_version": .number(0),
        ])
        let plan = bundle.monitorWrites(against: current)
        #expect(plan.writes.map(\.key) == ["claude_plan_limits_consent_version", "claude_plan_limits_enabled"])
        #expect(plan.unknown == ["from_a_newer_monitor"])
    }

    @Test func aPagesStateReadsBackTolerantly() {
        let bundle = sample()
        #expect(SettingsBundle.decode(UtilitiesState.self, from: bundle.utilities)?.dataHoarderEnabled == true)
        #expect(SettingsBundle.decode(ToysState.self, from: .object([:])) == ToysState())
        #expect(SettingsBundle.decode(ToysState.self, from: .string("garbage")) == nil)
        #expect(SettingsBundle.decode(ToysState.self, from: nil) == nil)
    }

    @Test func defaultsValuesComeBackAsDefaultsTypes() {
        #expect(SettingsBundle.defaultsValue(.bool(true)) as? Bool == true)
        #expect(SettingsBundle.defaultsValue(.array([.string("a")])) as? [String] == ["a"])
        #expect(SettingsBundle.defaultsValue(.array([.number(1)])) == nil)
        #expect(SettingsBundle.defaultsValue(.object([:])) == nil)
    }

    @MainActor @Test func theSpelledOutKeysAreTheOwnersKeys() {
        #expect(SettingsBundle.preferenceKeys.contains(PanelHotkey.defaultsKey))
        #expect(SettingsBundle.preferenceKeys.contains(SettingsStore.shelfHotkeyDefaultsKey))
        #expect(SettingsBundle.travels(HotkeyChordDefaults.key(for: "panel")))
        #expect(SettingsBundle.travels(SoundPreferences.volumeKey))
        #expect(SettingsBundle.travels(SoundPreferences.choiceKey(.completion)))
    }
}
