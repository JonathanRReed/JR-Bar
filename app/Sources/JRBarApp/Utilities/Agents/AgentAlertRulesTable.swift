import JRBarCore
import SwiftUI

/// The Agent Overview card's own job: how loud each provider's agents may
/// be. One row per provider with hooks or sessions — asks, finishes,
/// failures, sounds, and how far its escalation may climb — each
/// defaulting to "follow the global setting", so an untouched row changes
/// nothing. The rules apply where every event turns into sound and
/// banners (`EventCoordinator.deliveryRules`), after the global policy
/// decided.
struct AgentAlertRulesTable: View {
    let utility: AgentUtility

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingLabel(title: "Alert rules",
                         subtitle: "How loud each agent may be — \"Codex can be loud, Grok quiet\". A blank rule follows Settings › Notifications.")
            let providers = utility.alertProviders
            if providers.isEmpty {
                Text("No agents yet — providers appear here once their hooks are installed or a session reports in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Agent")
                        Text("Asks")
                        Text("Finishes")
                        Text("Failures")
                        Text("Sounds")
                        Text("Escalates to")
                        Text("")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    ForEach(providers, id: \.self) { provider in
                        row(provider)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ provider: String) -> some View {
        let style = ProviderStyle.style(for: provider)
        let rule = utility.alertRule(for: provider)
        GridRow {
            HStack(spacing: 6) {
                ProviderTile(style: style, size: 16)
                Text(style.name).lineLimit(1)
            }
            .help(rule.summary.map { "\(style.name): \($0)" } ?? "\(style.name) follows the global notification settings")
            Toggle("", isOn: utility.bindRule(provider, \.asks))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Ask banners, the ask sound and the escalation's pulse and chime; off keeps the ask on the panel and the light but never interrupts")
            Picker("", selection: utility.bindRule(provider, \.completions)) {
                Text("Follow").tag(Bool?.none)
                Text("Always").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
            }
            .labelsHidden()
            .fixedSize()
            .help("Completion banners for this agent: follow Settings, always, or never")
            Toggle("", isOn: utility.bindRule(provider, \.failures))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Failure banners and the failure sound")
            Toggle("", isOn: utility.bindRule(provider, \.sounds))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Every sound this agent's events make, the escalation chime included — banners stay")
            Picker("", selection: utility.bindRule(provider, \.escalationCeiling)) {
                Text("Follow").tag(Int?.none)
                Text("The light").tag(Int?.some(1))
                Text("The pulse").tag(Int?.some(2))
                Text("The chime").tag(Int?.some(3))
            }
            .labelsHidden()
            .fixedSize()
            .help("How far an unanswered ask from this agent may climb past the light, which always ramps; a rule can only lower Settings' ceiling")
            if rule.isDefault {
                Text("")
            } else {
                Button {
                    utility.setAlertRule(.followGlobal, for: provider)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Follow the global settings again")
                .accessibilityLabel("Reset \(style.name)'s rule")
            }
        }
        .font(.callout)
    }
}
