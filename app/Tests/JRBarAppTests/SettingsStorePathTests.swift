import Foundation
import Observation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The settings document observed path by path: an edit or a push wakes
/// the rows that read what changed, and nothing else — and the overlay's
/// rules (pending, echo, a clamped reply, the consent-gated write) still
/// hold on top of it.
@MainActor
@Suite("Settings store paths")
struct SettingsStorePathTests {
    /// Counts one observation's fires; the onChange closure is Sendable.
    final class Fired: @unchecked Sendable {
        var count = 0
    }

    static func document(brightness: Double = 0.8, dim: Bool = true, gap: JSONValue = .null) -> JSONValue {
        .object([
            "global_brightness_scale": .number(brightness),
            "idle_dim_enabled": .bool(dim),
            "screen_bar_gap_width": gap,
            "colors": .object([
                "blend_mode": .string("color_blend"),
                "agent_colors": .object(["claude": .string("#D97757")]),
            ]),
            "devices": .array([
                .object(["id": .string("sidepulse:pro:A1"), "name": .string("Desk strip"), "brightness": .number(200)]),
            ]),
        ])
    }

    static func store(_ document: JSONValue = document(), generation: Int = 1) -> (CoreModel, SettingsStore) {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-path-tests.sock")
        core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema, document: document)))
        return (core, SettingsStore(core: core))
    }

    /// Runs `read` under observation and returns the counter its change bumps.
    static func watch(_ read: () -> Void) -> Fired {
        let fired = Fired()
        withObservationTracking(read) { fired.count += 1 }
        return fired
    }

    @Test("an edit on one path wakes that path's readers and no other path's")
    func editWakesOnlyItsPath() {
        let (core, store) = Self.store()
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        let dim = Self.watch { _ = store.values.bool("idle_dim_enabled") }
        let provided = Self.watch { _ = store.isProvided("idle_dim_enabled") }
        let present = Self.watch { _ = store.hasDocument }
        let devices = Self.watch { _ = store.deviceEntries }
        store.set("global_brightness_scale", .number(0.5), throttled: true)
        #expect(brightness.count == 1)
        #expect(dim.count == 0, "an edit to brightness must not re-render the dim row")
        #expect(provided.count == 0)
        #expect(present.count == 0)
        #expect(devices.count == 0, "the device list does not move with a global slider")
        #expect(store.values.double("global_brightness_scale") == 0.5)
        withExtendedLifetime(core) {}
    }

    @Test("a device edit wakes the path it wrote and the paths above it, not the device list")
    func deviceEditWakesItsBranch() {
        let (core, store) = Self.store()
        let own = Self.watch { _ = store.values.double("devices.0.brightness") }
        let whole = Self.watch { _ = store.values.array("devices") }
        let list = Self.watch { _ = store.deviceEntries }
        let other = Self.watch { _ = store.values.string("colors.blend_mode") }
        store.set("devices.0.brightness", .number(120), throttled: true)
        #expect(own.count == 1)
        #expect(whole.count == 1, "a reader of the whole array sees the change inside it")
        #expect(list.count == 0, "ids, names and kinds did not change")
        #expect(other.count == 0)
        withExtendedLifetime(core) {}
    }

    @Test("a settings push that changes one path updates one cell")
    func pushUpdatesOneCell() {
        let (core, store) = Self.store()
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        let dim = Self.watch { _ = store.values.bool("idle_dim_enabled") }
        let colour = Self.watch { _ = store.values.agentColorHex("claude") }
        core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.document(dim: false))))
        // A read right after the push is already current, before the sync.
        #expect(store.values.bool("idle_dim_enabled") == false)
        store.syncMirrors()
        #expect(dim.count == 1)
        #expect(brightness.count == 0)
        #expect(colour.count == 0)
        withExtendedLifetime(core) {}
    }

    @Test("an unchanged document pushed again wakes no row, only the generation")
    func echoOfSameDocumentIsQuiet() {
        let (core, store) = Self.store()
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        let whole = Self.watch { _ = store.document }
        let generation = Self.watch { _ = store.generation }
        core.apply(.settings(CoreSettings(generation: 9, schema: CoreProtocol.knownSettingsSchema, document: Self.document())))
        store.syncMirrors()
        #expect(brightness.count == 0)
        #expect(whole.count == 0, "readers of the whole document wake only when it changed")
        #expect(generation.count == 1)
        #expect(store.generation == 9)
        withExtendedLifetime(core) {}
    }

    @Test("the settings revision moves with the monitor's document, not its generation or a local edit")
    func revisionFollowsContent() {
        let (core, store) = Self.store()
        let revision = store.settingsRevision
        core.apply(.settings(CoreSettings(generation: 5, schema: CoreProtocol.knownSettingsSchema, document: Self.document())))
        store.set("global_brightness_scale", .number(0.2), throttled: true)
        store.syncMirrors()
        #expect(store.settingsRevision == revision)
        let watched = Self.watch { _ = store.settingsRevision }
        core.apply(.settings(CoreSettings(generation: 6, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.document(dim: false))))
        store.syncMirrors()
        #expect(store.settingsRevision == revision + 1)
        #expect(watched.count == 1)
        withExtendedLifetime(core) {}
    }

    @Test("with the window closed a push leaves the facts alone until something reads them")
    func closedWindowSkipsFacts() {
        let (core, store) = Self.store()
        let live = Self.watch { _ = store.isLive }
        store.settingsWindowDidClose()
        core.handle(.connected)
        core.apply(.state(CoreState()))
        store.syncMirrors()
        #expect(live.count == 0, "no mirror is written for a closed window")
        #expect(store.isLive, "a read is current all the same")
        let again = Self.watch { _ = store.isLive }
        store.syncMirrors()
        #expect(again.count == 1, "once read, the facts follow the pushes again")
        withExtendedLifetime(core) {}
    }

    @Test("a read in the moment after a push does not observe the core through the store")
    func staleReadStaysNarrow() {
        let (core, store) = Self.store()
        // A push lands; before the store's sync, a row reads its path and
        // a couple of facts, as a body evaluated in that moment would.
        core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.document(brightness: 0.6))))
        let fired = Self.watch {
            _ = store.values.double("global_brightness_scale")
            _ = store.isLive
            _ = store.hookStatus("claude")
        }
        #expect(store.values.double("global_brightness_scale") == 0.6, "the read was current")
        // Pushes that change nothing the row reads must not wake it.
        core.apply(.settings(CoreSettings(generation: 3, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.document(brightness: 0.6, dim: false))))
        core.handle(.connected)
        #expect(fired.count == 0, "the row observes its cell, not core.settings or the connection")
        withExtendedLifetime(core) {}
    }

    @Test("provided follows the monitor's document, never the overlay")
    func providedIgnoresOverlay() {
        let (core, store) = Self.store()
        #expect(store.isProvided("global_brightness_scale"))
        #expect(store.isProvided("screen_bar_gap_width"), "JSON null counts as provided")
        #expect(!store.isProvided("rainstick_idle_enabled"))
        store.set("rainstick_idle_enabled", .bool(true), throttled: true)
        #expect(!store.isProvided("rainstick_idle_enabled"))
        #expect(store.values.bool("rainstick_idle_enabled") == true, "the overlay still shows the edit")
        withExtendedLifetime(core) {}
    }

    @Test("pending shows the edit until the echo carries it, then drops without a change")
    func pendingThenEcho() {
        let (core, store) = Self.store()
        store.set("global_brightness_scale", .number(0.4), throttled: true)
        #expect(store.document.double("global_brightness_scale") == 0.4)
        core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.document(brightness: 0.4))))
        store.syncMirrors()
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        store.settlePending("global_brightness_scale", value: .number(0.4), echoed: .number(0.4))
        #expect(brightness.count == 0, "dropping an overlay the document already carries changes nothing")
        #expect(store.values.double("global_brightness_scale") == 0.4)
        withExtendedLifetime(core) {}
    }

    @Test("a clamped reply drops the overlay at once and says what the monitor kept")
    func clampedReplyDrops() {
        let (core, store) = Self.store()
        store.set("global_brightness_scale", .number(1.4), throttled: true)
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        store.settlePending("global_brightness_scale", value: .number(1.4), echoed: .number(1.0))
        #expect(brightness.count == 1)
        #expect(store.values.double("global_brightness_scale") == 0.8, "back to the document until its push lands")
        #expect(store.lastError?.contains("kept 1") == true)
        withExtendedLifetime(core) {}
    }

    @Test("the consent-gated plan-limits switch shows on at once, on its own path")
    func planLimitsOverlay() {
        let (core, store) = Self.store()
        let limits = Self.watch { _ = store.values.bool("claude_plan_limits_enabled") }
        let brightness = Self.watch { _ = store.values.double("global_brightness_scale") }
        store.setClaudePlanLimits(true)
        #expect(store.values.bool("claude_plan_limits_enabled") == true)
        #expect(limits.count == 1)
        #expect(brightness.count == 0)
        withExtendedLifetime(core) {}
    }

    @Test("a binding reads its own cell")
    func bindingReadsItsCell() {
        let (core, store) = Self.store()
        let dimBinding = store.bool("idle_dim_enabled")
        let dim = Self.watch { _ = dimBinding.wrappedValue }
        store.set("global_brightness_scale", .number(0.3), throttled: true)
        #expect(dim.count == 0)
        dimBinding.wrappedValue = false
        #expect(dim.count == 1)
        #expect(store.values.bool("idle_dim_enabled") == false)
        withExtendedLifetime(core) {}
    }

    @Test("state pushes that move only a write time wake no device row")
    func stateFactsIgnoreWriteTimes() throws {
        let (core, store) = Self.store()
        core.handle(.connected)
        func state(_ generation: Int, lastWrite: Double, connected: Bool = true) throws -> CoreMessage {
            let doc: [String: Any] = [
                "t": "state", "v": 1, "generation": generation, "now": 1_790_000_000.0 + Double(generation),
                "devices": [["id": "sidepulse:pro:A1", "kind": "pro", "connected": connected, "last_write": lastWrite]],
            ]
            let data = try JSONSerialization.data(withJSONObject: doc)
            return try CoreCodec.decode(line: String(decoding: data, as: UTF8.self))
        }
        core.apply(try state(1, lastWrite: 1_790_000_000))
        store.syncMirrors()
        let facts = Self.watch { _ = store.deviceFacts("sidepulse:pro:A1") }
        let live = Self.watch { _ = store.isLive }
        core.apply(try state(2, lastWrite: 1_790_000_005))
        store.syncMirrors()
        #expect(facts.count == 0)
        #expect(live.count == 0)
        #expect(store.deviceLastWrite("sidepulse:pro:A1") == 1_790_000_005, "the Right now line still reads the newest write")
        core.apply(try state(3, lastWrite: 1_790_000_006, connected: false))
        #expect(store.deviceFacts("sidepulse:pro:A1")?.isPresent == false, "a read right after the push is current")
        store.syncMirrors()
        #expect(facts.count == 1)
        withExtendedLifetime(core) {}
    }

    /// Direct reads of the whole document in the files Settings pages are
    /// drawn from. Each one re-renders its view on every edit and every
    /// `settings` push; a row reads its own path instead. The counts may
    /// only go down.
    static let wholeDocumentReads: [String: Int] = [
        "SettingsPagesA.swift": 0, "SettingsPagesB.swift": 0, "SettingsPagesShell.swift": 0,
        "SettingsView.swift": 0, "SettingsAtoms.swift": 0, "LEDDirectionRow.swift": 0,
        "DotTravelStyleRow.swift": 0, "DotRoleControls.swift": 0,
        "CalibrationProfilesSection.swift": 8, "LinkedSyncControls.swift": 5,
        "ScreenBarHiddenAppsRow.swift": 1, "LightingMotionRows.swift": 2,
        "UsageHooksSection.swift": 1, "ClaudeStatusLineSection.swift": 1, "CalibrationSheet.swift": 3,
    ]

    @Test("page bodies read the whole document no more often than they did")
    func wholeDocumentReadsOnlyGoDown() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        for (file, allowed) in Self.wholeDocumentReads {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            let count = text.components(separatedBy: "store.document").count - 1
            #expect(count <= allowed, "\(file) reads store.document \(count) times; read the path instead")
        }
    }

    @Test("heavy runs start folded, and a search hit unfolds the one holding its row")
    func revealUnfoldsItsFold() {
        let (core, store) = Self.store()
        #expect(store.openFolds.isEmpty)
        store.reveal(SettingsSearchEntry(.devices, "Screen Bar", "Notch wings"))
        #expect(store.isFoldOpen(SettingsFold.screenBar))
        store.reveal(SettingsSearchEntry(.devices, "Devices", "Brightness"))
        #expect(store.isFoldOpen(SettingsFold.device("sidepulse:pro:A1")), "a device row unfolds the device cards")
        store.reveal(SettingsSearchEntry(.devices, "Creator Micro 2", "Session keys"))
        #expect(store.isFoldOpen(SettingsFold.creatorMicro))
        store.reveal(SettingsSearchEntry(.devices, "Stream Deck", "Status URL"))
        #expect(store.isFoldOpen(SettingsFold.streamDeck))
        let colours = SettingsSearch.search("provider colours", in: SettingsSearch.rows).first
        #expect(colours?.page == .lighting)
        if let colours { store.reveal(colours) }
        #expect(store.isFoldOpen(SettingsFold.providerColours))
        let action = SettingsSearch.shortcutRows.first { $0.group == "Actions" }
        if let action { store.reveal(action) }
        #expect(store.isFoldOpen(SettingsFold.shortcutActions))
        let chip = SettingsSearch.shortcutRows.first { $0.group == "Quick toggles" }
        if let chip { store.reveal(chip) }
        #expect(store.isFoldOpen(SettingsFold.quickToggles))
        let open = store.openFolds
        store.reveal(SettingsSearchEntry(.notifications, "Power", "Lid closed"))
        #expect(store.openFolds == open, "a row outside every fold opens none")
        store.setFold(SettingsFold.screenBar, open: false)
        #expect(!store.isFoldOpen(SettingsFold.screenBar), "folding by hand is the person's")
        withExtendedLifetime(core) {}
    }

    @Test("every listed row on a folded run names a fold to open")
    func everyFoldedGroupMapsToAFold() {
        let (core, store) = Self.store()
        let folded: Set<String> = ["Devices", "Screen Bar", "Creator Micro 2", "Stream Deck"]
        for row in SettingsSearch.rows where row.page == .devices && folded.contains(row.group) {
            #expect(!store.folds(holding: row).isEmpty, "\(row.title) sits in a fold the search cannot open")
        }
        withExtendedLifetime(core) {}
    }
}
