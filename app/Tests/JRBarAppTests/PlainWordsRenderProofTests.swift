import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore
@testable import JRBarUI

/// Lane 2 (plain words): the states whose words changed, drawn so a person
/// can read them. Synthetic data only.
@MainActor
@Suite("Plain words render proof")
struct PlainWordsRenderProofTests {
    static let now: Double = 1_800_000_000

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func advancedConnectionRowSaysWhyInPlainWords() throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-plain-words-proof.sock")
        core.handle(.disconnected(reason: "core closed the socket"))
        let store = SettingsStore(core: core)
        try WindowsRenderProofTests.write("plain-advanced-disconnected", size: CGSize(width: 560, height: 120)) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Advanced").font(.system(size: 20, weight: .semibold))
                ConnectionWordRow(store: store)
            }
            .padding(20)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func hooksDoctorCountsRefusedEvents() async throws {
        let doctor = HooksDoctorModel()
        let result: JSONValue = .object([
            "checked_at": .number(Date().timeIntervalSince1970 - 30),
            "ingress_socket": .object(["answers": .bool(true)]),
            "providers": .array([]),
            "rejected": .object(["today": .number(3), "newest_detail": .string("bad_lengths"),
                                 "sentence": .string("3 hook events were refused today. The newest: the event arrived cut short.")]),
        ])
        await doctor.refresh { CoreReply(id: "report", ok: true, result: result) }?.value
        try WindowsRenderProofTests.write("plain-hooks-refused", size: CGSize(width: 640, height: 140)) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Providers").font(.system(size: 20, weight: .semibold))
                HooksDoctorStatusRow(doctor: doctor, live: true) {}
            }
            .padding(20)
        }
    }

    static func row(_ id: String, state: String, status: String, action: String?, availability: String,
                    quotaSource: Bool = true) -> CoreProviderUsage {
        var row = CoreProviderUsage(id: id, windows: [], state: state, action: action, quotaSource: quotaSource)
        row.availability = availability
        row.statusText = status
        return row
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func signInAndConsentRowsAreNeutralWithAnHonestButton() throws {
        let rows = [
            Self.row("kiro", state: "needs_sign_in", status: "Run kiro-cli login in Terminal, then Retry.",
                     action: "Retry", availability: "available"),
            Self.row("kilo", state: "needs_consent", status: "Turn on Kilo usage in Settings > Providers.",
                     action: nil, availability: "available"),
            // No Go subscription is an answer, not a failure: neutral, no button.
            Self.row("opencode", state: "unsupported",
                     status: "This account has no OpenCode Go subscription, so there is no quota to show.",
                     action: nil, availability: "available", quotaSource: false),
        ]
        try WindowsRenderProofTests.write("plain-usage-rows", size: CGSize(width: 372, height: 300), plate: .glass) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { provider in
                    UsageGaugeRow(provider: provider, name: ProviderPalette.displayName(for: provider.id), now: Self.now,
                                  connected: true, style: .compact, snapshotReceivedAt: Self.now,
                                  onAction: provider.action == nil ? nil : {},
                                  onRetry: provider.availability == "failing" && provider.action != "Retry" ? {} : nil)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func historyWordsAndErrorToasts() throws {
        let toasts = [
            CoreReplyError(code: "usage_off", message: "Kiro usage is off. Turn it on in Settings > Providers first; nothing is read or sent until you do.").localizedDescription,
            CoreClientError.timeout.localizedDescription,
            MonitorWords.reason("core closed the socket"),
        ]
        try WindowsRenderProofTests.write("plain-history-and-toasts", size: CGSize(width: 640, height: 260)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(EventLogWords.banner(kept: 120, dropped: 3, incomplete: false)).jrbarType(.caption)
                Label(EventLogWords.needYou(1), systemImage: "exclamationmark.bubble").jrbarType(.caption)
                Text("Run lengths: " + [45.0, 1500, 3600].compactMap { HistoryStore.duration($0) }.joined(separator: ", "))
                    .jrbarType(.caption)
                Divider()
                ForEach(toasts, id: \.self) { toast in
                    StatusBanner(toast)
                }
            }
            .padding(20)
        }
    }
}
