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
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            SettingLabel(title: "Alert rules",
                         subtitle: "How loud each agent may be — \"Codex can be loud, Grok quiet\". A blank rule follows Settings › Notifications.")
                .padding(.top, SettingsMetrics.xs)
            let providers = utility.alertProviders
            if providers.isEmpty {
                CardNote("No agents yet — providers appear here once their hooks are installed or a session reports in.",
                         symbol: "person.crop.circle.badge.questionmark")
            } else {
                // The table while it fits; at a narrow window each agent
                // stacks its switches under its name instead of spilling
                // the page sideways.
                ViewThatFits(in: .horizontal) {
                    table(providers)
                    stacked(providers)
                }
                .padding(.horizontal, SettingsMetrics.m)
                .padding(.vertical, SettingsMetrics.s + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(InsetPanel())
            }
        }
    }

    private func table(_ providers: [String]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: SettingsMetrics.m, verticalSpacing: SettingsMetrics.s) {
            GridRow {
                Text("Agent")
                Text("Asks")
                Text("Finishes")
                Text("Failures")
                Text("Sounds")
                Text("Escalates to")
                Text("")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(providers, id: \.self) { provider in
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    name(provider)
                    asks(provider, labelled: false)
                    finishes(provider, labelled: false)
                    failures(provider, labelled: false)
                    sounds(provider, labelled: false)
                    escalation(provider, labelled: false)
                    reset(provider)
                }
                .font(.callout)
            }
        }
    }

    private func stacked(_ providers: [String]) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        name(provider)
                        Spacer(minLength: SettingsMetrics.s)
                        reset(provider)
                    }
                    FlowLayout(spacing: SettingsMetrics.m, lineSpacing: 6) {
                        asks(provider, labelled: true)
                        failures(provider, labelled: true)
                        sounds(provider, labelled: true)
                        finishes(provider, labelled: true)
                        escalation(provider, labelled: true)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: The controls both layouts share

    private func name(_ provider: String) -> some View {
        let style = ProviderStyle.style(for: provider)
        let rule = utility.alertRule(for: provider)
        return HStack(spacing: 6) {
            ProviderTile(style: style, size: 16)
            Text(style.name).lineLimit(1)
        }
        .font(.callout)
        .help(rule.summary.map { "\(style.name): \($0)" } ?? "\(style.name) follows the global notification settings")
    }

    private func asks(_ provider: String, labelled: Bool) -> some View {
        Toggle(labelled ? "Asks" : "", isOn: utility.bindRule(provider, \.asks))
            .labelsHidden(!labelled)
            .toggleStyle(.checkbox)
            .help("Ask banners, the ask sound and the escalation's pulse and chime; off keeps the ask on the panel and the light but never interrupts")
    }

    private func finishes(_ provider: String, labelled: Bool) -> some View {
        captioned(labelled ? "Finishes" : nil) {
            Picker("Finishes", selection: utility.bindRule(provider, \.completions)) {
                Text("Follow").tag(Bool?.none)
                Text("Always").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
            }
            .labelsHidden()
            .fixedSize()
        }
        .help("Completion banners for this agent: follow Settings, always, or never")
    }

    private func failures(_ provider: String, labelled: Bool) -> some View {
        Toggle(labelled ? "Failures" : "", isOn: utility.bindRule(provider, \.failures))
            .labelsHidden(!labelled)
            .toggleStyle(.checkbox)
            .help("Failure banners and the failure sound")
    }

    private func sounds(_ provider: String, labelled: Bool) -> some View {
        Toggle(labelled ? "Sounds" : "", isOn: utility.bindRule(provider, \.sounds))
            .labelsHidden(!labelled)
            .toggleStyle(.checkbox)
            .help("Every sound this agent's events make, the escalation chime included — banners stay")
    }

    private func escalation(_ provider: String, labelled: Bool) -> some View {
        captioned(labelled ? "Escalates to" : nil) {
            Picker("Escalates to", selection: utility.bindRule(provider, \.escalationCeiling)) {
                Text("Follow").tag(Int?.none)
                Text("The light").tag(Int?.some(1))
                Text("The pulse").tag(Int?.some(2))
                Text("The chime").tag(Int?.some(3))
            }
            .labelsHidden()
            .fixedSize()
        }
        .help("How far an unanswered ask from this agent may climb past the light, which always ramps; a rule can only lower Settings' ceiling")
    }

    /// A picker with its column's word before it in the stacked rows —
    /// the form would otherwise stretch a labelled picker across the row.
    private func captioned<Content: View>(_ caption: String?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            if let caption {
                Text(caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    @ViewBuilder
    private func reset(_ provider: String) -> some View {
        if utility.alertRule(for: provider).isDefault {
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
            .accessibilityLabel("Reset \(ProviderStyle.style(for: provider).name)'s rule")
        }
    }
}

private extension View {
    /// `labelsHidden()` only when asked — the table hides the column
    /// words its header already says; the stacked rows keep them.
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
