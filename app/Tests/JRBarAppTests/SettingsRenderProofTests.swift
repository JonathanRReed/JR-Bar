import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the Settings window: every page, and the Utilities
/// and Toys pages with each card open, in light and dark, so a human can
/// eyeball the grouped forms, the card shells and the atoms they are
/// built from. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `settings-*.png` into `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/jrbar-settings-proof`). The document is the mock monitor's
/// defaults (`app/scripts/mock-core.py`), or the JSON file named by
/// `JRBAR_RENDER_PROOF_SETTINGS`.
@Suite("Settings render proof")
@MainActor
struct SettingsRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The detail pane's width at the window's older default size;
    /// `JRBAR_RENDER_PROOF_WIDTH=430` draws the narrowest the window allows.
    static let paneWidth: CGFloat = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_WIDTH"]
        .flatMap(Double.init).map { CGFloat($0) } ?? 560

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-settings-proof", isDirectory: true)
    }

    /// The mock monitor's settings document, read through its own script
    /// so the proof never drifts from what `mock-core.py` serves.
    private static func document() throws -> JSONValue {
        let env = ProcessInfo.processInfo.environment
        let data: Data
        if let path = env["JRBAR_RENDER_PROOF_SETTINGS"] {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "scripts/mock-core.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", """
                import importlib.util, json, sys
                spec = importlib.util.spec_from_file_location("mock_core", sys.argv[1])
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                print(json.dumps(module.default_settings_document()))
                """, script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A Settings store over the mock document, with its toys and
    /// utilities built the way the delegate builds them but never started.
    private struct Fixture {
        let core: CoreModel
        let settings: SettingsStore
        let toys: ToysStore
        let utilities: UtilitiesStore
    }

    private static func fixture() throws -> Fixture {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-render-proof.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try document())))
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        // A few agents with rules, so the Agent Overview card's table
        // has rows to draw: one loud, one quiet, one following.
        var state = UtilitiesState()
        state.agents.alertRules = [
            "claude": .followGlobal,
            "codex": AgentAlertRule(completions: true, escalationCeiling: 3),
            "grok": AgentAlertRule(asks: true, completions: false, sounds: false, escalationCeiling: 1),
        ]
        let utilities = UtilitiesStore(core: core, settings: settings, state: state)
        settings.utilities = utilities
        return Fixture(core: core, settings: settings, toys: toys, utilities: utilities)
    }

    /// Every card id on the Utilities and Toys pages.
    private static func cardIDs(_ fixture: Fixture) -> [String] {
        var ids = [fixture.utilities.menuBar.id, fixture.utilities.dock.id,
                   fixture.utilities.agents.id, fixture.utilities.dataHoarder.id]
        if let notch = fixture.toys.notch { ids.append(notch.id) }
        ids += fixture.toys.toys.map(\.id)
        return ids
    }

    // MARK: Rendering

    /// Draws `view` in an offscreen window at `size` under the given
    /// appearance and returns its layer tree as a bitmap — AppKit-backed
    /// controls included, which `ImageRenderer` cannot draw.
    private static func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
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
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        window.contentView = nil
        window.close()
        return rep
    }

    /// Crops a snapshot's empty tail: rows at the bottom that match the
    /// last row's colour everywhere.
    private static func cropped(_ rep: NSBitmapImageRep, margin: Int = 24) -> CGImage? {
        guard let image = rep.cgImage else { return nil }
        let width = image.width, height = image.height
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return image }
        let row = image.bytesPerRow, pixel = image.bitsPerPixel / 8
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * row + x * pixel
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
        let background = color(width / 2, height - 1)
        var last = height - 1
        scan: while last > 0 {
            for x in stride(from: 0, to: width, by: 3) {
                let c = color(x, last)
                if abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2) > 12 { break scan }
            }
            last -= 1
        }
        let keep = min(height, last + margin * 2)
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: keep))
    }

    /// `JRBAR_RENDER_PROOF_ONLY=notch` keeps a run to the shots whose
    /// name holds that word.
    private static func wanted(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_ONLY"] else { return true }
        return name.contains(only)
    }

    private static func write(_ rep: NSBitmapImageRep, named name: String) throws {
        let image = try #require(cropped(rep))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Proofs

    /// Every page, cards closed, in both appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Settings PNGs"))
    func pages() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for page in SettingsStore.Page.allCases {
            for dark in [false, true] where Self.wanted("settings-\(page.rawValue)") {
                fixture.settings.page = page
                let view = SettingsPageContainer(store: fixture.settings, page: page)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
                try Self.write(rep, named: "settings-\(page.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }

    /// Each Utilities and Toys card open on its own page, in both
    /// appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the card PNGs"))
    func cards() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for card in Self.cardIDs(fixture) {
            fixture.settings.expandedCards = [card]
            let page: SettingsStore.Page = fixture.toys.toys.contains { $0.id == card } ? .toys : .utilities
            for dark in [false, true] where Self.wanted("card-\(card)") {
                let view = SettingsPageContainer(store: fixture.settings, page: page)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
                try Self.write(rep, named: "card-\(card)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }

    /// The atoms on one sheet: a grouped page's rows and an open
    /// disclosure, then a card body's run header, subrows, chips, notes
    /// and every status pill.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the atoms PNGs"))
    func atoms() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let statuses: [ToyStatus] = [.paused("Parked"), .needsPermission("Needs Accessibility"),
                                     .external("Bendy is rendering it"), .limited("Wallpaper only"),
                                     .unavailable("No lid-angle sensor"), .note("Watching quietly")]
        let sheet = Form {
            Section {
                SettingsPageHeader(page: .toys)
            }
            SettingGroup("A grouped page", note: "A footer note under the group, in the subtitle's size.") {
                Toggle(isOn: .constant(true)) {
                    SettingLabel(title: "A switch", subtitle: "A one-sentence description under its title.")
                }
                SettingRow("A button", subtitle: "The control sits in the trailing column.") {
                    Button("Do It…") {}
                }
                DisclosureGroup(isExpanded: .constant(true)) {
                    Toggle(isOn: .constant(false)) {
                        SettingLabel(title: "Inside the panel", subtitle: "Rows under an open disclosure.")
                    }
                    LabeledContent {
                        Text("42 min").foregroundStyle(.secondary)
                    } label: {
                        SettingLabel(title: "A reading")
                    }
                } label: {
                    SettingLabel(title: "An open disclosure", subtitle: "The chevron turns in the control column.")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    CardNote("A note with a glyph: how a thing works.")
                    CardSectionHeader("A run")
                    Toggle(isOn: .constant(true)) {
                        SettingLabel(title: "A parent switch", subtitle: "Its dependent rows sit below it.")
                    }
                    CardSubrows {
                        FlowLayout {
                            Toggle("Asks", isOn: .constant(true))
                            Toggle("Completions", isOn: .constant(true))
                            Toggle("Failures", isOn: .constant(false))
                            Toggle("Quota resets", isOn: .constant(true))
                            Toggle("Power", isOn: .constant(false))
                        }
                        .toggleStyle(ChipToggleStyle())
                        .padding(.vertical, SettingsMetrics.s)
                        Toggle(isOn: .constant(false)) {
                            SettingLabel(title: "A dependent switch")
                        }
                    }
                    CardNote("A warning, with its fix beside it.", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    CardSectionHeader("Pills")
                    FlowLayout {
                        ForEach(statuses, id: \.text) { StatusPill($0.text, tint: $0.tint) }
                    }
                    .padding(.vertical, SettingsMetrics.s)
                }
                .cardBodyStyle()
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(SettingsDisclosureStyle())
        for dark in [false, true] where Self.wanted("atoms") {
            let rep = try Self.snapshot(sheet, size: CGSize(width: Self.paneWidth, height: 2000), dark: dark)
            try Self.write(rep, named: "atoms-\(dark ? "dark" : "light")")
        }
    }

    /// The sheets Settings raises: calibration over the strip and the
    /// Doctor's report.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the sheet PNGs"))
    func sheets() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        let strip = fixture.settings.deviceEntries.first { $0.kind != "dot" }?.id ?? "virtual:status-bar"
        let report: JSONValue = .object([
            "ok": .bool(false),
            "checks": .array([
                .object(["name": .string("Socket"), "ok": .bool(true), "detail": .string("listening")]),
                .object(["name": .string("Claude hooks"), "ok": .bool(true), "detail": .string("12 events")]),
                .object(["name": .string("Codex hooks"), "ok": .bool(false), "detail": .string("stale since 2 h")]),
                .object(["name": .string("SidePulse"), "ok": .bool(true), "detail": .string("/Volumes/SidePulse")]),
            ]),
        ])
        for dark in [false, true] where Self.wanted("sheet") {
            let calibration = CalibrationSheet(store: fixture.settings, deviceID: strip, dismiss: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(maxHeight: .infinity, alignment: .top)
            let rep = try Self.snapshot(calibration, size: CGSize(width: 540, height: 900), dark: dark)
            try Self.write(rep, named: "sheet-calibration-\(dark ? "dark" : "light")")
            var bundle = SettingsBundle(exportedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                        appVersion: "0.8.0", schema: 1)
            bundle.monitor = ["global_brightness_scale": .number(0.8), "alert_burst": .number(3)]
            bundle.devices = .array([])
            bundle.toys = .object([:])
            bundle.preferences = ["sound.volume": .number(0.6)]
            let importer = SettingsImportSheet(bundle: bundle, monitorLive: false, knownSchema: 1,
                                               apply: { _ in }, cancel: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(maxHeight: .infinity, alignment: .top)
            let imp = try Self.snapshot(importer, size: CGSize(width: 460, height: 700), dark: dark)
            try Self.write(imp, named: "sheet-import-\(dark ? "dark" : "light")")
            let doctor = DoctorSheet(report: report, dismiss: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(maxHeight: .infinity, alignment: .top)
            let doc = try Self.snapshot(doctor, size: CGSize(width: 480, height: 640), dark: dark)
            try Self.write(doc, named: "sheet-doctor-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
    }

    /// The whole window at the size it first opens — sidebar,
    /// toolbar-less split and a page.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the window PNGs"))
    func window() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for page in [SettingsStore.Page.utilities, .toys, .general] {
            fixture.settings.page = page
            for dark in [false, true] where Self.wanted("window-\(page.rawValue)") {
                let view = SettingsRootView(store: fixture.settings)
                let rep = try Self.snapshot(view, size: SettingsWindowController.defaultSize, dark: dark)
                try Self.write(rep, named: "window-\(page.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        // A search: the sidebar lists the hits, the page names the one
        // picked, and its card is open and lit.
        fixture.settings.searchQuery = "lyrics"
        if let hit = fixture.settings.searchResults.first { fixture.settings.reveal(hit) }
        for dark in [false, true] where Self.wanted("window-search") {
            let view = SettingsRootView(store: fixture.settings)
            let rep = try Self.snapshot(view, size: SettingsWindowController.defaultSize, dark: dark)
            try Self.write(rep, named: "window-search-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
    }

    // MARK: lane dock

    /// The Dock card's Appearance group with the spacing between stops
    /// and the glass 12 pt off the Dock: no stop lit, the subtitle
    /// naming the value with the control still beside the title, and the
    /// live sample at that spacing and gap, in both appearances. The
    /// default card is `card-dock-*` above.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Dock card PNGs"))
    func dockCardAppearance() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-render-proof-dock.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try Self.document())))
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        // Seeded, not edited: a write would re-apply the Dock utility.
        var state = UtilitiesState()
        state.dock.enhance.previewSpacing = 0.85
        state.dock.enhance.dockGap = 12
        let utilities = UtilitiesStore(core: core, settings: settings, state: state)
        settings.utilities = utilities
        settings.expandedCards = [utilities.dock.id]
        for dark in [false, true] where Self.wanted("card-dock") {
            let view = SettingsPageContainer(store: settings, page: .utilities)
            let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
            try Self.write(rep, named: "card-dock-custom-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime((core, settings, toys, utilities)) {}
    }

    // MARK: lane menubar

    /// A concealer backend that never asserts anything.
    private final class MenuBarQuietBackend: MenuBarConcealBackend {
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            MenuBarAssertionToken(NSNumber(value: 1))
        }
        func invalidate(_ token: MenuBarAssertionToken) {}
    }

    /// The Menu Bar card as the card draws it, Advanced open and under a
    /// concealer that is never started: the ⌘-drag rows, Item Bar opens
    /// at, then Relaunch, New menu bar items, Icon seat and the layout
    /// table in their real places.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Menu Bar Advanced PNGs"))
    func menuBarAdvanced() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        let utility = fixture.utilities.menuBar
        utility.concealer = MenuBarConcealer(backend: MenuBarQuietBackend())
        for dark in [false, true] where Self.wanted("card-menuBar-advanced") {
            let card = Form {
                Section {
                    MenuBarUtilityControls(utility: utility, showAdvanced: true)
                        .cardBodyStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            let rep = try Self.snapshot(card, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
            try Self.write(rep, named: "card-menuBar-advanced-\(dark ? "dark" : "light")")
        }
        utility.concealer = nil
        withExtendedLifetime(fixture) {}
    }

    // MARK: lane confetti

    /// A search for Hang time: the Confetti card opens with Adjust open
    /// under it, so the row the search named is on show. Adjust opens
    /// once per search, so each shot searches again.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the card PNGs"))
    func confettiSearchOpensAdjust() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for dark in [false, true] where Self.wanted("card-confetti-search") {
            fixture.settings.reveal(SettingsSearchEntry(.toys, "Confetti", "Hang time", card: "confetti"))
            let view = SettingsPageContainer(store: fixture.settings, page: .toys)
            let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
            try Self.write(rep, named: "card-confetti-search-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
    }

    // MARK: lane utilities

    /// The Screen Bar card with two apps under "Hide over these apps", and
    /// the Keep Awake card open on the Utilities page, in both appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the utilities-lane PNGs"))
    func laneUtilities() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        fixture.settings.set(ScreenBarHiddenAppsRow.path,
                             .array([.string("com.apple.iWork.Keynote"), .string("us.zoom.xos")]))
        let row = Form {
            Section("Screen Bar") {
                ScreenBarHiddenAppsRow(store: fixture.settings,
                                       offered: [("com.apple.Safari", "Safari")])
            }
        }
        .formStyle(.grouped)
        .environment(fixture.settings)
        for dark in [false, true] where Self.wanted("screenbar-hidden-apps") {
            let rep = try Self.snapshot(row, size: CGSize(width: Self.paneWidth, height: 360), dark: dark)
            try Self.write(rep, named: "settings-screenbar-hidden-apps-\(dark ? "dark" : "light")")
        }
        fixture.settings.expandedCards = ["keepAwake"]
        // The real page's card, with fixed holders: this Mac's own power
        // holders never reach the PNG.
        KeepAwakeUtility.shared.proofHolders = [
            KeepAwakeHolders.Holder(name: "Amphetamine", bundleID: "com.if.Amphetamine", display: false),
        ]
        defer { KeepAwakeUtility.shared.proofHolders = nil }
        for dark in [false, true] where Self.wanted("card-keepAwake") {
            let view = SettingsPageContainer(store: fixture.settings, page: .utilities)
            let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
            try Self.write(rep, named: "card-keepAwake-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
    }

    // MARK: lane led-link

    /// A lights frame for a linked Pro + Dot: the Dot extending the strip,
    /// held 18 ms from it on a clock 2.66% slow, and a foreign write on the
    /// SidePulse (the mock's device ids).
    private static let linkedLightsFrame = """
    {"t":"lights","v":1,"linked":true,"devices_linked":true,
     "surfaces":{
      "hardware":{"program":"0:#00E5FF 400ms cosine; 1:#00E5FF 400ms cosine 100ms\\nrepeat","led_count":8,"why":"working"},
      "dot":{"program":"0:#00E5FF 1:#00B8CC 400ms cosine\\nrepeat","led_count":2,"why":"working","role":"extend"}},
     "dot_link":{"state":"linked","role":"extend","error":null,"phase_error_ms":-18.4,
      "clock_rate":0.9734,"clock_source":"measured","tolerance_ms":40,"sync_writes_hour":3,
      "rotation":"exact","style":"continue","rung":"brightest"},
     "device_receipts":{"sidepulse:pro:B293A1":{"foreign_write_at":1790271000.0,"foreign_writes":1,"paused":false}}}
    """

    /// The same pair with a comet the Dot carries on (`rung: continue`) and
    /// a Check sync running for another half minute.
    private static func continuingLightsFrame(checkUntil: Double) -> String {
        """
        {"t":"lights","v":1,"linked":true,"devices_linked":true,
         "surfaces":{
          "hardware":{"program":"0:#00E5FF 400ms cosine; 1:#00E5FF 400ms cosine 100ms\\nrepeat","led_count":8,"why":"working"},
          "dot":{"program":"#00E5FF 496ms pulse 658ms; 1:#00E5FF 496ms pulse 823ms\\nrepeat","led_count":2,"why":"working","role":"extend"}},
         "dot_link":{"state":"linked","role":"extend","error":null,"phase_error_ms":7.2,
          "clock_rate":0.9734,"clock_source":"measured","tolerance_ms":40,"sync_writes_hour":1,
          "rotation":"exact","style":"continue","rung":"continue","check_until":\(checkUntil)}}
        """
    }

    /// The Devices page with a linked Pro + Dot, at the default width and
    /// the narrowest, in both appearances: the Pro & Dot group's look, trim,
    /// clock and Check sync; the readout's measured timing; the Dot's card
    /// with Display, Pin to, Asks only, Blend and Auto-brightness switched
    /// off and the reason on the card; the receipt and the eject guard on
    /// the SidePulse's. Then a comet the Dot continues, with its side
    /// picker and a Check sync running, and the Mirror look. Every fold on
    /// the page is open, so each card's rows are drawn.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the linked Devices PNGs"))
    func linkedDevices() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        fixture.core.apply(try CoreCodec.decode(frame: Data(Self.linkedLightsFrame.utf8)))
        fixture.settings.page = .devices
        fixture.settings.openFolds = Set(fixture.settings.deviceEntries.map { SettingsFold.device($0.id) }
            + [SettingsFold.screenBar, SettingsFold.creatorMicro, SettingsFold.streamDeck])
        for width in [CGFloat(560), CGFloat(430)] {
            for dark in [false, true] where Self.wanted("linked-devices") {
                let view = SettingsPageContainer(store: fixture.settings, page: .devices)
                let rep = try Self.snapshot(view, size: CGSize(width: width, height: 6000), dark: dark)
                try Self.write(rep, named: "linked-devices-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
        // A comet the Dot carries on, with Check sync running: the readout
        // says "Continuing the strip" and the check row says it is watching.
        let checking = Date().timeIntervalSince1970 + 30
        let continuing = Self.continuingLightsFrame(checkUntil: checking)
        fixture.core.apply(try CoreCodec.decode(frame: Data(continuing.utf8)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for dark in [false, true] where Self.wanted("linked-devices") {
            let view = SettingsPageContainer(store: fixture.settings, page: .devices)
            let rep = try Self.snapshot(view, size: CGSize(width: 560, height: 6000), dark: dark)
            try Self.write(rep, named: "linked-devices-continue-\(dark ? "dark" : "light")")
        }
        // Mirror picked: no side picker.
        fixture.core.apply(try CoreCodec.decode(frame: Data(Self.linkedLightsFrame.utf8)))
        fixture.settings.set("dot_extend_style", .string("mirror"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for dark in [false, true] where Self.wanted("linked-devices") {
            let view = SettingsPageContainer(store: fixture.settings, page: .devices)
            let rep = try Self.snapshot(view, size: CGSize(width: 560, height: 6000), dark: dark)
            try Self.write(rep, named: "linked-devices-mirror-\(dark ? "dark" : "light")")
        }
        // The real rows with the monitor live, so Check sync and the eject
        // guard's buttons are as the person sees them: the Pro & Dot rows,
        // the Clock disclosure's rows open, and the eject guard in every
        // state it can be in (seeded, so the row asks nothing).
        let live = try Self.fixture()
        live.core.handle(.connected)
        live.core.apply(.state(CoreState()))
        live.core.apply(try CoreCodec.decode(frame: Data(Self.linkedLightsFrame.utf8)))
        let readings = [
            EjectGuardReading(installed: false),
            EjectGuardReading(installed: true, mountedVolumeUUID: "5E1F"),
            EjectGuardReading(installed: true, runs: 2, mountedVolumeUUID: "5E1F"),
            EjectGuardReading(installed: true, volumeUUID: "5E1F", mountedVolumeUUID: "5E1F"),
            EjectGuardReading(installed: true, volumeUUID: "5E1F", mountedVolumeUUID: "5E1F", loaded: true),
            EjectGuardReading(installed: true, protects: true, volumeUUID: "7F02", mountedVolumeUUID: "5E1F"),
            EjectGuardReading(installed: true, protects: true, protectsMounted: true, running: true,
                              volumeUUID: "5E1F", mountedVolumeUUID: "5E1F"),
        ]
        let store = live.settings
        let sheet = Form {
            SettingGroup("Pro & Dot") { LinkedSyncControls(store: store) }
            SettingGroup("Clock") { LinkedClockRows(store: store) }
            SettingGroup("Eject guard") {
                ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                    EjectGuardRow(store: store, reading: reading)
                }
            }
        }
        .formStyle(.grouped)
        for dark in [false, true] where Self.wanted("linked-devices") {
            let rep = try Self.snapshot(sheet, size: CGSize(width: 560, height: 1500), dark: dark)
            try Self.write(rep, named: "linked-eject-guard-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
        withExtendedLifetime(live) {}
    }

    // MARK: lane oss

    /// Settings › Usage › Hooks: a rule that runs, with its last result,
    /// and one that never will, with the reason, over the mock's rules.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the usage hooks PNGs"))
    func usageHooks() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        Self.goLive(fixture.core)
        let model = UsageHooksModel()
        let ninthMinute = Date().timeIntervalSince1970 - 540
        model.lastResults = ["chime": UsageHookLastResult(sentence: "Quota low: exit 0 in 0.1 s", at: ninthMinute, ok: true,
                                                          event: "quota_low")]
        model.problems = ["log": "the executable must be an absolute path"]
        for dark in [false, true] where Self.wanted("settings-usage-hooks") {
            let view = Form { UsageHooksSection(store: fixture.settings, model: model) }
                .formStyle(.grouped)
            let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 900), dark: dark)
            try Self.write(rep, named: "settings-usage-hooks-\(dark ? "dark" : "light")")
        }
        withExtendedLifetime(fixture) {}
    }

    /// Settings › Usage › Claude Code status line with a monitor that
    /// answers: the question asked before someone's own status line is
    /// kept, and the refusal for one JR-Bar can't keep.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the status line PNGs"))
    func usageStatusLine() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        Self.goLive(fixture.core)
        let ask = "Claude Code already has a status line. JR-Bar can keep it and show its own line above it."
        let refused = "Claude Code's status line isn't a command JR-Bar can run after its own, so it was left as it is. "
            + "Remove it from ~/.claude/settings.json to use JR-Bar's."
        let states: [(name: String, ask: String?, failure: String?)] = [
            ("settings-usage-statusline", ask, nil),
            ("settings-usage-statusline-refused", nil, refused),
        ]
        for state in states where Self.wanted(state.name) {
            for dark in [false, true] {
                let view = Form { ClaudeStatusLineSection(store: fixture.settings, askToWrap: state.ask, failure: state.failure) }
                    .formStyle(.grouped)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 520), dark: dark)
                try Self.write(rep, named: "\(state.name)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }

    /// A monitor that answers, so buttons that need one draw enabled.
    private static func goLive(_ core: CoreModel) {
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [], asks: [])))
    }
}
