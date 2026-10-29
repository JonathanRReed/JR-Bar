import JRBarTestSupport
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Provider update controls render proof", .renderProofAppearance)
struct ProviderUpdateRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func updateStates() throws {
        let cases: [(String, ProviderUpdateStatus)] = [
            ("current", ProviderUpdateStatus(phase: .unchanged, fromVersion: "2.1.301",
                toVersion: "2.1.301", message: "Already up to date (2.1.301)", updatable: true)),
            ("registry-current", ProviderUpdateStatus(updatable: true, upToDateVersion: "2.1.301")),
            ("unsupported", ProviderUpdateStatus(updatable: false,
                updateAdvice: "Use this installation's original installer to update it.")),
            ("available", ProviderUpdateStatus(latestVersion: "2.1.302", updatable: true)),
            ("running", ProviderUpdateStatus(phase: .running, message: "Installing the update…", updatable: true)),
            ("failed", ProviderUpdateStatus(phase: .failed, message: "The updater did not finish. Try again.",
                updatable: true)),
        ]
        for (name, status) in cases {
            let store = DevicePresentationTests.fixture(live: true)
            store.core.apply(.state(CoreState(generation: 2, providerUpdates: ["claude": status])))
            #expect(store.core.providerUpdates["claude"] == status)
            try WindowsRenderProofTests.write("provider-update-\(name)", size: CGSize(width: 500, height: 120)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude").font(.headline)
                    ProviderUpdateLine(store: store, provider: "claude", version: "2.1.301")
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}
