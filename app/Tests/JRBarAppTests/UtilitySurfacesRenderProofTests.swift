import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the utility surfaces people see: the Dock's preview
/// panel and ⌥⇥ switcher, the menu bar's Item Bar and layout editor, and
/// the Data Hoarder's archive and rebuilt timeline — each with realistic
/// fixtures (real app icons, drawn window stills, live agent marks), in
/// light and dark, over a desktop-like backdrop with a stand-in for the
/// glass the real panels float on. Rendered through `NSHostingView` and
/// `cacheDisplay`, so scroll views and buttons draw as themselves rather
/// than as ImageRenderer's placeholder. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`
/// (default `/tmp/jrbar-audit/utilities`).
@Suite("Utility surfaces render proof")
@MainActor
struct UtilitySurfacesRenderProofTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit/utilities", isDirectory: true)
    }

    // MARK: Always on

    /// The panel, the switcher and the Item Bar draw their fixtures
    /// without tripping — the proof shots below only run on request.
    @Test("the Dock preview, the switcher and the Item Bar render")
    func surfacesRender() throws {
        let preview = DockPreviewView(content: Fixtures.terminalContent(),
                                      actions: DockPreviewActions(content: Fixtures.terminalContent()))
        let switcher = DockSwitcherView(model: Fixtures.switcherModel(stills: true))
        let bar = MenuBarBarView(model: Fixtures.barModel(), tiles: MenuBarLiveTiles(),
                                 onTrigger: { _ in }, onRevealItem: { _ in },
                                 itemSection: { _ in .hidden }, onMoveItem: { _, _ in })
            .frame(width: 320, height: MenuBarBarLayout.contentSize(itemCount: 7).height)
        for view in [AnyView(preview), AnyView(switcher), AnyView(bar)] {
            let hosting = NSHostingView(rootView: view.fixedSize())
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 40 && hosting.fittingSize.height > 20)
        }
    }

    /// The panel sizes itself from its content: a compact list takes a
    /// row's width, not the screen's, and a strip of three stills fits
    /// under the panel's cap.
    @Test("the preview panel fits its content, compact or carded")
    func panelFits() {
        for content in [Fixtures.compactContent(), Fixtures.terminalContent()] {
            let panel = DockPreviewPanel(content: content)
            let size = panel.fittingSize()
            #expect(size.width >= 340 && size.width <= 720, "width \(size.width)")
            #expect(size.height > 120 && size.height < 560, "height \(size.height)")
        }
    }

    /// The fixtures the spacing proofs walk, by the name their PNGs take.
    private static let spacingFixtures: [(String, (Double) -> DockPreviewContent)] = [
        ("browser", { Fixtures.browserContent(spacing: $0) }),
        ("terminal", { Fixtures.terminalContent(spacing: $0) }),
        ("music", { Fixtures.musicContent(spacing: $0) }),
        ("compact", { Fixtures.compactContent(spacing: $0) }),
        ("nostills", { Fixtures.noStillsContent(spacing: $0) }),
    ]

    /// Tight is smaller than Standard and Standard than Roomy, both ways,
    /// for every face the panel wears.
    @Test("each spacing stop grows the panel both ways")
    func spacingOrdersThePanel() {
        for (name, make) in Self.spacingFixtures {
            let sizes = DockPreviewSpacing.allCases.map { DockPreviewPanel(content: make($0.scale)).fittingSize() }
            #expect(sizes[0].width < sizes[1].width && sizes[1].width < sizes[2].width, "\(name) widths \(sizes)")
            #expect(sizes[0].height < sizes[1].height && sizes[1].height < sizes[2].height, "\(name) heights \(sizes)")
        }
    }

    /// Standard is the panel people had before the knob, to the point;
    /// Tight is pinned where it measured, so a later padding drift trips
    /// here rather than on the Dock.
    @Test("Standard keeps the old size and Tight is pinned")
    func spacingPinsTheSizes() {
        let standard = DockPreviewPanel(content: Fixtures.browserContent(spacing: 1)).fittingSize()
        #expect(standard == CGSize(width: 496, height: 194), "Standard browser \(standard)")
        let tight = DockPreviewPanel(content: Fixtures.browserContent(spacing: 0.6)).fittingSize()
        #expect(tight == CGSize(width: 472, height: 165), "Tight browser \(tight)")
        let terminalStandard = DockPreviewPanel(content: Fixtures.terminalContent(spacing: 1)).fittingSize()
        let terminalTight = DockPreviewPanel(content: Fixtures.terminalContent(spacing: 0.6)).fittingSize()
        #expect(terminalStandard.width - terminalTight.width >= 16, "\(terminalStandard) vs \(terminalTight)")
        #expect(terminalStandard.height - terminalTight.height >= 20, "\(terminalStandard) vs \(terminalTight)")
        #expect(terminalTight == CGSize(width: 472, height: 247), "Tight terminal \(terminalTight)")
    }

    /// The key row reads its caps off the line the controller writes, a
    /// tool's node follows its name, and a yellow disc takes dark ink.
    @Test("key caps, tool glyphs and verb ink read what they are given")
    func chromeHelpers() {
        let caps = DockKeyHints.parse(DockSwitcherList.verbHints(appMode: false, drilled: true))
        #expect(caps.count == 6)
        #expect(caps.first?.key == "W" && caps.first?.word == "close")
        #expect(caps[2].key == "F" && caps[2].word == "full screen")
        #expect(caps.last?.key == "↑" && caps.last?.word == "apps")
        #expect(ReconstructedTimelineView.toolSymbol("Bash") == "terminal.fill")
        #expect(ReconstructedTimelineView.toolSymbol("apply_patch") == "pencil")
        #expect(ReconstructedTimelineView.toolSymbol(nil) == "wrench.and.screwdriver.fill")
        #expect(DockChrome.isLight(DockChrome.caution))
        #expect(!DockChrome.isLight(DockChrome.stop))
    }

    /// A window title as long as a browser tab's truncates in its row;
    /// it never pushes the compact panel wider than short titles do.
    @Test("a long window title never widens the compact list")
    func compactTitleKeepsWidth() {
        let short = DockPreviewPanel(content: Fixtures.compactContent()).fittingSize()
        let long = Fixtures.compactContent()
        long.windows[3] = Fixtures.window(4, String(repeating: "a very long page title ", count: 12))
        let widened = DockPreviewPanel(content: long).fittingSize()
        #expect(widened.width == short.width)
    }

    // MARK: Proof shots

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func dockPreviews() throws {
        let previous = AskAnswerDesk.shared
        AskAnswerDesk.shared = AskAnswerDesk(send: { _, _, _ in throw CoreClientError.notConnected })
        defer { AskAnswerDesk.shared = previous }
        let shots: [(String, DockPreviewContent)] = [
            ("dock-terminal", Fixtures.terminalContent()),
            ("dock-browser", Fixtures.browserContent()),
            ("dock-no-stills", Fixtures.noStillsContent()),
            ("dock-compact", Fixtures.compactContent()),
            ("dock-folder", Fixtures.folderContent()),
            ("dock-folder-denied", Fixtures.deniedFolderContent()),
            ("dock-music", Fixtures.musicContent()),
            ("dock-calendar", Fixtures.calendarContent()),
            ("dock-not-running", Fixtures.notRunningContent()),
            ("dock-large", Fixtures.terminalContent(large: true)),
        ]
        // The plain shots wear the default spacing — what a new install
        // shows; the stops below walk every face through all three.
        let defaultMetrics = DockPreviewMetrics.scaled(DockEnhanceSettings.defaultSpacing)
        for (name, content) in shots {
            content.metrics = defaultMetrics
            for dark in [true, false] {
                let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                try Self.write(view, glassRadius: content.metrics.panelRadius, name: name, dark: dark,
                               canvas: CGSize(width: 900, height: 460))
            }
        }
        for (name, make) in Self.spacingFixtures {
            for stop in DockPreviewSpacing.allCases {
                let content = make(stop.scale)
                for dark in [true, false] {
                    let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                    try Self.write(view, glassRadius: content.metrics.panelRadius,
                                   name: "dock-\(name)-\(stop.rawValue)", dark: dark,
                                   canvas: CGSize(width: 900, height: 480))
                }
            }
        }
        // Windows of three shapes: letterboxed in 16:10 boxes, then in
        // cards that take each window's shape.
        for (name, hug) in [("dock-shapes-fit", false), ("dock-shapes-hug", true)] {
            let content = DockPreviewSamples.shapes(hug: hug)
            for dark in [true, false] {
                let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                try Self.write(view, glassRadius: content.metrics.panelRadius, name: name, dark: dark,
                               canvas: CGSize(width: 900, height: 420))
            }
        }
        // Where the glass sits off a 55 pt tile, from the frame math:
        // covering the name bubble at the default 4 pt, and the classic
        // band that clears it.
        for (name, covers) in [("dock-placement-cover", true), ("dock-placement-classic", false)] {
            for dark in [true, false] {
                let sample = DockPreviewSample(spacing: DockEnhanceSettings.defaultSpacing,
                                               dockGap: DockEnhanceSettings.defaultDockGap,
                                               coversLabel: covers, scale: 1, showsMeasure: true)
                try Self.write(sample, glassRadius: nil, name: name, dark: dark,
                               canvas: DockPreviewSample.desk)
            }
        }
        // The card's sample at the stops and at the far gap, as Settings
        // draws it.
        for (name, spacing, gap) in [("dock-sample-tight", 0.6, 4.0), ("dock-sample-roomy", 1.4, 4.0),
                                     ("dock-sample-far", 0.6, 40.0)] {
            for dark in [true, false] {
                let sample = DockPreviewSample(spacing: spacing, dockGap: gap, coversLabel: true)
                try Self.write(sample, glassRadius: nil, name: name, dark: dark,
                               canvas: CGSize(width: 420, height: 260))
            }
        }
        // The hover faces a render never reaches by pointer: each verb
        // lit in its colour, beside the resting discs, over glass and
        // over a still.
        let verbs = VStack(spacing: 12) {
            HStack(spacing: 6) {
                DockRoundVerb(symbol: "plus", tint: DockChrome.go, label: "New window", lit: true) {}
                DockRoundVerb(symbol: "eye.slash", tint: DockChrome.caution, label: "Hide", lit: true) {}
                DockRoundVerb(symbol: "minus", tint: DockChrome.caution, label: "Minimise all", lit: true) {}
                DockRoundVerb(symbol: "xmark", tint: DockChrome.stop, label: "Close all", lit: true) {}
                DockRoundVerb(symbol: "power", tint: DockChrome.stop, label: "Quit", lit: true) {}
                DockRoundVerb(symbol: "folder", label: "Open in Finder", lit: true) {}
            }
            HStack(spacing: 6) {
                DockRoundVerb(symbol: "plus", label: "New window") {}
                DockRoundVerb(symbol: "eye.slash", label: "Hide") {}
                DockRoundVerb(symbol: "minus", label: "Minimise all") {}
                DockRoundVerb(symbol: "xmark", label: "Close all") {}
                DockRoundVerb(symbol: "power", label: "Quit") {}
                DockRoundVerb(symbol: "folder", label: "Open in Finder") {}
            }
            DockStill(image: Still.browser(hue: 0.58))
                .frame(width: 200, height: 130)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        DockRoundVerb(symbol: "xmark", tint: DockChrome.stop, label: "Close", size: 20,
                                      onStill: true, lit: true) {}
                        DockRoundVerb(symbol: "minus", tint: DockChrome.caution, label: "Minimize", size: 20,
                                      onStill: true, lit: true) {}
                        DockRoundVerb(symbol: "arrow.up.right.and.arrow.down.left", tint: DockChrome.go,
                                      label: "Full screen", size: 20, onStill: true) {}
                    }
                    .padding(6)
                }
        }
        .padding(14)
        for dark in [true, false] {
            try Self.write(verbs, glassRadius: DockPreviewMetrics.standard.panelRadius, name: "dock-verbs", dark: dark,
                           canvas: CGSize(width: 420, height: 320))
        }
        let toast = DockToastPanel.Model()
        toast.text = "Claude is working here — ⌘-right-click again to quit"
        for dark in [true, false] {
            try Self.write(DockToastView(model: toast), glassRadius: 12, name: "dock-toast", dark: dark,
                           canvas: CGSize(width: 520, height: 120))
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func switcher() throws {
        let shots: [(String, DockSwitcherModel)] = [
            ("switcher-stills", Fixtures.switcherModel(stills: true)),
            ("switcher-icons", Fixtures.switcherModel(stills: false)),
            ("switcher-search", Fixtures.switcherModel(stills: true, query: "saf")),
            ("switcher-latched", Fixtures.switcherModel(stills: false, latched: true)),
            ("switcher-armed", Fixtures.switcherModel(stills: true, armed: true)),
            ("switcher-hints", Fixtures.switcherModel(stills: true, hints: true)),
            ("switcher-nomatch", Fixtures.switcherModel(stills: true, query: "zzz")),
        ]
        for (name, model) in shots {
            for dark in [true, false] {
                try Self.write(DockSwitcherView(model: model), glassRadius: model.metrics.cornerRadius,
                               name: name, dark: dark, canvas: CGSize(width: 1100, height: 520))
            }
        }
        // The strip at the spacing stops it shares with the preview.
        for stop in [DockPreviewSpacing.tight, .standard] {
            let model = Fixtures.switcherModel(stills: true)
            model.metrics = DockSwitcherMetrics.scaled(stop.scale)
            for dark in [true, false] {
                try Self.write(DockSwitcherView(model: model), glassRadius: model.metrics.cornerRadius,
                               name: "switcher-stills-\(stop.rawValue)", dark: dark,
                               canvas: CGSize(width: 1100, height: 520))
            }
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func itemBar() async throws {
        let tiles = MenuBarLiveTiles()
        let live = Fixtures.barItems.prefix(2)
        tiles.itemsProvider = { Array(live) }
        tiles.rowRects = { [CGRect(x: 0, y: 0, width: 3000, height: 24)] }
        tiles.capture = { rect in Fixtures.liveCapture(width: rect.width) }
        await tiles.refreshOnce()
        let shots: [(String, MenuBarBarModel)] = [
            ("itembar", Fixtures.barModel()),
            ("itembar-keyboard", Fixtures.barModel(query: "", selection: 2)),
            ("itembar-filtered", Fixtures.barModel(query: "vpn", selection: 0)),
            ("itembar-empty", MenuBarBarModel()),
        ]
        for (name, model) in shots {
            for dark in [true, false] {
                let widths = model.rowWidths(liveWidths: tiles.imageWidths)
                let size = model.items.isEmpty
                    ? MenuBarBarLayout.contentSize(itemCount: 0)
                    : MenuBarBarLayout.contentSize(widths: widths)
                let view = MenuBarBarView(model: model, tiles: tiles,
                                          onTrigger: { _ in }, onRevealItem: { _ in },
                                          itemSection: { _ in .hidden }, onMoveItem: { _, _ in })
                    .frame(width: size.width, height: size.height)
                try Self.write(view, glassRadius: MenuBarBarPanel.cornerRadius, name: name, dark: dark,
                               canvas: CGSize(width: max(size.width + 80, 360), height: size.height + 70))
            }
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func layoutEditor() throws {
        let subjects = Fixtures.barItems.map {
            MenuBarProfileSubject(key: $0.bundleID ?? $0.id, isApp: $0.bundleID != nil,
                                  title: $0.ownerName, item: $0)
        }
        let sections: [String: MenuBarItemSection] = [
            "istat": .shown, "weather": .shown, "vpn": .hidden, "tailscale": .hidden,
            "dropover": .hidden, "shottr": .hidden, "bt": .shown,
        ]
        let faces = Fixtures.barModel().glyphs
        for (name, fill) in [("layout-editor", true), ("layout-editor-empty", false)] {
            let source = MenuBarLayoutEditorView.Source(
                subjects: { subjects },
                section: { fill ? sections[$0.id] ?? .shown : ($0.id == "vpn" ? .hidden : .shown) },
                setSection: { _, _ in },
                face: { faces[$0.id] })
            let view = MenuBarLayoutEditorView(source: source, placement: { _ in "hidden" })
                .padding(16)
                .frame(width: 520)
            for dark in [true, false] {
                try Self.write(view, glassRadius: nil, name: name, dark: dark,
                               canvas: CGSize(width: 520, height: 160), window: true)
            }
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func timeline() throws {
        let view = ReconstructedTimelineView(reconstruction: Fixtures.reconstruction(),
                                             viewState: ReconstructedTimelineViewState())
            .padding(16)
            .frame(width: 560, height: 860)
        for dark in [true, false] {
            try Self.write(view, glassRadius: nil, name: "timeline", dark: dark,
                           canvas: CGSize(width: 600, height: 900), window: true)
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func dataHoarder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-proof-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, mode) in [("hoarder-timeline", DataHoarderModel.DetailMode.timeline),
                             ("hoarder-contents", .contents)] {
            let model = Fixtures.hoarderModel(root: root)
            model.detailMode = mode
            let view = DataHoarderView(model: model).frame(width: 1040, height: 700)
            for dark in [true, false] {
                try Self.write(view, glassRadius: nil, name: name, dark: dark,
                               canvas: CGSize(width: 1040, height: 700), window: true)
            }
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the utility PNGs"))
    func hoarderSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-proof-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Fixtures.hoarderModel(root: root)
        let now = Date()
        func inventory(_ id: String, _ name: String, _ path: String, files: Int,
                       warnings: [String] = []) -> ArchiveSourceInventory {
            ArchiveSourceInventory(
                source: ArchiveSource(id: id, name: name, root: URL(fileURLWithPath: NSHomeDirectory() + path),
                                      extensions: ["jsonl"]),
                files: (0..<files).map { index in
                    ArchiveSourceFile(url: URL(fileURLWithPath: "/tmp/\(id)-\(index).jsonl"),
                                      byteCount: Int64(120_000 * (index + 1)),
                                      modifiedAt: now.addingTimeInterval(-Double(index) * 86_400 * 3))
                },
                warnings: warnings)
        }
        model.sourceInventories = [
            inventory("claude-projects", "Claude Code", "/.claude/projects", files: 14),
            inventory("codex-sessions", "Codex", "/.codex/sessions", files: 6),
            inventory("gemini-chats", "Gemini CLI", "/.gemini/tmp", files: 0,
                      warnings: ["Some files could not be read"]),
        ]
        model.selectedSources = ["claude-projects"]
        for dark in [true, false] {
            try Self.write(DataHoarderSourcesView(model: model), glassRadius: nil, name: "hoarder-sources",
                           dark: dark, canvas: CGSize(width: 630, height: 480), window: true)
        }
    }

    // MARK: Staging

    /// Writes `view` over the proof backdrop: a desktop-like wash, and —
    /// for a floating panel — a stand-in for its glass at `glassRadius`.
    /// A `window` view fills the canvas on the window background instead.
    private static func write(_ view: some View, glassRadius: CGFloat?, name: String, dark: Bool,
                              canvas: CGSize = CGSize(width: 820, height: 460),
                              window: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = ZStack {
            if window {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ProofWallpaper(dark: dark)
            }
            if let glassRadius {
                view.fixedSize()
                    .background(SurfaceProofGlass(radius: glassRadius, dark: dark))
            } else {
                view
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: staged)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: canvas)
        let proofWindow = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        proofWindow.appearance = hosting.appearance
        proofWindow.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = canvas
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// A desktop-like backdrop: the wash a glass panel floats over.
private struct ProofWallpaper: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark
                           ? [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.24, green: 0.12, blue: 0.30)]
                           : [Color(red: 0.62, green: 0.74, blue: 0.93), Color(red: 0.93, green: 0.76, blue: 0.80)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [dark ? Color(red: 0.20, green: 0.36, blue: 0.62) : Color(red: 0.98, green: 0.88, blue: 0.62),
                                    .clear],
                           center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: 420)
        }
    }
}

/// A stand-in for the regular Liquid Glass a floating panel wears: a
/// frosted fill over the wash, a hairline rim and a soft shadow.
private struct SurfaceProofGlass: View {
    let radius: CGFloat
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(dark ? Color(white: 0.13).opacity(0.78) : Color(white: 0.98).opacity(0.72))
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.16 : 0.55), lineWidth: 0.75))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 18, y: 8)
    }
}

