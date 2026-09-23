import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the palette: the list, a selected row, tags, the
/// footer and the ⌘K panel at 2×, over a dark and a light backdrop, so
/// a human can eyeball the Raycast-grade layout. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write /tmp/palette-proof PNGs (or
/// `JRBAR_RENDER_PROOF_DIR` to pick the folder).
@Suite("Palette render proof")
@MainActor
struct PaletteRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func palette() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: env["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/palette-proof",
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let ask = CoreAsk(session: "claude:fix-ci", openedAt: now.timeIntervalSince1970 - 140,
                          summary: "Bash: npm test -- --runInBand", answerable: true, request: "r")
        let rows = [
            SessionRow(session: CoreSession(id: "claude:fix-ci", provider: "claude", label: "fix-ci",
                                            cwd: "/Users/me/src/jr-bar", mode: "waiting", ask: ask),
                       pinnedAsk: nil),
            SessionRow(session: CoreSession(id: "codex:docs", provider: "codex", label: "docs pass",
                                            cwd: "/Users/me/src/site", mode: "working",
                                            since: now.timeIntervalSince1970 - 900, tool: "Edit"),
                       pinnedAsk: nil),
        ]
        let noop = AgentPaletteVerbs(open: { _ in }, approve: { _ in }, deny: { _ in }, snooze: { _, _ in },
                                     copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        var items = AgentPaletteRows.items(rows: rows, now: now, verbs: noop)
        let bar = [
            MenuBarItem(id: "1p", ownerPID: 1, ownerName: "1Password",
                        bounds: CGRect(x: 600, y: 0, width: 24, height: 24), title: nil,
                        windowID: 0, bundleID: "com.1password.1password"),
            MenuBarItem(id: "ist", ownerPID: 2, ownerName: "iStat Menus",
                        bounds: CGRect(x: 640, y: 0, width: 24, height: 24), title: nil,
                        windowID: 0, bundleID: "com.bjango.istatmenus"),
        ]
        items += MenuBarCommands.build(items: bar, sections: ["ist": .hidden], concealing: true,
                                       ownBundleID: nil)
            .map { $0.paletteItem { _ in } }
        items += QuietPaletteRows.items(mode: "pause", quietLabel: nil, quietIsOurs: false, now: now,
                                        verbs: QuietPaletteVerbs(quiet: { _, _ in }, end: {}))
        items += ControlCenterPaletteRows.items(isOn: [.darkMode: true, .keepAwake: false],
                                                applying: []) { _ in }
        var usage = PaletteUsage()
        usage.record("quiet.1h", at: now)
        usage.record("system.darkMode", at: now)
        let shots: [(name: String, query: String, actions: Bool)] = [
            ("home", "", false), ("query", "hide 1p", false), ("actions", "", true),
        ]
        for shot in shots {
            let model = PaletteModel()
            model.load(items: items, usage: usage, now: now)
            model.query = shot.query
            if shot.actions { model.openActions() }
            for dark in [true, false] {
                let palette = PaletteView(model: model, prompt: "Search menu bar, sessions and commands…",
                                          onQueryChange: {}, onActivate: { _ in }, onRun: { _, _ in },
                                          onToggleActions: {}, snapshot: true)
                let view = ZStack {
                    Color(white: dark ? 0.16 : 0.93)
                    palette
                        .background(RoundedRectangle(cornerRadius: PalettePanel.cornerRadius)
                            .fill(Color(white: dark ? 0.21 : 0.98)))
                }
                .frame(width: PalettePanel.width + 40, height: PalettePanel.height + 40)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let png = try #require(rep.representation(using: .png, properties: [:]))
                let file = "palette-\(shot.name)-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(file))
            }
        }
    }
}
