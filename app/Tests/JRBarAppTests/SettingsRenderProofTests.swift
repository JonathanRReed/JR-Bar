import JRBarTestSupport
import JRBarUI
import QuartzCore
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
@Suite("Settings render proof", .renderProofAppearance)
@MainActor
struct SettingsRenderProofTests {
    init() throws {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" { try U5Proof.pinDefaultAccent() }
    }

    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test("owner feedback settings", .enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1"))
    func ownerFeedbackSettings() async throws {
        let firmwareLink = FakeFirmwareLink()
        let firmware = FirmwareStore(send: firmwareLink.send)
        let fixture = try Self.fixture(firmware: firmware)
        defer { fixture.toys.shutdown() }
        let pro = try #require(fixture.settings.deviceEntries.first { $0.kind == "pro" })
        let dot = try #require(fixture.settings.deviceEntries.first { $0.kind == "dot" })
        firmwareLink.statusOverride = SettingsDocument(FakeFirmwareLink.json(FakeFirmwareLink.proReply))
            .replacing("devices.0.id", with: .string(pro.id)).root
        await firmware.refresh()
        var deck = DeckState(device: DeckDevice(connected: false))
        deck.settings.enabled = true
        fixture.core.handle(.connected)
        fixture.core.apply(.state(CoreState(devices: [
            CoreDevice(id: pro.id, kind: "pro", name: "SidePulse Pro", connected: true, enabled: true),
            CoreDevice(id: dot.id, kind: "dot", name: "PulseDot", connected: false, enabled: true),
        ], health: .object(["hooks": .object(["claude": .string("installed"), "codex": .string("installed")])]), deck: deck)))
        fixture.settings.t3Integration.receive(T3CodeStatus(present: true, enabled: true, readOnly: true,
                                                          running: true, installed: true))
        fixture.toys.state.confetti.enabled = true
        for dark in [false, true] {
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                IntegrationsPage(store: fixture.settings)
            }.padding(24), name: "owner-integrations", width: 620, dark: dark)
            try await U5Proof.render(VStack {
                ToysPage(store: fixture.settings)
            }.padding(24), name: "owner-toy-rows", width: 620, dark: dark)
            try await U5Proof.render(SettingsGroup {
                NotchRendererPicker(selection: .constant(.jrbar), alcoveInstalled: true, boringNotchInstalled: false)
            }.padding(24), name: "owner-render-with", width: 620, dark: dark)
            try await U5Proof.render(SettingsGroup {
                NotchRendererPicker(selection: .constant(.boringNotch), alcoveInstalled: false, boringNotchInstalled: false)
            }.padding(24), name: "owner-render-with-missing", width: 620, dark: dark)
        }
    }

    @Test("the mock's notification setting survives decoding and binding")
    func notificationBinding() throws {
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        #expect(fixture.core.settings?.document["completion_notification_enabled"] == .bool(true))
        #expect(fixture.settings.bool("completion_notification_enabled").wrappedValue)
        #expect(fixture.settings.bool("dnd_schedule_enabled").wrappedValue == false)
    }

    @Test("native switch proofs place the on thumb to the right of off", .enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1"))
    func toggleStates() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        let original = try #require(fixture.core.settings?.document)
        for dark in [false, true] {
            var images: [NSBitmapImageRep] = []
            for on in [false, true] {
                let document = SettingsDocument(original).replacing("completion_notification_enabled", with: .bool(on))
                fixture.core.apply(.settings(CoreSettings(generation: on ? 3 : 2, schema: CoreProtocol.knownSettingsSchema,
                                                          document: document.root)))
                #expect(fixture.settings.bool("completion_notification_enabled").wrappedValue == on)
                let view = Form {
                    SettingToggle(fixture.settings, "Notification banner", path: "completion_notification_enabled")
                }.formStyle(.grouped).tint(.blue)
                let rep = try await DesignFixBProof.snapshot(view, title: "Settings switches",
                                                            size: CGSize(width: 560, height: 140), dark: dark)
                try Self.write(rep, named: "toggle-\(on ? "on" : "off")-\(dark ? "dark" : "light")")
                images.append(rep)
            }
            var brighter = (count: 0, x: CGFloat(0))
            var darker = (count: 0, x: CGFloat(0))
            // Compare active native thumb positions without relying on tint.
            let off = images[0], on = images[1]
            for y in stride(from: 0, to: off.pixelsHigh, by: 4) {
                for x in stride(from: off.pixelsWide - 160, to: off.pixelsWide, by: 4) {
                    let before = try #require(off.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let after = try #require(on.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let beforeLight = (before.redComponent + before.greenComponent + before.blueComponent) / 3
                    let afterLight = (after.redComponent + after.greenComponent + after.blueComponent) / 3
                    let delta = afterLight - beforeLight
                    // White on the near-white off track has a small luminance change.
                    if delta > 0.03 { brighter.count += 1; brighter.x += CGFloat(x) }
                    if delta < -0.03 { darker.count += 1; darker.x += CGFloat(x) }
                }
            }
            try #require(brighter.count > 20 && darker.count > 20, "on and off must draw different thumb positions")
            let onX = brighter.x / CGFloat(brighter.count)
            let offX = darker.x / CGFloat(darker.count)
            #expect(onX > offX + 10, "the on thumb must be to the right of the off thumb")
        }
    }

    /// The detail pane's width at the window's older default size;
    /// `JRBAR_RENDER_PROOF_WIDTH=430` draws the narrowest the window allows.
    static let paneWidth: CGFloat = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_WIDTH"]
        .flatMap(Double.init).map { CGFloat($0) } ?? 560

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-settings-proof", isDirectory: true)
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1"))
    func lifecycleSwitches() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        for dark in [false, true] {
            let presence = SettingsPageContainer(store: fixture.settings, page: .alerts)
            let presenceImage = try Self.snapshot(presence, size: CGSize(width: 560, height: 7000), dark: dark)
            try Self.write(presenceImage, named: "lifecycle-presence-\(dark ? "dark" : "light")")
            let studio = EffectStudioStore(core: fixture.core,
                defaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.device-proof"))!, settings: fixture.settings)
            let controls = StudioDevicesPage(store: studio)
            let deviceImage = try Self.snapshot(controls, size: CGSize(width: 560, height: 1600), dark: dark)
            try Self.write(deviceImage, named: "lifecycle-device-\(dark ? "dark" : "light")")
        }
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
    struct Fixture {
        let core: CoreModel
        let settings: SettingsStore
        let toys: ToysStore
        let utilities: UtilitiesStore
    }

    static func fixture(firmware: FirmwareStore? = nil) throws -> Fixture {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-render-proof.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try document())))
        let settings = SettingsStore(core: core, firmware: firmware)
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
                   fixture.utilities.agents.id]
        if let notch = fixture.toys.notch { ids.append(notch.id) }
        ids += fixture.toys.toys.map(\.id)
        return ids
    }

    // MARK: Rendering

    /// Draws `view` in an offscreen window at `size` under the given
    /// appearance and returns its layer tree as a bitmap — AppKit-backed
    /// controls included, which `ImageRenderer` cannot draw.
    static func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool, growToFit: Bool = false,
                                  requiresKey: Bool = false) throws -> NSBitmapImageRep {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" { try RenderProofAppearance.pinDefaultAccent() }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .tint(.blue).accentColor(.blue)
            .frame(width: size.width, height: growToFit ? nil : size.height))
        let window = SettingsKeyProofWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        var captureSize = size
        if growToFit {
            hosting.layoutSubtreeIfNeeded()
            captureSize.height = max(size.height, ceil(hosting.fittingSize.height))
            window.setContentSize(captureSize)
            hosting.frame = NSRect(origin: .zero, size: captureSize)
        }
        if enabled && requiresKey {
            try WindowPresenter.renderProofKey(window)
            if !window.isKeyWindow { FoundationRenderProofTests.runUntilKey(window) }
            #expect(window.isKeyWindow)
        }
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(captureSize.width * scale), pixelsHigh: Int(captureSize.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = captureSize
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Crops a snapshot's empty tail: rows at the bottom that match the
    /// last row's colour everywhere.
    static func cropped(_ rep: NSBitmapImageRep, margin: Int = 24) -> CGImage? {
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

    /// Every page with its Advanced fold open, in both appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Settings PNGs"))
    func pagesAdvancedOpen() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for page in SettingsStore.Page.allCases {
            for dark in [false, true] where Self.wanted("advanced-\(page.rawValue)") {
                fixture.settings.page = page
                fixture.settings.setFold(SettingsFold.advanced(page), open: true)
                let view = SettingsPageContainer(store: fixture.settings, page: page)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 7000), dark: dark)
                try Self.write(rep, named: "advanced-\(page.rawValue)-\(dark ? "dark" : "light")")
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
            let page = SettingsStore.Page.utilities
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
                SettingsPageHeader(page: .utilities)
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
                        ForEach(statuses, id: \.text) { StatusBadge($0.text, tint: $0.tint) }
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
        for page in [SettingsStore.Page.utilities, .general] {
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

    /// The Menu Bar card as the card draws it, Advanced open: the Item Bar
    /// opens at, then Relaunch and the profile rows in their real places.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Menu Bar Advanced PNGs"))
    func menuBarAdvanced() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        let utility = fixture.utilities.menuBar
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
        withExtendedLifetime(fixture) {}
    }

    /// Every state the Menu Bar card's banner can say, stacked.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Menu Bar banner PNGs"))
    func menuBarBanner() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var inputs: [MenuBarHidingStatus.Inputs] = []
        func add(_ edit: (inout MenuBarHidingStatus.Inputs) -> Void) {
            var i = MenuBarHidingStatus.Inputs()
            i.engine = .divider
            i.dividerHidden = 4
            i.recovery = .clear
            edit(&i)
            inputs.append(i)
        }
        add { _ in }
        add { $0.dividerHidden = 0 }
        add { $0.noRoom = true; $0.noRoomHelp = "macOS is holding 5 items in its « overflow. Quit or switch off at least 1 menu bar item to give the JR-Bar icon a place." }
        add { $0.overlay = .showEverything; $0.overlayNote = "Everything is showing until 14:30 — your picks come back then." }
        add { $0.rivals = ["Bartender"] }
        add { $0.accessibilityGranted = false }
        add { $0.enabled = false }
        for dark in [false, true] where Self.wanted("card-menuBar-banner") {
            let stack = VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                    MenuBarHidingBanner(status: MenuBarHidingStatus.assess(input)) { _ in }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            let rep = try Self.snapshot(stack, size: CGSize(width: 560, height: 1100), dark: dark)
            try Self.write(rep, named: "card-menuBar-banner-\(dark ? "dark" : "light")")
        }
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
            let view = SettingsPageContainer(store: fixture.settings, page: .utilities)
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

    /// Settings › Agents & Usage › Advanced › Hooks: a rule that runs, with its last result,
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

    /// Settings › Agents & Usage › Advanced › Claude Code status line with a monitor that
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

extension SettingsRenderProofTests {
    @Test("Approved Settings pages as key windows", .enabled(if: Self.enabled))
    func organizedKeyWindows() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let status: JSONValue = .object([
            "catalog": .array([]),
            "devices": .array(["pro", "dot"].map { kind in .object([
                "id": .string("fixture-\(kind)"), "name": .string(kind == "pro" ? "SidePulse" : "PulseDot"),
                "model": .string(kind), "mounted": .bool(true), "version": .string("1.0.0"),
                "latest": .string("1.0.0"), "update_available": .bool(false), "can_update": .bool(false),
            ]) }),
        ])
        let firmware = FirmwareStore { _, _ in CoreReply(id: "proof", ok: true, result: status) }
        await firmware.refresh()
        let fixture = try Self.fixture(firmware: firmware)
        defer { fixture.toys.shutdown() }
        Self.goLive(fixture.core)
        let hardware = fixture.settings.deviceEntries.filter { $0.kind == "pro" || $0.kind == "dot" }.map {
            CoreDevice(id: $0.id, kind: $0.kind, connected: true)
        }
        fixture.core.apply(.state(CoreState(devices: hardware)))
        fixture.settings.launchAtLoginStatus = { false }
        let previousHolders = KeepAwakeUtility.shared.proofHolders
        KeepAwakeUtility.shared.proofHolders = []
        defer { KeepAwakeUtility.shared.proofHolders = previousHolders }
        let providerData = Data("""
        [{"id":"claude","enabled":true,"supports_quota":true,"usage_consent":{"granted":true,"version":1,"detail":"Reads account quota.","question":"Read Claude usage?"}},
         {"id":"codex","enabled":true,"supports_quota":true,"usage_consent":{"granted":false,"version":1}},
         {"id":"gemini","enabled":false,"supports_quota":true},
         {"id":"factory","enabled":true,"supports_local_tokens":true,"usage_consent":{"granted":false,"version":1}}]
        """.utf8)
        let providers = try JSONDecoder().decode([ProviderRow].self, from: providerData)
        fixture.settings.providerList.readRows = { providers }
        await fixture.settings.providerList.refresh()
        fixture.settings.t3Integration.receive(T3CodeStatus(present: true, enabled: true, readOnly: true,
                                                          observation: nil, running: false, installed: true))
        for page in SettingsStore.Page.allCases {
            fixture.settings.page = page
            let heights: [SettingsStore.Page: CGFloat] = [
                .alerts: 3200, .shortcuts: 2400, .remote: 2200, .advanced: 2400,
                .privacy: 1500, .devices: 2600, .notch: 5000, .agents: 1400,
            ]
            let height = heights[page] ?? 1000
            for dark in [false, true] {
                try await Self.keySnapshot(SettingsRootView(store: fixture.settings),
                                           name: "u3-\(page.rawValue)", height: height, dark: dark)
            }
        }
        for page in [SettingsStore.Page.agents, .alerts, .shortcuts] {
            fixture.settings.page = page
            fixture.settings.subpage = "advanced"
            for dark in [false, true] {
                try await Self.keySnapshot(SettingsRootView(store: fixture.settings),
                                           name: "u3-\(page.rawValue)-advanced", height: page == .alerts ? 2800 : 1600, dark: dark)
            }
        }
        fixture.settings.page = .agents
        fixture.settings.selectedProvider = "claude"
        for dark in [false, true] {
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "u3-provider-detail", height: 1000, dark: dark)
        }
        fixture.settings.page = .utilities
        fixture.settings.subpage = "keepAwake"
        for dark in [false, true] {
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "u3-keep-awake", height: 1700, dark: dark)
        }
        for id in Self.cardIDs(fixture) where id != fixture.toys.notch?.id {
            fixture.settings.subpage = id
            fixture.settings.expandedCards.insert(id)
            let height: CGFloat = id == "menuBar" ? 6000 : id == "dock" ? 4500 : 2600
            for dark in [false, true] {
                try await Self.keySnapshot(SettingsRootView(store: fixture.settings),
                                           name: "u3-detail-\(id)", height: height, dark: dark)
            }
        }
        fixture.settings.page = .devices
        fixture.core.handle(.disconnected(reason: "Synthetic disconnect"))
        for dark in [false, true] {
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "u3-devices-offline", height: 2600, dark: dark)
        }
    }

    static func keySnapshot<V: View>(_ view: V, name: String, height: CGFloat, dark: Bool) async throws {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" { try RenderProofAppearance.pinDefaultAccent() }
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        // NSApp is nil until something asks for the shared application; a
        // filtered proof run can reach here first.
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        app.appearance = appearance
        defer { app.appearance = previousAppearance }
        let size = SettingsWindowController.defaultSize
        let root = view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .tint(.blue).accentColor(.blue)
            .jrbarAccessibility(reduceMotion: true)
        let window = SettingsKeyProofWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                            styleMask: SettingsWindowController.windowStyle, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "JR-Bar Settings"
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "u3-proof-toolbar")
        window.appearance = appearance
        let controller = WindowContentLifecycle.attach(to: window, title: "JR-Bar Settings") {
            SettingsHostingController(rootView: AnyView(CheckedContent(content: root)))
        }
        let host = controller.view
        host.appearance = appearance
        window.setContentSize(size)
        defer { WindowContentLifecycle.detach(from: window); window.close() }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try WindowPresenter.renderProofKey(window)
        if !window.isKeyWindow { FoundationRenderProofTests.runUntilKey(window) }
        // A headless run has no window server session to grant key; only an
        // interactive run can prove the key-window look.
        let interactive = ProcessInfo.processInfo.environment["JRBAR_INTERACTIVE_TESTS"] == "1"
        if interactive { #expect(window.isKeyWindow) }
        if let table = SettingsWindowController.sidebarTable(in: host) { window.makeFirstResponder(table) }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await drainMainQueue()
        }
        CATransaction.flush()
        if interactive { #expect(window.isKeyWindow, "The page is captured as a native key window") }
        let frame = try #require(window.contentView?.superview)
        func capture(_ suffix: String = "") throws {
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            appearance.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
            }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: Self.directory.appendingPathComponent("\(name)\(suffix)-\(dark ? "dark" : "light").png"))
        }
        try capture()
        if ProcessInfo.processInfo.environment["JRBAR_POLISH_SWEEP"] == "1" {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            for scroll in scrollViews(in: host) where scroll.bounds.width > size.width / 2 {
                guard let document = scroll.documentView else { continue }
                let viewport = scroll.contentView.bounds.height
                let end = max(0, document.bounds.height - viewport)
                guard viewport > 40, end > 1 else { continue }
                let step = viewport - 40
                let count = min(40, Int(ceil(end / step)))
                for index in 1...count {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(end, CGFloat(index) * step)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        await drainMainQueue()
                    }
                    #expect(window.isKeyWindow)
                    try capture("-scroll-\(index)")
                }
                scroll.contentView.scroll(to: .zero)
            }
        }
    }
}