// MARK: - Fixtures

@MainActor
private enum Fixtures {
    // The Dock preview's fixtures live with the card's live sample
    // (`DockPreviewSamples`), so the proofs and Settings draw the same.
    static func icon(_ path: String) -> NSImage { DockPreviewSamples.icon(path) }
    static var terminalIcon: NSImage { DockPreviewSamples.terminalIcon }
    static var waiting: DockAgentMark { DockPreviewSamples.waiting }
    static var working: DockAgentMark { DockPreviewSamples.working }

    static func window(_ id: Int, _ title: String, still: NSImage? = nil,
                       minimized: Bool = false, fullScreen: Bool? = false) -> DockPreviewWindow {
        DockPreviewSamples.window(id, title, still: still, minimized: minimized, fullScreen: fullScreen)
    }

    static func terminalContent(large: Bool = false, spacing: Double = 1) -> DockPreviewContent {
        DockPreviewSamples.terminal(large: large, spacing: spacing)
    }

    static func browserContent(spacing: Double = 1) -> DockPreviewContent {
        DockPreviewSamples.browser(spacing: spacing)
    }

    static func noStillsContent(spacing: Double = 1) -> DockPreviewContent {
        DockPreviewSamples.noStills(spacing: spacing)
    }

    static func compactContent(spacing: Double = 1) -> DockPreviewContent {
        DockPreviewSamples.compact(spacing: spacing)
    }

