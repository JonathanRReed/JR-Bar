import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// A Usage Center card whose Claude reading was kept through failed polls:
/// beside its Stale badge it says how old the numbers are ("read 5h 10m ago",
/// counted from `read_at`), not how long ago the last failed attempt was.
/// Off by default; set `JRBAR_RENDER_PROOF=1` to write PNGs into
/// `JRBAR_RENDER_PROOF_DIR`, using the mock daemon's `stale` usage scenario.
@Suite("Usage stale reading render proof", .serialized)
@MainActor
struct UsageStaleRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func staleReadingNamesItsAge() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6, extra: ["--usage-scenario", "stale"])
        defer { process.terminate(); core.stop() }
        let store = UsageCenterStore(core: core)
        store.windowDidOpen()
        try await WindowsRenderProofTests.settle {
            !store.providers.isEmpty && store.providers.allSatisfy { store.history(for: $0) != nil }
        }
        let claude = try #require(store.providers.first { $0.id == "claude" })
        #expect(claude.isStale)
        let read = try #require(claude.readAt)
        let observed = try #require(claude.observedAt)
        #expect(observed - read > 5 * 3600, "the numbers are hours older than the last attempt")
        let stale = ProviderUsageCard.readingAgeText(claude, now: store.now)
        #expect(stale?.hasPrefix("read 5h") == true, "\(stale ?? "nil")")
        let codex = try #require(store.providers.first { $0.id == "codex" })
        #expect(ProviderUsageCard.readingAgeText(codex, now: store.now) == "read 1m ago")
        try WindowsRenderProofTests.write("usage-center-stale", size: CGSize(width: 780, height: 1340)) {
            UsageCenterView(store: store)
        }
        store.windowDidClose()
    }
}
