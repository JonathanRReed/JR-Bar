import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Overview consistency proofs", .serialized)
@MainActor
struct OverviewConsistencyRenderProofTests {
    static let now = 1_800_000_000.0

    static var providers: [CoreProviderUsage] {
        var providers = [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 42, resetsAt: now + 7200),
                CoreUsageWindow(key: "7d_fable", name: "7d Fable", usedPct: 20, resetsAt: now + 86400),
            ], state: "ready"),
            CoreProviderUsage(id: "cursor", state: "needs_consent", quotaSource: false),
            CoreProviderUsage(id: "devin", windows: [
                CoreUsageWindow(key: "daily", name: "Daily", usedPct: 39, resetsAt: now + 3418),
            ], state: "ready"),
            CoreProviderUsage(id: "antigravity", windows: [
                CoreUsageWindow(key: "gemini_weekly", name: "Gemini Weekly", usedPct: 60, resetsAt: now - 86400),
                CoreUsageWindow(key: "claude_gpt_5h", name: "Claude + GPT 5-Hour", usedPct: 80, resetsAt: now - 7200),
            ], state: "stale", observedAt: now - 10 * 86400),
            CoreProviderUsage(id: "factory", state: "needs_sign_in"),
        ]
        providers[1].availability = "absent"
        providers[3].availability = "source_idle"
        providers[3].statusText = "Quota service is not running"
        providers[4].availability = "failing"
        providers[4].statusText = "Browser connection expired. Open Factory in your browser and sign in again."
        return providers
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func surfaces() throws {
        let sessions = [CoreSession(id: "codex:sample", provider: "codex", label: "Sample check", mode: "working")]
        let core = WindowsRenderProofTests.liveCore(CoreState(now: Self.now, sessions: sessions,
            devices: WindowsRenderProofTests.devices, usage: CoreUsage(providers: Self.providers),
            deck: DeckState(device: DeckDevice(name: "Legacy deck", connected: false), settings: DeckSettings(enabled: true))))
        let overview = OverviewStore(core: core, localName: "Sample Mac")
        overview.roster = sessions.map { CoreRosterEntry(session: $0) }
        let usage = UsageCenterStore(core: core)
        usage.now = Date(timeIntervalSince1970: Self.now)
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            overview.filter = OverviewFilter(preset: .needsMe)
            try ProofRender.write(OverviewView(store: overview).tint(.blue).accentColor(.blue)
                .environment(\.controlActiveState, .key).background(Color(nsColor: .windowBackgroundColor)),
                size: CGSize(width: 1200, height: 760), name: "agent-empty-\(look)", dark: dark, settle: 0)
            try nativeWindow(overview, name: "agent-window-empty-\(look)", dark: dark)
            overview.filter = OverviewFilter(preset: .working)
            try ProofRender.write(OverviewView(store: overview).tint(.blue).accentColor(.blue)
                .environment(\.controlActiveState, .key).background(Color(nsColor: .windowBackgroundColor)),
                size: CGSize(width: 1200, height: 760), name: "agent-populated-\(look)", dark: dark, settle: 0)
            try nativeWindow(overview, name: "agent-window-populated-\(look)", dark: dark)
            try ProofRender.write(UsageOverviewTable(store: usage, showCost: true, select: { _ in })
                .padding(20).background(Color(nsColor: .windowBackgroundColor)),
                size: CGSize(width: 1200, height: 650), name: "usage-overview-\(look)", dark: dark, settle: 0)
        }
    }

    private func nativeWindow(_ store: OverviewStore, name: String, dark: Bool) throws {
        let controller = OverviewWindowController(store: store)
        let window = controller.makeWindow()
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: -20000, y: -20000, width: 1200, height: 800), display: false)
        let frame = try #require(window.contentView?.superview)
        for _ in 0..<6 {
            frame.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(window.toolbar != nil)
        #expect(!window.isVisible)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: ProofRender.directory.appendingPathComponent("\(name).png"))
    }
}
