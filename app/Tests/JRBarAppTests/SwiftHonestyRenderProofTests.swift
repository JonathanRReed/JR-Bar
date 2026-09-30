import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Pictures of the three places that now say what the daemon means: the
/// Overview inspector, the palette's ask rows and the Rail's pill, each with
/// an open ask, an answered one and one that cannot be answered from here
/// side by side. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `honesty-*.png` into `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Swift honesty render proof", .serialized)
@MainActor
struct SwiftHonestyRenderProofTests {
    private typealias Fixture = DecidedAskFixture
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The ask as it would read a moment after it opened.
    private static func justOpened(_ ask: CoreAsk) -> CoreAsk {
        var fresh = ask
        let now = Date().timeIntervalSince1970
        fresh.openedAt = now - 75
        fresh.decision?.holdUntil = now + 30
        return fresh
    }

    private static let sealed = CoreAsk(session: Fixture.session, kind: "permission",
                                        openedAt: Date().timeIntervalSince1970 - 75, summary: "Edit the release notes",
                                        answerable: false, request: "r-sealed", preview: "notes/0.8.md")

    // MARK: Overview

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func overviewInspector() throws {
        let store = OverviewStore(core: CoreModel())
        let cases: [(name: String, ask: CoreAsk)] = [
            ("open", Self.justOpened(Fixture.openAsk())),
            ("answered", Self.justOpened(Fixture.decidedAsk())),
            ("answered-older-daemon", Self.justOpened(Fixture.olderDaemonDecidedAsk())),
            ("sealed", Self.sealed),
        ]
        for shot in cases {
            let session = CoreSession(id: Fixture.session, provider: "claude", label: "release cleanup",
                                      cwd: "/Users/jr/JR-Bar", mode: "waiting", lifecycle: "active", ask: shot.ask)
            let entry = CoreRosterEntry(session: session, schema: 1, pinned: true, visibility: "live")
            for dark in [true, false] {
                let view = OverviewSessionInspector(store: store, entry: entry) { _ in }
                    .frame(width: 340, height: 400, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(view, size: CGSize(width: 340, height: 400),
                                      name: "honesty-overview-\(shot.name)-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    // MARK: Palette

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func paletteAskRows() throws {
        let now = Date()
        func row(_ id: String, _ label: String, _ ask: CoreAsk) -> SessionRow {
            var pinned = ask
            pinned.session = id
            return SessionRow(session: CoreSession(id: id, provider: "claude", label: label,
                                                   cwd: "/Users/jr/JR-Bar", mode: "waiting",
                                                   since: now.timeIntervalSince1970 - 90, ask: pinned),
                              pinnedAsk: nil)
        }
        let rows = [
            row("claude:open", "run the tests", Self.justOpened(Fixture.openAsk())),
            row("claude:answered", "clear the build folder", Self.justOpened(Fixture.decidedAsk())),
            row("claude:older", "same, older daemon", Self.justOpened(Fixture.olderDaemonDecidedAsk())),
            row("claude:sealed", "edit the notes", Self.sealed),
        ]
        let noop = AgentPaletteVerbs(open: { _ in }, approve: { _ in }, deny: { _ in }, snooze: { _, _ in },
                                     copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        let items = AgentPaletteRows.items(rows: rows, now: now, verbs: noop)
        for dark in [true, false] {
            let model = PaletteModel()
            model.load(items: items, usage: PaletteUsage(), now: now)
            let palette = PaletteView(model: model, prompt: "Search menu bar, sessions and commands…",
                                      onQueryChange: {}, onActivate: { _ in }, onRun: { _, _ in },
                                      onToggleActions: {}, snapshot: true)
            let view = ZStack {
                Color(white: dark ? 0.16 : 0.93)
                palette
                    .background(RoundedRectangle(cornerRadius: PalettePanel.cornerRadius)
                        .fill(Color(white: dark ? 0.21 : 0.98)))
            }
            .frame(width: PalettePanel.width + 40, height: 300)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory.appendingPathComponent("honesty-palette-\(dark ? "dark" : "light").png"))
        }
    }

    // MARK: Rail

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func railPills() throws {
        let desk = Fixture.loggingDesk(Fixture.SentLog())
        let slot = DeckSlot(index: 0, identity: "key-0", session: Fixture.session, state: .inputRequired)
        func pill(_ ask: CoreAsk, key: String) -> some View {
            let core = CoreModel()
            core.apply(.state(Fixture.state(holding: ask)))
            let store = DeckStore(core: core)
            return RailLabelView(title: "release cleanup", subtitle: store.railSubtitle(for: slot),
                                 provider: "claude", number: key, detail: ask.summary,
                                 ask: store.ask(for: slot), desk: desk)
                .background(ProofGlass(cornerRadius: 9))
        }
        for dark in [true, false] {
            let canvas = CGSize(width: 420, height: 340)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                VStack(alignment: .leading, spacing: 18) {
                    pill(Self.justOpened(Fixture.openAsk()), key: "1")
                    pill(Self.justOpened(Fixture.decidedAsk()), key: "2")
                    pill(Self.justOpened(Fixture.olderDaemonDecidedAsk()), key: "3")
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "honesty-rail-\(dark ? "dark" : "light")", dark: dark)
        }
    }
}
