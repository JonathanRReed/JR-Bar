import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proofs for the wait effects: every orb activity in light and
/// dark at 1× and 2×; a beam's frame sequence under the palette's field
/// and round an ask card whose answer is on the wire; and the panel with
/// working rows doing different things. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`
/// (default /tmp/waits-proof).
@Suite("Wait effects render proof", .serialized)
@MainActor
struct WaitEffectsRenderProofTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" }

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/waits-proof",
            isDirectory: true)
    }

    static let now = Date()
    static var t: Double { now.timeIntervalSince1970 }

    /// Writes `view` at `size` and `scale` in one appearance, over the
    /// plate it would sit on.
    static func write<V: View>(_ name: String, size: CGSize, dark: Bool, scale: CGFloat = 2,
                               plate: Color? = nil, still: WaitStill? = nil, _ view: V) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let framed = ZStack {
            plate ?? Color(white: dark ? 0.13 : 0.93)
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.renderSnapshot, true)
        .environment(\.waitStill, still ?? WaitStill(now: now))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Orbs

    /// One activity's row: its name, its still frame in three provider
    /// tints and amber at the row's 14 pt, at 18 pt, the Reduce Motion
    /// still, and six frames of its loop.
    struct OrbSheetRow: View {
        let activity: AgentActivity
        static let tints: [Color] = ["claude", "codex", "gemini"].map { ProviderStyle.style(for: $0).accent }
            + [SessionActivity.waiting.tint]

        var body: some View {
            HStack(spacing: 12) {
                Text(activity.spokenLabel)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 64, alignment: .leading)
                ForEach(Self.tints.indices, id: \.self) { index in
                    ThinkingOrb(activity: activity, tint: Self.tints[index], size: 14)
                }
                ThinkingOrb(activity: activity, tint: Self.tints[0], size: 18)
                ThinkingOrb(activity: activity, tint: .secondary, size: 14, reduced: true)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 16)
                ForEach(0..<6, id: \.self) { step in
                    ThinkingOrb(activity: activity, tint: Self.tints[1], size: 18)
                        .environment(\.waitStill, WaitStill(now: WaitEffectsRenderProofTests.now,
                                                            orbTime: Double(step) * 0.2))
                }
            }
        }
    }

    struct OrbSheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AgentActivity.allCases, id: \.self) { activity in
                    OrbSheetRow(activity: activity)
                }
            }
            .padding(14)
        }
    }

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func orbs() throws {
        let size = CGSize(width: 440, height: 170)
        for dark in [false, true] {
            for scale in [1, 2] as [CGFloat] {
                let name = "orbs-\(dark ? "dark" : "light")-\(Int(scale))x"
                try Self.write(name, size: size, dark: dark, scale: scale, OrbSheet())
            }
        }
    }

    // MARK: The palette

    static func paletteModel(searchingFor seconds: TimeInterval) -> PaletteModel {
        let model = PaletteModel()
        let rows = [
            SessionRow(session: CoreSession(id: "codex:docs", provider: "codex", label: "docs pass",
                                            cwd: "/Users/me/src/site", mode: "working",
                                            since: t - 900, event: "PreToolUse", tool: "Edit"),
                       pinnedAsk: nil),
        ]
        let noop = AgentPaletteVerbs(open: { _ in }, approve: { _ in }, deny: { _ in }, snooze: { _, _ in },
                                     copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        var items = AgentPaletteRows.items(rows: rows, now: now, verbs: noop)
        items += ControlCenterPaletteRows.items(isOn: [.darkMode: true, .keepAwake: false], applying: []) { _ in }
        model.load(items: items, usage: PaletteUsage(), now: now)
        model.query = "do"
        model.clock = { now.addingTimeInterval(-seconds) }
        model.noteSearching(true)
        return model
    }

    static func palette(_ model: PaletteModel, dark: Bool) -> some View {
        PaletteView(model: model, prompt: "Search menu bar, sessions and commands…",
                    onQueryChange: {}, onActivate: { _ in }, onRun: { _, _ in }, onToggleActions: {},
                    snapshot: true)
            .background(RoundedRectangle(cornerRadius: PalettePanel.cornerRadius)
                .fill(Color(white: dark ? 0.21 : 0.98)))
    }

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func paletteWait() throws {
        let size = CGSize(width: PalettePanel.width + 40, height: PalettePanel.height + 40)
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            // 1.5 s: nothing yet. 2.5 s: the footer's orb. 3.5 s: the beam too.
            for (seconds, label) in [(1.5, "quiet"), (2.5, "orb")] {
                let model = Self.paletteModel(searchingFor: seconds)
                try Self.write("palette-\(label)-\(scheme)", size: size, dark: dark, Self.palette(model, dark: dark))
            }
            let model = Self.paletteModel(searchingFor: 3.5)
            for (index, phase) in [0.12, 0.3, 0.48, 0.66, 0.84].enumerated() {
                let still = WaitStill(now: Self.now, beamPhase: phase)
                try Self.write("palette-beam-\(index + 1)-\(scheme)", size: size, dark: dark, still: still,
                               Self.palette(model, dark: dark))
            }
        }
    }

    // MARK: An ask card with its answer on the wire

    static func askingStore(inFlightFor seconds: TimeInterval) async throws -> (PanelStore, Task<Void, Never>) {
        let ask = WindowsRenderProofTests.sessions(asking: true)
        let store = WindowsRenderProofTests.panelStore(CoreState(
            now: t, aggregate: CoreAggregate(mode: "waiting", needsYou: 2, active: 2, ready: 1, failed: 1),
            sessions: ask.sessions, asks: ask.asks, devices: WindowsRenderProofTests.devices,
            usage: WindowsRenderProofTests.usage(heavy: false)))
        store.askDesk.clock = { now.addingTimeInterval(-seconds) }
        store.askDesk.send = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return CoreReply(id: "1", ok: true)
        }
        let permission = try #require(ask.asks.first)
        let desk = store.askDesk
        let flight = Task { @MainActor in
            _ = await desk.answer(permission, .approve)
        }
        for _ in 0..<50 where !desk.isPending(permission.session) {
            await Task.yield()
        }
        #expect(desk.isPending(permission.session))
        return (store, flight)
    }

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func askCardInFlight() async throws {
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let (orbStore, orbFlight) = try await Self.askingStore(inFlightFor: 2.5)
            try Self.write("askcard-orb-\(scheme)", size: WindowsRenderProofTests.panelSize(orbStore), dark: dark,
                           WindowsRenderProofTests.panel(orbStore))
            orbFlight.cancel()
            let (store, flight) = try await Self.askingStore(inFlightFor: 3.5)
            let size = WindowsRenderProofTests.panelSize(store)
            for (index, phase) in [0.05, 0.25, 0.45, 0.65, 0.85].enumerated() {
                let still = WaitStill(now: Self.now, beamPhase: phase)
                try Self.write("askcard-beam-\(index + 1)-\(scheme)", size: size, dark: dark, still: still,
                               WindowsRenderProofTests.panel(store))
            }
            flight.cancel()
        }
    }

    /// The beam alone round an ask-card-sized plate: its travel at a few
    /// phases and the Reduce Motion glow, bigger than the panel shows it.
    struct BeamPlate: View {
        let phase: Double
        var motion: BeamMotion = .travel

        var body: some View {
            AskCardPlate(selected: false)
                .frame(width: 300, height: 92)
                .overlay {
                    BorderBeamLayer(track: .ring(cornerRadius: AskCardPlate.radius),
                                    tint: SessionActivity.waiting.tint, motion: motion, frozenPhase: phase)
                        .padding(-BeamGeometry.bleed)
                }
        }
    }

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func beamSequence() throws {
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            // Two frames either side of the path's seam, then a lap in
            // fifths, then the Reduce Motion glow.
            let frames = VStack(spacing: 14) {
                ForEach([0.99, 0.013, 0.2, 0.4, 0.6, 0.8], id: \.self) { phase in
                    BeamPlate(phase: phase)
                }
                BeamPlate(phase: 0, motion: .glow)
            }
            .padding(16)
            try Self.write("beam-frames-\(scheme)", size: CGSize(width: 340, height: 820), dark: dark, frames)
        }
    }

    // MARK: The panel's working rows

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func panelActivities() throws {
        let sessions = [
            CoreSession(id: "claude:audit", provider: "claude", label: "menu bar audit", cwd: "/Users/me/src/jr-bar",
                        mode: "working", since: Self.t - 320, event: "PreToolUse", tool: "Grep"),
            CoreSession(id: "codex:site", provider: "codex", label: "docs refresh", cwd: "/Users/me/src/site",
                        mode: "working", since: Self.t - 1520, event: "PreToolUse", tool: "apply_patch"),
            CoreSession(id: "gemini:ci", provider: "gemini", label: "flaky ci", cwd: "/Users/me/src/api",
                        mode: "working", since: Self.t - 95, event: "PreToolUse", tool: "run_shell_command"),
            CoreSession(id: "opencode:plan", provider: "opencode", label: "release plan", cwd: "/Users/me/src/notes",
                        mode: "working", since: Self.t - 40, event: "UserPromptSubmit"),
            CoreSession(id: "cursor:ui", provider: "cursor", label: "settings polish", cwd: "/Users/me/src/app",
                        mode: "working", since: Self.t - 610, event: "Notification"),
            CoreSession(id: "devin:notes", provider: "devin", label: "changelog", cwd: "/Users/me/src/notes",
                        mode: "completed", since: Self.t - 380),
            CoreSession(id: "grok:api", provider: "grok", label: "api migration", cwd: "/Users/me/src/api",
                        mode: "failed", since: Self.t - 2200),
        ]
        let store = WindowsRenderProofTests.panelStore(CoreState(
            now: Self.t, aggregate: CoreAggregate(mode: "working", active: 5, ready: 1, failed: 1),
            sessions: sessions, devices: WindowsRenderProofTests.devices,
            usage: WindowsRenderProofTests.usage(heavy: false)))
        let size = WindowsRenderProofTests.panelSize(store)
        for dark in [false, true] {
            try Self.write("panel-activities-\(dark ? "dark" : "light")", size: size, dark: dark,
                           WindowsRenderProofTests.panel(store))
        }
    }
}
