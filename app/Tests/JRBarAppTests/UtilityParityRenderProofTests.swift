import AppKit
import CoreAudio
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the utilities parity pass: the rivals notes on the
/// Notch, Dock and Shelf rows, the Keep Awake card in both appearances,
/// the keep-awake duration menu, the shelf with a multi-selection and its
/// chip menu, the card's sound-output picker, the archive's provider
/// filter and the Overview's window-share fact. The fixtures are fixed —
/// no running app, power assertion or sound device of this Mac reaches a
/// PNG; only the card's battery line reads this Mac's own charge. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write PNGs into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Utility parity render proof", .serialized)
@MainActor
struct UtilityParityRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    // MARK: Fixtures

    private static func rival(_ name: String) -> UtilityRivals.Rival {
        UtilityRivals.known.first { $0.name == name }!
    }

    /// The mock monitor's settings document, read through its own script.
    private static func settingsStore() throws -> SettingsStore {
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-parity-proof.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try JSONDecoder().decode(JSONValue.self, from: data))))
        return SettingsStore(core: core)
    }

    /// A settings-window sheet: the grouped form the cards sit in.
    private static func sheet<V: View>(_ content: V, width: CGFloat = 560) -> some View {
        Form { Section { content } }
            .formStyle(.grouped)
            .disclosureGroupStyle(SettingsDisclosureStyle())
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A macOS menu as a still: the rows a context menu would show, with
    /// the check column and separators, on the menu's own glass.
    private struct MenuStill: View {
        struct Row: Identifiable {
            let id = UUID()
            var title: String
            var checked = false
            var enabled = true
            var divider = false
            var header = false
        }
        let rows: [Row]
        var width: CGFloat = 250

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if row.divider {
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(row.checked ? 1 : 0)
                            .frame(width: 14)
                        Text(row.title)
                            .font(.system(size: 13, weight: row.header ? .semibold : .regular))
                            .foregroundStyle(row.enabled && !row.header ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                }
            }
            .padding(.vertical, 5)
            .frame(width: width)
            .background(ProofGlass(cornerRadius: 10))
        }
    }

    /// A notch toy on a card model whose Now Playing is hand-fed.
    private static func makeToy() -> (NotchToy, ToysStore, NotchSurfaceRenderProofTests.ProofMonitor) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let monitor = NotchSurfaceRenderProofTests.ProofMonitor()
        let model = NotchCardModel(
            timers: ShelfTimerModel(storeURL: URL(fileURLWithPath:
                NSTemporaryDirectory() + "jrbar-parity-timers-\(UUID().uuidString).json")),
            tray: ShelfTrayModel(),
            utility: ShelfUtilityModel(feed: MediaFeed(monitor: monitor)),
            runtimeEnabled: false)
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: toys,
                              cardModel: model, notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        toy.capsuleTimer = { _, _ in }
        return (toy, store, monitor)
    }

    /// The grown card on black, hung from the notch, as the island shows it.
    private static func writeCard(_ toy: NotchToy, name: String, extra: AnyView? = nil) throws {
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: NotchSurfaceRenderProofTests.slotWidth)
        let card = NotchCardView(model: toy.cardModel, style: .island, width: width)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let island = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
            card.padding(.top, toy.cardTopPad)
        }
        let side: CGFloat = extra == nil ? 0 : 300
        let canvas = CGSize(width: width + 140 + side, height: max(height + 40, 420))
        let scene = HStack(alignment: .top, spacing: 0) {
            NotchSurfaceRenderProofTests.scene(island, size: CGSize(width: width, height: height),
                                               depth: depth, canvas: CGSize(width: width + 140, height: canvas.height))
            if let extra {
                ZStack(alignment: .top) {
                    ProofDesktop(dark: true)
                    extra.padding(.top, 60)
                }
                .frame(width: side, height: canvas.height)
            }
        }
        try ProofRender.write(scene, size: canvas, name: name)
    }

    private static func files(_ names: [String]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jrbar-parity-tray")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.map { name in
            let url = dir.appending(path: name)
            FileManager.default.createFile(atPath: url.path, contents: Data("proof".utf8))
            return url
        }
    }

    // MARK: Rivals

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func rivalGuards() throws {
        let notch = VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Text("JR-Bar").foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Render with", subtitle: "Let Alcove or Boring Notch draw the island instead.")
            }
            .padding(.vertical, SettingsMetrics.rowPadding)
            RivalGuardView(role: .notch, handOver: { _ in }, rivals: [Self.rival("Alcove"), Self.rival("Atoll")],
                           quit: { _ in })
        }.cardBodyStyle()
        let dock = VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Text("JR-Bar").foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Hand the previews to DockDoor (free) or ActiveDock (paid); ours park while the pick stands.")
            }
            .padding(.vertical, SettingsMetrics.rowPadding)
            RivalGuardView(role: .dockPreviews, handOver: { _ in }, rivals: [Self.rival("DockDoor")], quit: { _ in })
        }.cardBodyStyle()
        let shelf = VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: .constant(true)) {
                SettingLabel(title: "Step aside for other shelf apps",
                             subtitle: "While Dropover, Yoink or Dropzone runs, a shake is theirs, so one shake never opens two shelves. Dropping on the notch still works.")
            }
            RivalGuardView(role: .shelfGesture, rivals: [Self.rival("Dropover")], quit: { _ in })
        }.cardBodyStyle()
        for (name, view) in [("notch", AnyView(notch)), ("dock", AnyView(dock)), ("shelf", AnyView(shelf))] {
            for dark in [false, true] {
                try ProofRender.write(Self.sheet(view), size: CGSize(width: 560, height: 260),
                                      name: "rival-guard-\(name)\(dark ? "-dark" : "")", dark: dark)
            }
        }
    }

    // MARK: Keep awake

    /// A hold the daemon has: a countdown with a little under 42 minutes
    /// left from `now`, so every line that rounds it up says 42.
    private static func heldToggles(now: Date) throws -> SystemTogglesStore {
        let suite = "UtilityParityRenderProofTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.sendLease = { _ in .taken }
        let until = now.addingTimeInterval(42 * 60 - 20).timeIntervalSince1970
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","lease":{"kind":"duration","until":\#(until)}}"#.utf8))
        state.noteDaemonHold(hold, live: true)
        return SystemTogglesStore(state: state)
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func keepAwakeCard() throws {
        let settings = try Self.settingsStore()
        let now = Date()
        let utility = KeepAwakeUtility(toggles: try Self.heldToggles(now: now))
        settings.expandedCards = [utility.id]
        let holders = [KeepAwakeHolders.Holder(name: "Amphetamine", bundleID: "com.if.Amphetamine", display: false),
                       KeepAwakeHolders.Holder(name: "Keynote", bundleID: "com.apple.iWork.Keynote", display: true)]
        // The card as the page draws it — ToyCard's head, then the body
        // with fixed holders, so no app of this Mac reaches the PNG.
        let open = Self.sheet(VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: SettingsMetrics.m) {
                SettingsIconTile(symbol: utility.symbol,
                                 tint: ToyCard.tint(for: utility.id, page: SettingsStore.Page.utilities.tint),
                                 size: SettingsMetrics.cardTile)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SettingsMetrics.s) {
                        Text(utility.name).font(.body.weight(.semibold))
                        StatusPill(utility.status.text, tint: utility.status.tint)
                    }
                    Text(utility.blurb).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: .constant(utility.isOn)).labelsHidden().toggleStyle(.switch)
            }
            // The card's own clock, the one the status pill reads.
            KeepAwakeUtilityControls(utility: utility, holders: holders)
                .cardBodyStyle()
        }, width: 580).environment(settings)
        for dark in [false, true] {
            try ProofRender.write(open, size: CGSize(width: 580, height: 1100),
                                  name: "keepawake-card-\(dark ? "dark" : "light")", dark: dark, settle: 0.8)
        }
        withExtendedLifetime(settings) {}
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func awakeMenu() throws {
        let now = Date()
        let items = KeepAwakeMenu.items(durations: KeepAwakeMenu.defaultDurations,
                                        reading: KeepAwakeReading(state: .lease(.indefinite)),
                                        displayOn: true, monitorLive: true, now: now)
        // The items as the chip, the cup and the ear list them — the
        // real menu has no header row.
        let rows = items.map { MenuStill.Row(title: $0.title, checked: $0.checked, enabled: $0.enabled,
                                             divider: $0.dividerBefore) }
        let view = ZStack(alignment: .topLeading) {
            ProofDesktop(dark: true)
            MenuStill(rows: rows).padding(24)
        }
        try ProofRender.write(view, size: CGSize(width: 300, height: 360), name: "notch-awake-menu")
        try ProofRender.write(view, size: CGSize(width: 300, height: 360), name: "notch-awake-menu-light", dark: false)
    }

    // MARK: Shelf

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func shelfMultiselect() throws {
        let (toy, store, _) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let tray = toy.cardModel.tray
        for entry in tray.entries { tray.remove(entry) }
        defer { tray.removeAll() }
        let urls = Self.files(["Screenshot 2026-09-24 at 10.12.png", "notes.md", "design-review.pdf",
                               "logo.png", "budget.numbers"])
        for url in urls {
            // One chip each: a single add of a file from the same folder
            // would stack with the one before it.
            tray.add([url], before: tray.entries.first)
            if case .stack = tray.entries.first { tray.dissolve(tray.entries.first!) }
        }
        let chips = tray.entries
        tray.toggleSelection(chips[0])
        tray.toggleSelection(chips[3])
        tray.actionNotice = "Compressed into Archive.zip"
        toy.cardModel.pinned = true
        toy.cardModel.contentRevealed = true
        toy.cardModel.show(.shelf)
        try Self.writeCard(toy, name: "notch-card-shelf-multiselect")

        // The chip's menu for that two-chip selection.
        let picked = tray.presentURLs(of: tray.targets(for: chips[0]))
        var rows: [MenuStill.Row] = ["Hand to review-patch", "Quick Look", "Reveal in Finder",
                                     "Send via AirDrop", "Share…"].map { MenuStill.Row(title: $0) }
        rows += ShelfActionMenu.verbs(for: picked).enumerated().map { index, verb in
            MenuStill.Row(title: ShelfActionMenu.title(verb, count: picked.count), divider: index == 0)
        }
        rows.append(MenuStill.Row(title: "Deselect All"))
        rows.append(MenuStill.Row(title: "Merge with Next", divider: true))
        rows.append(MenuStill.Row(title: ShelfActionMenu.removeTitle(count: picked.count)))
        rows.append(MenuStill.Row(title: "Clear Shelf"))
        let menu = ZStack(alignment: .topLeading) {
            ProofDesktop(dark: true)
            MenuStill(rows: rows, width: 230).padding(24)
        }
        try ProofRender.write(menu, size: CGSize(width: 280, height: 470), name: "notch-shelf-menu")
    }

    // MARK: Output picker

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func outputPicker() throws {
        let (toy, store, monitor) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        let speakers = CoreAudioOutputs.Device(id: 41, name: "MacBook Pro Speakers", transport: nil)
        let airpods = CoreAudioOutputs.Device(id: 77, name: "Jonathan's AirPods Pro",
                                              transport: kAudioDeviceTransportTypeBluetooth)
        let studio = CoreAudioOutputs.Device(id: 90, name: "Studio Display Speakers", transport: nil)
        model.utility.readOutputs = { ([airpods, speakers, studio], 77) }
        model.utility.watchOutputs = { _ in {} }
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "review-patch",
                                     word: "Working", clickSession: "claude:1")
        model.pinned = true
        model.contentRevealed = true
        model.utility.start()
        defer { model.utility.stop() }
        monitor.onChange?(NotchSurfaceRenderProofTests.media())
        model.show(.now)
        // The picker's menu: the devices, the one playing checked.
        let rows = model.utility.outputs.map {
            MenuStill.Row(title: $0.name, checked: $0.id == model.utility.defaultOutput)
        }
        try Self.writeCard(toy, name: "notch-card-now-output-picker",
                           extra: AnyView(MenuStill(rows: rows, width: 240)))
    }

    // MARK: Data Hoarder

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func hoarderFilters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-parity-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let entries: [(String, String, String, String)] = [
            ("pi-1", "pi", "Tidy the LED effect names", "/Users/jr/JR-Bar"),
            ("pi-2", "pi", "Port the comet to the Dot", "/Users/jr/SidePulse"),
            ("gem-1", "gemini", "Site copy pass", "/Users/jr/site"),
            ("grok-1", "grok", "Benchmark the parser", "/Users/jr/JR-Bar"),
        ]
        for (name, provider, title, project) in entries {
            let file = root.appending(path: "\(name).jsonl")
            try Data(#"{"type":"message","content":"\#(title)"}"#.utf8).write(to: file)
            let record = try await archive.importFile(file)
            try await archive.updateRecordMetadata(id: record.id, provider: provider, sessionID: "5f1c9a2e-\(name)",
                                                   project: project, title: title,
                                                   startedAt: Date().addingTimeInterval(-7200),
                                                   lastActivityAt: Date().addingTimeInterval(-3600))
        }
        // Imported through Find History with no source capturing: the
        // pi, Gemini and Grok records still get their own filter rows.
        // Nothing of this Mac's own transcripts is read.
        let model = DataHoarderModel(archive: archive)
        model.enabled = true
        await model.reload()
        model.searchFilter.provider = "pi"
        await model.runSearch()
        model.selectedID = model.searchResults.first?.record.id
        let menu = [MenuStill.Row(title: "All providers")]
            + model.providerChoices.map { MenuStill.Row(title: DataHoarderProviders.title($0), checked: $0 == "pi") }
        // The window's own background: the archive view draws on it.
        let view = HStack(alignment: .top, spacing: 0) {
            DataHoarderView(model: model).frame(width: 1040, height: 700)
            ZStack(alignment: .top) {
                Color(nsColor: .windowBackgroundColor)
                MenuStill(rows: menu, width: 200).padding(.top, 150)
            }
            .frame(width: 240, height: 700)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try await Self.writeLoaded(view, size: CGSize(width: 1280, height: 700),
                                       name: "hoarder-archive-filters\(dark ? "-dark" : "")", dark: dark,
                                       model: model)
        }
        // A Grok record: its CLI resumes, so the detail offers Resume and
        // the copyable line.
        model.searchFilter.provider = "grok"
        await model.runSearch()
        model.selectedID = model.searchResults.first?.record.id
        let resume = DataHoarderView(model: model).frame(width: 1040, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
        try await Self.writeLoaded(resume, size: CGSize(width: 1040, height: 520), name: "hoarder-record-resume",
                                   dark: false, model: model)
        await model.capture.stop()
    }

    /// The archive window as a still once it has loaded what it shows. Its
    /// own `.task`s fetch the storage line, the list, the preview and the
    /// detail when it appears, and they finish only while the test awaits
    /// — so it is hosted, waited on (at most 30 s) until nothing is
    /// loading, and then drawn.
    private static func writeLoaded<V: View>(_ view: V, size: CGSize, name: String, dark: Bool,
                                             model: DataHoarderModel) async throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        // Past the search's 200 ms debounce, so every load has begun.
        try await Task.sleep(nanoseconds: 400_000_000)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, model.preview.isEmpty || model.measuringStorage || model.searching
                || model.detailLoading || model.busy {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try png.write(to: ProofRender.directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Overview

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the parity PNGs"))
    func overviewWindowShare() throws {
        let store = OverviewStore(core: CoreModel())
        let session = CoreSession(id: "claude:session:a1", provider: "claude", label: "review-patch",
                                  cwd: "/Users/jr/JR-Bar", mode: "working", lifecycle: "active")
        let entry = CoreRosterEntry(session: session, schema: 1, visibility: "live")
        var mine = SessionUsage(provider: "claude", model: "claude-opus-5-5",
                                tokens: SessionUsageTokens(input: 120_000, cachedInput: 820_000, output: 60_000),
                                turns: 48, estimatedCostUSD: 3.84, contextTokens: 88_000, contextWindow: 200_000,
                                contextWindowSource: "reported")
        mine.windowTokens = 340_000
        var other = SessionUsage(provider: "claude")
        other.windowTokens = 660_000
        store.sessionUsage.apply(SessionUsageDocument(sessions: [session.id: mine, "claude:session:b2": other]),
                                 asked: [session.id, "claude:session:b2"])
        for dark in [false, true] {
            let view = OverviewSessionInspector(store: store, entry: entry) { _ in }
                .frame(width: 340, height: 620)
                .background(Color(nsColor: .windowBackgroundColor))
            try ProofRender.write(view, size: CGSize(width: 340, height: 620),
                                  name: "overview-inspector-window-share\(dark ? "-dark" : "")", dark: dark)
        }
    }
}
