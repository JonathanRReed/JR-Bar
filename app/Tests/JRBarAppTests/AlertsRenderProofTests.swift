import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the panel's session rows: the bell on a working row (shown while
/// the row is selected, filled once it is on), and a quiet row's amber label. Off by
/// default; set `JRBAR_RENDER_PROOF=1` and `JRBAR_RENDER_PROOF_DIR`.
@Suite("Alerts render proof")
@MainActor
struct AlertsRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the alerts PNGs"))
    func rows() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-alerts-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "jrbar.test.alerts-proof")!
        let panel = PanelStore(core: CoreModel(), draftsDefaults: defaults, screenBarShown: false)
        let now = Date()
        panel.now = now
        func session(_ id: String, _ label: String, minutesAgo: Double, mode: String = "working",
                     event: String = "PostToolUse") -> CoreSession {
            CoreSession(id: id, provider: "claude", label: label, cwd: "/Users/me/src/\(label)", mode: mode,
                        since: now.timeIntervalSince1970 - minutesAgo * 60, event: event)
        }
        let rows = [
            SessionRow(session: session("claude:a", "selected-bell", minutesAgo: 3), pinnedAsk: nil),
            SessionRow(session: session("claude:b", "bell-on", minutesAgo: 4), pinnedAsk: nil),
            SessionRow(session: session("claude:c", "quiet-12m", minutesAgo: 12), pinnedAsk: nil),
            SessionRow(session: session("claude:d", "long-build", minutesAgo: 50, mode: "tool_running", event: "PreToolUse"),
                       pinnedAsk: nil),
        ]
        panel.toggleDoneWatch(rows[1])
        panel.selectedID = rows[0].id
        for dark in [false, true] {
            let view = VStack(spacing: 0) {
                ForEach(rows) { row in PanelAgentView(agent: PanelAgent(row: row, members: [], unlinked: false, workerCount: 0), store: panel) }
            }
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            let rep = try SettingsRenderProofTests.snapshot(view, size: CGSize(width: 380, height: 260), dark: dark)
            let image = try #require(SettingsRenderProofTests.cropped(rep))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("panel-rows-\(dark ? "dark" : "light").png"))
        }
        defaults.removePersistentDomain(forName: "jrbar.test.alerts-proof")
    }
}
