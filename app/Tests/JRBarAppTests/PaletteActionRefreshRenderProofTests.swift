import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Palette action refresh render proof", .renderProofAppearance)
@MainActor
struct PaletteActionRefreshRenderProofTests {
    private func row(_ verbs: [String]) -> PaletteItem {
        PaletteItem(id: "notes", title: "Notes", subtitle: "Example menu item",
                    icon: .symbol("note.text", .orange), kind: "Menu Item", section: .menuBar,
                    actions: verbs.map { title in
                        PaletteAction(id: title, title: title, symbol: "circle") { nil }
                    })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func refreshedActions() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: env["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/palette-proof",
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(name: String, verbs: [String], expected: String)] = [
            ("retained", ["Always Hide", "Open", "Hide"], "Always Hide"),
            ("removed", ["Open", "Hide"], "Hide"),
        ]
        for state in cases {
            let model = PaletteModel()
            model.load(items: [row(["Open", "Hide", "Always Hide"])], usage: PaletteUsage())
            model.openActions()
            model.moveAction(-1)
            model.reload(items: [row(state.verbs)])
            #expect(model.actionsOpen)
            #expect(model.selectedAction?.id == state.expected)
            for dark in [true, false] {
                let palette = PaletteView(model: model, prompt: "Search JR-Bar…",
                                          onQueryChange: {}, onActivate: { _ in }, onRun: { _, _ in },
                                          onToggleActions: {}, snapshot: true)
                let view = ZStack {
                    Color(white: dark ? 0.16 : 0.93)
                    palette.background(RoundedRectangle(cornerRadius: PalettePanel.cornerRadius)
                        .fill(Color(white: dark ? 0.21 : 0.98)))
                }
                .frame(width: PalettePanel.width + 40, height: PalettePanel.height + 40)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let png = try #require(rep.representation(using: .png, properties: [:]))
                let filename = "palette-action-\(state.name)-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(filename))
            }
        }
    }
}
