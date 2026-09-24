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
        for (name, content) in shots {
            for dark in [true, false] {
                let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                try Self.write(view, glassRadius: content.metrics.panelRadius, name: name, dark: dark,
                               canvas: CGSize(width: 900, height: 460))
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
                try Self.write(DockSwitcherView(model: model), glassRadius: DockSwitcherPanel.cornerRadius,
                               name: name, dark: dark, canvas: CGSize(width: 1100, height: 520))
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
    static func icon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static var terminalIcon: NSImage {
        FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
            ? icon("/Applications/Ghostty.app") : icon("/System/Applications/Utilities/Terminal.app")
    }

    static func mark(_ id: String, provider: String, name: String, label: String,
                     activity: SessionActivity, fact: String? = nil, ask: CoreAsk? = nil) -> DockAgentMark {
        DockAgentMark(sessionID: id, provider: provider, providerName: name, label: label,
                      cwd: "/Users/jonathanreed/Downloads/JR-Bar", cwdTail: "Downloads/JR-Bar",
                      activity: activity, fact: fact, ask: ask,
                      hosts: ["com.mitchellh.ghostty"], tty: nil)
    }

    static let waitingAsk = CoreAsk(session: "claude:proof", openedAt: Date().timeIntervalSince1970 - 90,
                                    summary: "Bash: swift test --filter DockSwitcher",
                                    answerable: true, request: "request:v1:proof",
                                    preview: "swift test --filter DockSwitcher")

    static var waiting: DockAgentMark {
        mark("claude:proof", provider: "claude", name: "Claude", label: "polish the dock",
             activity: .waiting, ask: waitingAsk)
    }

    static var working: DockAgentMark {
        mark("codex:proof", provider: "codex", name: "Codex", label: "release notes",
             activity: .working, fact: "running Edit")
    }

    static func window(_ id: Int, _ title: String, still: NSImage? = nil,
                       minimized: Bool = false, fullScreen: Bool? = false) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, minimized: minimized, fullScreen: fullScreen,
                          frame: nil, thumbnail: still, element: nil)
    }

    static func terminalContent(large: Bool = false) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.largeCards = large
        content.appName = "Ghostty"
        content.icon = terminalIcon
        content.bundleID = "com.mitchellh.ghostty"
        content.isRunning = true
        content.windows = [
            window(1, "✳ polish the dock", still: Still.terminal(.waiting)),
            window(2, "release notes — codex", still: Still.terminal(.working)),
            window(3, "~/Downloads/JR-Bar — zsh", still: Still.terminal(.idle)),
        ]
        content.agents = [1: waiting, 2: working]
        content.appAgents = [waiting, working]
        content.selectedWindowID = 2
        return content
    }

    static func browserContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Safari"
        content.icon = icon("/Applications/Safari.app")
        content.bundleID = "com.apple.Safari"
        content.isRunning = true
        content.badge = "3"
        content.windows = [
            window(1, "Liquid Glass — Apple Developer", still: Still.browser(hue: 0.58)),
            window(2, "Raycast Store", still: Still.browser(hue: 0.02)),
            window(3, "Pull request #412 · jr-bar", still: Still.browser(hue: 0.75), minimized: true),
        ]
        return content
    }

    static func noStillsContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "T3 Code (Nightly)"
        content.icon = icon("/Applications/T3 Code (Nightly).app")
        content.bundleID = "com.t3.code"
        content.isRunning = true
        content.windows = [
            window(1, "JR-Bar — DockEnhancePanel.swift"),
            window(2, "notes.md", minimized: true),
        ]
        return content
    }

    static func compactContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Ghostty"
        content.icon = terminalIcon
        content.bundleID = "com.mitchellh.ghostty"
        content.isRunning = true
        content.compact = true
        let titles = ["✳ polish the dock", "release notes — codex", "~/Downloads/JR-Bar — zsh",
                      "htop", "ssh studio.local", "python3 -m http.server", "vim README.md",
                      "~/src/site — zsh", "tail -f daemon.log", "git log --oneline"]
        content.windows = titles.enumerated().map { index, title in
            window(index + 1, title, minimized: index == 6, fullScreen: index == 4 ? true : false)
        }
        content.agents = [1: waiting, 2: working]
        content.appAgents = [waiting, working]
        content.selectedWindowID = 3
        return content
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

    static func musicContent() -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = "Music"
        content.icon = icon("/System/Applications/Music.app")
        content.bundleID = "com.apple.Music"
        content.isRunning = true
        content.media = AlcoveMedia(title: "Nightcall", artist: "Kavinsky", album: "OutRun", playing: true,
                                    artworkData: Still.artwork(), bundleIdentifier: "com.apple.Music",
                                    duration: 258, elapsed: 97,
                                    timestamp: Date().timeIntervalSinceReferenceDate)
        content.windows = [window(1, "Music", still: Still.browser(hue: 0.95))]
        return content
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