@MainActor
private final class SettingsKeyProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension SettingsRenderProofTests {
    @Test("Integrated Devices page as a key window", .enabled(if: Self.enabled))
    func integratedDevicesKeyWindows() async throws {
        try U5Proof.pinDefaultAccent()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        Self.goLive(fixture.core)
        let hardware = fixture.settings.deviceEntries.map { CoreDevice(id: $0.id, kind: $0.kind, connected: true) }
        fixture.core.apply(.state(CoreState(devices: hardware)))
        fixture.settings.page = .devices
        for dark in [false, true] {
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "integration-settings-devices",
                                       height: 2600, dark: dark)
        }
    }

    static func assertCatalogueHomes() async throws {
        let expected = SettingsCatalogueHomes.expected
        #expect(Set(expected.keys) == Set(SettingsKey.all.map(\.path)), "Every catalogue key needs an explicit destination")
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        Self.goLive(fixture.core)
        let hardware = fixture.settings.deviceEntries.map { CoreDevice(id: $0.id, kind: $0.kind, connected: true) }
        fixture.core.apply(.state(CoreState(devices: hardware)))
        let provider = try JSONDecoder().decode(ProviderRow.self, from: Data("""
        {"id":"claude","enabled":true,"usage_consent":{"granted":false,"version":1}}
        """.utf8))
        fixture.settings.providerList.readRows = { [provider] }
        await fixture.settings.providerList.refresh()
        fixture.settings.openFolds.formUnion([SettingsFold.dotClock, SettingsFold.screenBarAdvanced])
        let customShape = SettingsDocument(try Self.document()).replacing("screen_bar_notch_profile", with: .string("custom"))
        fixture.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema, document: customShape.root)))
        var homes: [String: Set<String>] = [:]
        let renderedOwners = expected.merging(["calibration_profiles": "studio.profiles"]) { current, _ in current }
        let catalogueRoutes = Set(expected.values.filter { !$0.hasPrefix("studio.") })
        var routes = catalogueRoutes.union(SettingsStore.Page.allCases.map(\.rawValue))
        routes.formUnion(cardIDs(fixture).filter { $0 != "notch" }.map { "utilities/" + $0 })
        for route in routes.sorted() {
            let parts = route.split(separator: "/").map(String.init)
            fixture.settings.page = try #require(SettingsStore.Page(rawValue: parts[0]))
            fixture.settings.subpage = parts.count > 1 && parts[1] != "provider" && parts[1] != "calibration" ? parts[1] : nil
            fixture.settings.selectedProvider = parts.last == "provider" ? "claude" : nil
            let paths: Set<String>
            if route == "devices/calibration" {
                let device = try #require(fixture.settings.deviceEntries.first)
                paths = try await controlPaths(CalibrationSheet(store: fixture.settings, deviceID: device.id,
                                                                dismiss: {}, fineTuneExpanded: true))
            } else {
                paths = try await controlPaths(SettingsPageContainer(store: fixture.settings, page: fixture.settings.page))
            }
            if catalogueRoutes.contains(route) { #expect(!paths.isEmpty, "No controls rendered for \(route)") }
            if route == "devices" {
                #expect(!paths.contains(ScreenBarController.stillOnCameraDefaultsKey))
            }
            for key in paths.map(SettingsCatalogueHomes.normalized) where renderedOwners[key] != nil {
                homes[key, default: []].insert(route)
            }
        }
        let suite = "jrbar.catalogue-home-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = EffectStudioStore(core: fixture.core, defaults: defaults, settings: fixture.settings)
        studio.covered = true
        studio.lightsStudio.requestPlan = {
            StudioLightPlan(mixes: [StudioMix(id: "color_blend", name: "Smooth", parameters: [])], devices: [])
        }
        studio.finishLookLoader = {
            FinishLookList(current: "bloom", enabled: true, looks: [
                FinishLookList.Look(style: "bloom", label: "Bloom", program: "#0088FF", dotProgram: "#0088FF")])
        }
        studio.scenePackLoader = { [ScenePackSummary(id: "fixture", name: "Fixture", scenes: ["calm"], installed: true)] }
        await studio.loadScenePacks()
        await studio.lightsStudio.refreshPlan()
        for mode in EffectStudioStore.Mode.allCases {
            studio.mode = mode
            let route = "studio.\(mode.rawValue)"
            // Each conditional Auto-dim control must render in its owning page.
            let dimModes = mode == .colours ? ["off", "schedule", "display", "ambient"] : ["off"]
            for dimMode in dimModes {
                let document = customShape.replacing("auto_dim.mode", with: .string(dimMode))
                let generation = (fixture.core.settings?.generation ?? 0) + 1
                fixture.core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema,
                                                          document: document.root)))
                let paths = try await controlPaths(EffectStudioView(store: studio))
                if mode == .devices { #expect(paths.contains(ScreenBarController.stillOnCameraDefaultsKey)) }
                for key in paths.map(SettingsCatalogueHomes.normalized) where renderedOwners[key] != nil {
                    homes[key, default: []].insert(route)
                }
            }
        }
        for (key, destination) in renderedOwners {
            #expect(homes[key] == [destination], "\(key): expected \(destination), rendered \(homes[key] ?? [])")
        }
        let beforeSearch = fixture.core.settings?.document
        fixture.settings.onOpenStudioSearch = { studio.reveal($0) }
        for entry in SettingsSearch.rows where entry.chapter == .lighting {
            let previousRequest = studio.searchRequest
            fixture.settings.reveal(entry)
            #expect(studio.searchRequest == previousRequest + 1, "\(entry.id) must route through Studio")
            let target = try #require(studio.searchPath)
            let paths = try await controlPaths(EffectStudioView(store: studio))
            #expect(paths.contains(target), "\(entry.id) did not render its target \(target) in \(studio.mode)")
        }
        #expect(fixture.core.settings?.document == beforeSearch, "Search must not write settings to reveal a control")
        let settingsCount = expected.values.filter { !$0.hasPrefix("studio.") }.count
        #expect(expected.count == 152)
        #expect(settingsCount == 93)
        print("Catalogue homes: \(expected.count) keys rendered exactly once by destination, \(settingsCount) Settings and \(expected.count - settingsCount) Studio")
    }

    private static func controlPaths<V: View>(_ view: V) async throws -> Set<String> {
        var rendered: Set<String> = []
        var occurrences: [String] = []
        let root = view.onPreferenceChange(SettingsControlPaths.self) { rendered.formUnion($0) }
            .onPreferenceChange(SettingsControlOccurrences.self) { occurrences = $0 }
            .environment(\.ledPreviewsHeld, true).environment(\.renderSnapshot, true)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 720, height: 10000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            await drainMainQueue()
        }
        let counts = Dictionary(grouping: occurrences, by: { $0 }).mapValues(\.count)
        #expect(counts.values.allSatisfy { $0 == 1 }, "Repeated rendered bindings: \(counts.filter { $0.value > 1 })")
        return rendered
    }
}

