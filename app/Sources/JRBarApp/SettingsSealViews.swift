import JRBarCore
import SwiftUI

// What Settings says about the settings seal (SettingsSeal.swift): a banner
// above every page when something needs a person, and Advanced › Protection.

/// The banner's content for one notice, with no model behind it, so a picture
/// of it needs only these facts.
struct SettingsSealNoticeCard: View {
    let notice: SettingsSealNotice
    var working = false
    var onKeep: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onRetry: () -> Void = {}

    private var symbol: String {
        switch notice {
        case .ignoredChange: return "lock.trianglebadge.exclamationmark.fill"
        case .keychainUnavailable: return "key.fill"
        case .notSealed: return "lock.open.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s + 2) {
            SettingsBanner(symbol: symbol, tint: .orange, title: notice.title, detail: notice.detail)
            HStack(spacing: SettingsMetrics.s) {
                Spacer(minLength: 28)
                switch notice {
                case .ignoredChange(_, let canKeep):
                    Button("Discard the change", action: onDiscard)
                    if canKeep {
                        Button("Keep the change", action: onKeep)
                            .buttonStyle(.borderedProminent)
                    }
                case .keychainUnavailable:
                    Button("Try again", action: onRetry)
                case .notSealed:
                    Button("Seal now", action: onDiscard)
                }
                Spacer(minLength: 0)
            }
            .disabled(working)
        }
        .padding(.vertical, 2)
    }
}

/// The banner at the top of every Settings page.
struct SettingsSealBanner: View {
    let seal: SettingsSealCoordinator

    var body: some View {
        if let notice = seal.notice {
            SettingsSealNoticeCard(
                notice: notice,
                working: seal.working,
                onKeep: { Task { await seal.keepChange() } },
                onDiscard: { Task { await seal.resetProtection() } },
                onRetry: { Task { await seal.tryKeychainAgain() } }
            )
        } else if let line = seal.resultLine {
            SettingsBanner(symbol: "checkmark.circle.fill", tint: .green, title: line)
                .task(id: line) {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    seal.clearResultLine()
                }
        }
    }
}

/// Advanced › Protected settings: whether the seal holds, and the way to seal again.
struct SettingsSealGroup: View {
    @Bindable var seal: SettingsSealCoordinator
    let isLive: Bool

    var body: some View {
        SettingGroup(
            note: "The settings that switch on answering from the status server, a webhook, cloud ingest, remote peers or a program JR-Bar runs are sealed with a key only JR-Bar can read from your Keychain. Editing them in the settings file by hand changes nothing, and JR-Bar tells you it was ignored."
        ) {
            SettingRow("Seal", subtitle: seal.stateWord) {
                Button("Reset protection…") { seal.confirmingReset = true }
                    .disabled(!isLive || seal.working)
            }
        } header: {
            Text("Protected settings")
        }
        .confirmationDialog("Reset protection?", isPresented: WindowPresenter.presentation($seal.confirmingReset), titleVisibility: .visible) {
            Button("Reset protection") { Task { await seal.resetProtection() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The protected settings as they are in JR-Bar now are sealed again, and any change made outside JR-Bar that was ignored is dropped.")
        }
    }
}
