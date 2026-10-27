import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
import JRBarCore

/// Render proof for the position model's card: the diagram (Hidden, the
/// icon as the divider, Shown), the suggestions panel, and every banner
/// the divider can show. Off by default; `JRBAR_RENDER_PROOF=1` writes
/// PNGs into `JRBAR_RENDER_PROOF_DIR` (default /tmp/jrbar-audit/menubar).
@Suite("Menu Bar position render proof")
@MainActor
struct MenuBarPositionRenderProofTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit/menubar", isDirectory: true)
    }

    private static func item(_ name: String, x: Double, y: Double = 4) -> MenuBarItem {
        var item = MenuBarItem(id: name, ownerPID: 500, ownerName: name,
                               bounds: CGRect(x: x, y: y, width: 28, height: 24), title: nil, windowID: 1)
        item.bundleID = "synthetic.\(name.lowercased())"
        return item
    }

    private static func write(_ view: some View, named name: String, dark: Bool, size: CGSize) throws {
        let staged = view
            .padding(16)
            .frame(width: size.width, alignment: .topLeading)
            .background(Color(nsColor: dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: staged)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: nil)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("render failed for \(name)")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private static var content: MenuBarPositionContent {
        var plan = MenuBarHidePlan()
        plan.hidden = ["Shottr", "Cotypist", "Ollama", "Claude", "Adobe", "cmux", "Defender"]
            .enumerated().map { item($1, x: 880 + Double($0) * 30) }
        plan.shown = [item("ChatGPT", x: 1080), item("Weather", x: 1130), item("Passwords", x: 1190)]
        plan.alwaysHidden = [item("Tailscale", x: 870)]
        return MenuBarPositionContent.make(plan: plan, rows: [CGRect(x: 0, y: 0, width: 1512, height: 33)])
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the position PNGs"))
    func diagram() throws {
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 10) {
                Text(MenuBarPositionCopy.model).font(.callout).foregroundStyle(.secondary)
                MenuBarPositionDiagram(content: Self.content)
                CardNote(MenuBarPositionCopy.remainder(count: 2), symbol: "tray.full")
                CardNote(MenuBarPositionCopy.engineExplanation, symbol: "gearshape.2")
                Divider()
                Text("Nothing hidden yet").font(.caption).foregroundStyle(.secondary)
                MenuBarPositionDiagram(content: MenuBarPositionContent.make(
                    plan: {
                        var plan = MenuBarHidePlan()
                        plan.shown = [Self.item("ChatGPT", x: 1080), Self.item("Weather", x: 1130)]
                        return plan
                    }(), rows: [CGRect(x: 0, y: 0, width: 1512, height: 33)]))
            }
            try Self.write(view, named: "position-diagram", dark: dark, size: CGSize(width: 560, height: 0))
        }
    }

    @Test(.enabled(if: Self.enabled))
    func savedAppNames() async throws {
        let names = MenuBarAppNames()
        names.lookup = { identity in
            identity == "test.sample-writer" ? "Sample Writer" : "Sample Flow (not installed)"
        }
        for identity in ["test.sample-writer", "test.sample-flow"] {
            _ = await names.resolvedName(for: identity)
        }
        let content = MenuBarSuggestionsContent.make(
            suggestions: ["test.sample-writer", "test.sample-flow"], plan: MenuBarHidePlan()
        ) { names.name(for: $0) }
        for dark in [false, true] {
            try Self.write(MenuBarSuggestionsPanel(content: content), named: "saved-app-names",
                           dark: dark, size: CGSize(width: 560, height: 0))
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the suggestions PNGs"))
    func suggestions() throws {
        var plan = MenuBarHidePlan()
        plan.shown = [Self.item("Cmux", x: 1000), Self.item("Adobe", x: 1030), Self.item("Typeless", x: 1060)]
        plan.hidden = [Self.item("Shottr", x: 900)]
        let names = ["synthetic.shottr": "Shottr", "synthetic.cmux": "cmux", "synthetic.adobe": "Adobe",
                     "synthetic.typeless": "Typeless", "synthetic.tailscale": "Tailscale"]
        let content = MenuBarSuggestionsContent.make(
            suggestions: Array(names.keys), plan: plan) { names[$0] ?? $0 }
        let readout = MenuBarDividerReadout.make(.init(
            standing: true, iconFrame: CGRect(x: 952, y: 4, width: 30, height: 24), spacer: 79,
            fitEdge: 903, fitEdgeLearned: false, hidden: 4, shown: 6, parked: 2,
            room: .holds, lastChange: "Typeless moved left of the icon: hidden"))
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 12) {
                MenuBarDividerHint()
                MenuBarSuggestionsPanel(content: content)
                CardNote(MenuBarPositionCopy.engineExplanation, symbol: "gearshape.2")
                MenuBarDividerReadoutView(readout: readout)
            }
            try Self.write(view, named: "position-suggestions", dark: dark, size: CGSize(width: 560, height: 0))
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the banner PNGs"))
    func banners() throws {
        var inputs: [MenuBarHidingStatus.Inputs] = []
        func add(_ edit: (inout MenuBarHidingStatus.Inputs) -> Void) {
            var i = MenuBarHidingStatus.Inputs()
            i.engine = .divider
            i.recovery = .clear
            edit(&i)
            inputs.append(i)
        }
        add { $0.dividerHidden = 7 }
        add { $0.dividerHidden = 7; $0.revealed = true }
        add { $0.dividerHidden = 7; $0.recovery = .idle }
        add { $0.dividerHidden = 7; $0.recovery = .settling }
        add { $0.dividerHidden = 7; $0.recovery = .unverified }
        add { $0.dividerHidden = 7; $0.recovery = .stuck(.spacerNotStanding) }
        add { $0.dividerHidden = 7; $0.recovery = .stuck(.overlapped(["Clock"])) }
        add { $0.dividerHidden = 0 }
        add { $0.noRoom = true
            $0.noRoomHelp = MenuBarRoomHelp.line(parked: 5, remove: 1) }
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                    MenuBarHidingBanner(status: MenuBarHidingStatus.assess(input)) { _ in }
                }
            }
            try Self.write(view, named: "position-banners", dark: dark, size: CGSize(width: 560, height: 0))
        }
    }
}