/// Window stills drawn for the proof — a terminal running an agent, a
/// browser page — at a real window's proportions, so a card's
/// letterboxing and corners read as they would over a capture.
private enum Still {
    enum TerminalState { case waiting, working, idle }

    static func draw(_ size: CGSize, _ body: (CGRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        // Flip so drawing reads top-down like a window.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        body(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor,
                     weight: NSFont.Weight = .regular, mono: Bool = true) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.saveGraphicsState()
        // Text draws unflipped: undo the flip locally around the line.
        let cg = NSGraphicsContext.current!.cgContext
        cg.translateBy(x: point.x, y: point.y + size)
        cg.scaleBy(x: 1, y: -1)
        attributed.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func titleBar(_ rect: CGRect, dark: Bool, title: String) {
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: 28)).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 12 + CGFloat(index) * 20, y: 8, width: 12, height: 12)).fill()
        }
        text(title, at: CGPoint(x: rect.width / 2 - CGFloat(title.count) * 3.2, y: 7), size: 11,
             color: dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.3, alpha: 1),
             weight: .semibold, mono: false)
    }

    static func terminal(_ state: TerminalState) -> NSImage {
        draw(CGSize(width: 480, height: 300)) { rect in
            NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            titleBar(rect, dark: true, title: state == .idle ? "zsh" : "claude")
            let dim = NSColor(white: 0.55, alpha: 1)
            let body = NSColor(white: 0.88, alpha: 1)
            let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            var y: CGFloat = 40
            func line(_ string: String, _ color: NSColor, weight: NSFont.Weight = .regular) {
                text(string, at: CGPoint(x: 14, y: y), size: 10.5, color: color, weight: weight)
                y += 16
            }
            switch state {
            case .waiting:
                line("✳ polish the dock", orange, weight: .bold)
                line("⏺ Read(DockEnhancePanel.swift)", body)
                line("  ⎿  Read 1604 lines", dim)
                line("⏺ Bash(swift test --filter DockSwitcher)", body)
                y += 6
                NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.9).setStroke()
                let box = NSBezierPath(roundedRect: CGRect(x: 12, y: y, width: rect.width - 24, height: 92),
                                       xRadius: 6, yRadius: 6)
                box.lineWidth = 1
                box.stroke()
                y += 10
                text("Do you want to proceed?", at: CGPoint(x: 24, y: y), size: 10.5, color: body, weight: .semibold)
                y += 20
                text("❯ 1. Yes", at: CGPoint(x: 24, y: y), size: 10.5, color: orange)
                y += 16
                text("  2. Yes, and don't ask again for swift test", at: CGPoint(x: 24, y: y), size: 10.5, color: body)
                y += 16
                text("  3. No, and tell Claude what to do differently", at: CGPoint(x: 24, y: y), size: 10.5, color: body)
            case .working:
                line("codex  ›  release notes", NSColor(red: 0.2, green: 0.56, blue: 1, alpha: 1), weight: .bold)
                line("• Edited CHANGELOG.md (+42 -3)", body)
                line("• Ran git log --oneline v0.7..HEAD", body)
                line("  └ 431 commits", dim)
                line("• Editing docs/release-0.8.md", body)
                line("  ◦ Working (1m 12s · esc to interrupt)", dim)
            case .idle:
                line("~/Downloads/JR-Bar main ✓", NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1))
                line("❯ git status", body)
                line("On branch main", dim)
                line("nothing to commit, working tree clean", dim)
                line("❯ make test", body)
                line("  ✔ 1,842 tests passed in 41.2s", NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1))
                line("❯ ▍", body)
            }
        }
    }

    static func browser(hue: CGFloat) -> NSImage {
        draw(CGSize(width: 480, height: 312)) { rect in
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            titleBar(rect, dark: false, title: "")
            NSColor(white: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 140, y: 5, width: 200, height: 18), xRadius: 6, yRadius: 6).fill()
            NSColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 28, width: rect.width, height: 120)).fill()
            NSColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 32, y: 62, width: 200, height: 22), xRadius: 4, yRadius: 4).fill()
            NSColor(white: 1, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: CGRect(x: 32, y: 96, width: 140, height: 10), xRadius: 3, yRadius: 3).fill()
            for row in 0..<6 {
                NSColor(white: 0.82, alpha: 1).setFill()
                let width = rect.width - 64 - CGFloat((row * 37) % 90)
                NSBezierPath(roundedRect: CGRect(x: 32, y: 170 + CGFloat(row) * 20, width: width, height: 8),
                             xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    static func artwork() -> Data? {
        let image = draw(CGSize(width: 120, height: 120)) { rect in
            let gradient = NSGradient(colors: [NSColor(red: 0.95, green: 0.25, blue: 0.55, alpha: 1),
                                               NSColor(red: 0.25, green: 0.12, blue: 0.55, alpha: 1)])
            gradient?.draw(in: rect, angle: -60)
            NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 30, y: 44, width: 60, height: 60)).fill()
        }
        return image.tiffRepresentation
    }
}