    static func folderContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Downloads"
        content.icon = icon(NSHomeDirectory() + "/Downloads")
        content.folderURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        content.folderState = .ready
        let files: [(String, UTType, Bool)] = [
            ("Screenshot 2026-09-24 at 01.12.40.png", .png, false), ("JR-Bar", .folder, true),
            ("invoice-0924.pdf", .pdf, false), ("Ghostty.dmg", .diskImage, false),
            ("wallpapers", .folder, true), ("notes.txt", .plainText, false),
            ("export.zip", .zip, false), ("clip.mov", .quickTimeMovie, false),
        ]
        content.folderEntries = files.enumerated().map { index, file in
            DockFolderEntry(id: index, name: file.0,
                            url: URL(fileURLWithPath: "/tmp/proof/\(file.0)"),
                            icon: NSWorkspace.shared.icon(for: file.1), isDirectory: file.2)
        }
        return content
    }

    static func deniedFolderContent() -> DockPreviewContent {
        let content = folderContent()
        content.folderEntries = []
        content.folderState = .denied
        return content
    }

    static func musicContent(spacing: Double = 1) -> DockPreviewContent {
        DockPreviewSamples.music(spacing: spacing)
    }

    static func calendarContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Calendar"
        content.icon = icon("/System/Applications/Calendar.app")
        content.bundleID = "com.apple.iCal"
        content.isRunning = true
        let now = Date()
        content.calendarFreeUntil = now.addingTimeInterval(40 * 60)
        content.calendarEvents = [
            ShelfCalendarModel.Event(title: "Design review", start: now.addingTimeInterval(40 * 60),
                                     end: now.addingTimeInterval(70 * 60),
                                     url: URL(string: "https://zoom.us/j/1")),
            ShelfCalendarModel.Event(title: "Lunch with Maya", start: now.addingTimeInterval(3 * 3600),
                                     end: now.addingTimeInterval(4 * 3600), url: nil),
        ]
        return content
    }

    static func notRunningContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Slack"
        content.icon = icon("/Applications/Slack.app")
        content.bundleID = "com.tinyspeck.slackmacgap"
        content.isRunning = false
        return content
    }

    // MARK: Switcher

    static func switcherModel(stills: Bool, query: String = "", latched: Bool = false,
                              armed: Bool = false, hints: Bool = false) -> DockSwitcherModel {
        let model = DockSwitcherModel()
        var waitingItem = SwitcherItem(id: "w1", pid: 1, appName: "Ghostty", icon: terminalIcon,
                                       title: "✳ polish the dock", minimized: false, onScreen: true,
                                       element: nil, windowID: 11)
        waitingItem.agent = waiting
        var workingItem = SwitcherItem(id: "w2", pid: 1, appName: "Ghostty", icon: terminalIcon,
                                       title: "release notes — codex", minimized: false, onScreen: true,
                                       element: nil, windowID: 12)
        workingItem.agent = working
        var mail = SwitcherItem(id: "w4", pid: 3, appName: "Mail", icon: icon("/System/Applications/Mail.app"),
                                title: "Inbox — 3 unread", minimized: false, onScreen: true,
                                element: nil, windowID: 14)
        mail.badge = "3"
        let all = [
            waitingItem,
            SwitcherItem(id: "w3", pid: 2, appName: "Safari", icon: icon("/Applications/Safari.app"),
                         title: "Liquid Glass — Apple Developer", minimized: false, onScreen: true,
                         element: nil, windowID: 13),
            workingItem,
            mail,
            SwitcherItem(id: "w5", pid: 4, appName: "Notes", icon: icon("/System/Applications/Notes.app"),
                         title: "Overnight plan", minimized: true, onScreen: false,
                         element: nil, windowID: 15),
            SwitcherItem(id: "w6", pid: 5, appName: "Finder", icon: icon("/System/Library/CoreServices/Finder.app"),
                         title: "Downloads", minimized: false, onScreen: false,
                         element: nil, windowID: 16),
        ]
        model.items = query.isEmpty ? all : all.filter { $0.appName.lowercased().hasPrefix(query) }
        model.selection = query.isEmpty ? 1 : 0
        model.query = query
        model.latched = latched
        if stills {
            model.thumbnails = [
                "w1": Still.terminal(.waiting), "w2": Still.terminal(.working),
                "w3": Still.browser(hue: 0.58), "w4": Still.browser(hue: 0.6),
                "w5": Still.browser(hue: 0.13),
            ]
        }
        if armed {
            model.armedID = "w1"
            model.armedAccent = waiting.accent
            model.armedNote = "Claude is waiting on you here — ⌘W again to close"
        }
        if hints {
            model.hints = DockSwitcherList.verbHints(appMode: false, drilled: false)
        }
        return model
    }

    // MARK: Item Bar

    static let barItems: [MenuBarItem] = [
        MenuBarItem(id: "istat", ownerPID: 11, ownerName: "iStat Menus",
                    bounds: CGRect(x: 1200, y: 0, width: 58, height: 24), title: "CPU",
                    windowID: 1, bundleID: "com.bjango.istatmenus"),
        MenuBarItem(id: "weather", ownerPID: 12, ownerName: "Weather",
                    bounds: CGRect(x: 1250, y: 0, width: 40, height: 24), title: "72°",
                    windowID: 2, bundleID: "com.apple.weather.menu"),
        MenuBarItem(id: "vpn", ownerPID: 13, ownerName: "ProtonVPN",
                    bounds: CGRect(x: 4000, y: 0, width: 24, height: 24), title: "VPN",
                    windowID: 3, bundleID: "ch.protonvpn.mac"),
        MenuBarItem(id: "tailscale", ownerPID: 14, ownerName: "Tailscale",
                    bounds: CGRect(x: 4030, y: 0, width: 24, height: 24), title: nil,
                    windowID: 4, bundleID: "io.tailscale.ipn.macos"),
        MenuBarItem(id: "dropover", ownerPID: 15, ownerName: "Dropover",
                    bounds: CGRect(x: 4060, y: 0, width: 24, height: 24), title: nil,
                    windowID: 5, bundleID: "me.damir.dropover-mac"),
        MenuBarItem(id: "shottr", ownerPID: 16, ownerName: "Shottr",
                    bounds: CGRect(x: 4090, y: 0, width: 24, height: 24), title: nil,
                    windowID: 6, bundleID: "cc.ffitch.shottr"),
        MenuBarItem(id: "bt", ownerPID: 17, ownerName: "Bluetooth",
                    bounds: CGRect(x: 4120, y: 0, width: 24, height: 24), title: nil,
                    windowID: 7, bundleID: nil),
    ]

    static func barModel(query: String? = nil, selection: Int = 0) -> MenuBarBarModel {
        let model = MenuBarBarModel()
        model.items = barItems
        model.parkedIDs = ["bt"]
        model.glyphs = [
            "vpn": glyph("lock.shield.fill"),
            "tailscale": glyph("point.3.filled.connected.trianglepath.dotted"),
            "dropover": glyph("tray.and.arrow.down.fill"),
        ]
        model.updatedIDs = ["tailscale"]
        if let query { model.keys = MenuBarBarKeys.State(query: query, selection: selection) }
        return model
    }

    static func glyph(_ symbol: String) -> MenuBarGlyphCache.Face {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return MenuBarGlyphCache.Face(image: image, width: max(18, image.size.width + 4), template: true)
    }

    /// A live capture of a menu bar item: its glyph drawn in the bar's
    /// white on the bar's dark row, as a capture of the real row lands.
    static func liveCapture(width: CGFloat) -> CGImage? {
        let scale: CGFloat = 2
        let size = CGSize(width: width, height: 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let text = width > 42 ? "CPU 12%" : "72°"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2,
                                            y: (size.height - measured.height) / 2),
                                withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: Data Hoarder

    static func reconstruction() -> SessionReconstruction {
        let start = Date().timeIntervalSince1970 - 1800
        var seq = 0
        func item(_ offset: Double, _ kind: ReconstructedItem.Kind, role: String? = nil,
                  name: String? = nil, error: Bool = false, text: String? = nil,
                  model: String? = nil, sidechain: Bool = false) -> ReconstructedItem {
            seq += 1
            return ReconstructedItem(seq: seq, at: start + offset, kind: kind, role: role, name: name,
                                     isError: error, sidechain: sidechain, text: text, model: model)
        }
        let items = [
            item(0, .message, role: "user", text: "Polish the Dock previews — continuous corners, calmer type."),
            item(8, .message, role: "assistant",
                 text: "I'll start by rendering a baseline of the preview panel, then work through the cards.",
                 model: "claude-opus-5-5"),
            item(12, .toolUse, name: "Read", text: "app/Sources/JRBarApp/Utilities/Dock/DockEnhancePanel.swift"),
            item(13, .toolResult, text: "1604 lines"),
            item(40, .toolUse, name: "Bash", text: "swift build --build-tests"),
            item(95, .toolResult, error: true,
                 text: "error: cannot find 'DockCardFace' in scope\n  --> DockEnhancePanel.swift:731:13"),
            item(120, .toolUse, name: "Task", text: "Survey the switcher's drawing code", sidechain: true),
            item(160, .toolResult, text: "Found 3 views", sidechain: true),
            item(210, .message, role: "assistant", text: "The build failed on a missing type — fixing the rename.",
                 model: "claude-opus-5-5"),
            item(260, .turnEnd, name: "end_turn"),
        ]
        let story = FailureStory(failed: true, errorCount: 1,
                                 lastErrorSummary: "cannot find 'DockCardFace' in scope",
                                 diedMidTurn: false,
                                 lastUserIntent: "Polish the Dock previews — continuous corners, calmer type.",
                                 failedToolNames: ["Bash"], failingTurnSeconds: 95)
        let request = CLIProxyRequest(timestamp: Date(timeIntervalSince1970: start + 30), method: "POST",
                                      path: "/v1/messages", client: "claude-cli/2.1.222",
                                      sessionID: "proof", model: "claude-opus-5-5", status: 529,
                                      upstreamURL: "api.anthropic.com/v1/messages", attemptCount: 2,
                                      errorSummary: "HTTP 529 overloaded_error")
        return SessionReconstruction(items: items, story: story, gaps: ["malformed_lines:2"],
                                     totalLines: 184, redactedLines: 0, proxyRequests: [request])
    }

    static func hoarderModel(root: URL) -> DataHoarderModel {
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.enabled = true
        let now = Date()
        func record(_ id: String, _ title: String?, provider: String?, project: String?,
                    hours: Double, bytes: Int64, state: CaptureState, segments: Int = 12) -> ArchiveRecord {
            ArchiveRecord(id: id, name: "\(id).jsonl",
                          sourcePath: NSHomeDirectory() + "/.claude/projects/-Users-jr-JR-Bar/\(id).jsonl",
                          byteCount: bytes, importedAt: now.addingTimeInterval(-hours * 3600),
                          sourceModifiedAt: now, provider: provider, sessionID: "5f1c9a2e-\(id)",
                          project: project, model: "claude-opus-5-5", title: title,
                          startedAt: now.addingTimeInterval(-hours * 3600 - 1800),
                          lastActivityAt: now.addingTimeInterval(-hours * 3600),
                          segmentCount: segments, captureState: state)
        }
        model.records = [
            record("a1", "Polish the Dock previews", provider: "claude", project: "/Users/jr/JR-Bar",
                   hours: 0.2, bytes: 1_240_000, state: .live),
            record("a2", "Release notes for 0.8", provider: "codex", project: "/Users/jr/JR-Bar",
                   hours: 5, bytes: 420_000, state: .closed),
            record("a3", "Fix the Screen Bar ears", provider: "claude", project: "/Users/jr/JR-Bar",
                   hours: 26, bytes: 2_900_000, state: .gap),
            record("a4", nil, provider: "other", project: nil, hours: 50, bytes: 88_000, state: .snapshot),
            record("a5", "Site copy pass", provider: "gemini", project: "/Users/jr/site",
                   hours: 80, bytes: 310_000, state: .closed),
        ]
        model.selectedID = "a1"
        model.detailKind = .transcript
        model.reconstruction = reconstruction()
        model.preview = """
        {"type":"user","message":{"role":"user","content":"Polish the Dock previews"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text"}]}}
        """
        model.storageUsage = ArchiveStorageUsage(recordCount: 5, contentBytes: 4_958_000,
                                                 allocatedBytes: 5_300_000, trashedRecordCount: 1,
                                                 trashedContentBytes: 12_000)
        return model
    }
}

// MARK: - Drawn window stills

/// The drawn stills the Dock samples use — a terminal running an
/// agent, a browser page — shared with the card's live sample.
private typealias Still = DockSampleStill