extension SettingsRenderProofTests {
    @Test("U3 fix round at the normal Settings size", .enabled(if: Self.enabled))
    func fixRoundKeyWindows() async throws {
        try U5Proof.pinDefaultAccent()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        defer { fixture.toys.shutdown() }
        Self.goLive(fixture.core)
        let hardware = fixture.settings.deviceEntries.map { CoreDevice(id: $0.id, kind: $0.kind, connected: true) }
        fixture.core.apply(.state(CoreState(devices: hardware)))
        let row = try JSONDecoder().decode(ProviderRow.self, from: Data("""
        {"id":"claude","enabled":true,"usage_consent":{"granted":false,"version":1,"detail":"Reads account quota."}}
        """.utf8))
        fixture.settings.providerList.readRows = { [row] }
        await fixture.settings.providerList.refresh()
        for page in SettingsStore.Page.allCases {
            fixture.settings.page = page
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-\(page.rawValue)", height: 620, dark: false)
        }
        fixture.settings.page = .agents
        fixture.settings.providerList.readRows = { throw CoreReplyError(code: "unavailable", message: "Provider list unavailable") }
        await fixture.settings.providerList.refresh()
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-provider-retry", height: 620, dark: false)
        fixture.settings.providerList.readRows = { [row] }
        await fixture.settings.providerList.refresh()
        fixture.settings.selectedProvider = "claude"
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-provider-detail", height: 620, dark: false)
        fixture.settings.page = .alerts
        fixture.settings.subpage = "advanced"
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-alerts-advanced", height: 620, dark: false)
        fixture.settings.page = .utilities
        fixture.settings.subpage = "keepAwake"
        let previous = KeepAwakeUtility.shared.proofHolders
        KeepAwakeUtility.shared.proofHolders = []
        defer { KeepAwakeUtility.shared.proofHolders = previous }
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-keep-awake", height: 620, dark: false)
        fixture.settings.subpage = "notch-buddy"
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-buddy", height: 620, dark: false)
        fixture.settings.page = .devices
        fixture.settings.openFolds.insert(SettingsFold.dotClock)
        try await Self.keySnapshot(ScrollView { VStack {
            DeviceLinkSettings(store: fixture.settings)
        }.padding(JRBarTokens.Space.lg) }.environment(fixture.settings), name: "fix-hardware-links", height: 620, dark: false)
        fixture.core.handle(.disconnected(reason: "Synthetic disconnect"))
        try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-devices-offline", height: 620, dark: false)
        for page in [SettingsStore.Page.devices, .utilities, .agents] {
            fixture.settings.page = page
            try await Self.keySnapshot(SettingsRootView(store: fixture.settings), name: "fix-\(page.rawValue)", height: 620, dark: true)
        }
    }
}
