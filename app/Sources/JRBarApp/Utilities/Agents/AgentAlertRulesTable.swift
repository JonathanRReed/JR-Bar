import JRBarUI
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
        VStack(alignment: .leading, spacing: JRBarTokens.Space.md) {
            SettingLabel(title: "Alert rules",
                         subtitle: "Choose which events each provider can announce. Unchanged rules follow Alerts & Sounds.")
            let providers = utility.alertProviders
            if providers.isEmpty {
                CardNote("Install a provider's hooks or start a session to set its alert rules.",
                         symbol: "person.crop.circle.badge.questionmark")
            }
            ForEach(providers, id: \.self) { provider in
                providerRows(provider)
            }
        }
    }

    private func providerRows(_ provider: String) -> some View {
        let name = ProviderStyle.style(for: provider).name
        let summary = utility.alertRule(for: provider).summary ?? "Follows Alerts & Sounds."
        return DisclosureRow(name, subtitle: summary, fold: SettingsFeatureOptions.agentProvider(provider)) {
            Toggle(isOn: utility.bindRule(provider, \.asks)) {
                SettingLabel(title: "Asks", subtitle: "Allow ask banners, sounds and escalation. Asks always remain in the panel and lights.")
            }
            LabeledContent {
                Picker("Finishes", selection: utility.bindRule(provider, \.completions)) {
                    Text("Follow").tag(Bool?.none)
                    Text("Always").tag(Bool?.some(true))
                    Text("Never").tag(Bool?.some(false))
                }.labelsHidden().pickerStyle(.segmented)
            } label: {
                SettingLabel(title: "Finishes", subtitle: "Show completion banners, or follow the global choice.")
            }
            Toggle(isOn: utility.bindRule(provider, \.failures)) {
                SettingLabel(title: "Failures", subtitle: "Show failure banners and play the failure sound.")
            }
            Toggle(isOn: utility.bindRule(provider, \.sounds)) {
                SettingLabel(title: "Provider sounds", subtitle: "Play this provider's event sounds and escalation chimes.")
            }
            LabeledContent {
                Picker("Escalates to", selection: utility.bindRule(provider, \.escalationCeiling)) {
                    Text("Follow").tag(Int?.none)
                    Text("The light").tag(Int?.some(1))
                    Text("The pulse").tag(Int?.some(2))
                    Text("The chime").tag(Int?.some(3))
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            } label: {
                SettingLabel(title: "Escalates to", subtitle: "Limit unanswered-ask alerts to this level. The global limit still applies.")
            }
            if !utility.alertRule(for: provider).isDefault {
                LabeledContent {
                    Button("Reset rule") { utility.setAlertRule(.followGlobal, for: provider) }
                        .accessibilityLabel("Reset \(name)'s rule")
                } label: {
                    SettingLabel(title: "Follow global alerts", subtitle: "Use the choices on Alerts & Sounds again.")
                }
            }
        }
        .toggleStyle(CardToggleStyle())
    }
}

/// `ViewThatFits` over two layouts that builds only one of them: the
/// `preferred` one while its ideal width fits the width offered (and
/// before either is known), the `fallback` once it does not. The
/// preferred layout's ideal width is read while it shows and remembered,
/// so a window that grows back past it brings it back; a new `key` (the
/// content changed) reads it again. `ViewThatFits` builds and measures
/// both on every pass — the Agent Overview's pickers and switches twice.
struct WidestThatFits<Preferred: View, Fallback: View>: View {
    let key: AnyHashable
    @ViewBuilder var preferred: () -> Preferred
    @ViewBuilder var fallback: () -> Fallback
    @ViewState private var ideal: CGFloat?
    @ViewState private var measured: AnyHashable?
    @ViewState private var offered: CGFloat?

    init<Key: Hashable>(key: Key, @ViewBuilder preferred: @escaping () -> Preferred,
                        @ViewBuilder fallback: @escaping () -> Fallback) {
        self.key = AnyHashable(key)
        self.preferred = preferred
        self.fallback = fallback
    }

    /// Whether the fallback shows for these widths. Pure, for the tests.
    static func fallsBack(ideal: CGFloat?, offered: CGFloat?, current: Bool) -> Bool {
        guard current, let ideal, let offered else { return false }
        return ideal > offered + 0.5
    }

    var body: some View {
        let fallsBack = Self.fallsBack(ideal: ideal, offered: offered, current: measured == key)
        Group {
            if fallsBack {
                fallback()
            } else {
                IdealWidthLayout {
                    preferred()
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            ideal = width
                            measured = key
                        }
                        .id(key)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { offered = $0 }
    }
}

/// Lays out its first view as it is offered, and hands its second — a
/// probe that takes no room — the first one's ideal width, for the probe
/// to report.
private struct IdealWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var size = subviews.first?.sizeThatFits(proposal) ?? .zero
        // The grid's minimum width must not expand the parent form before the fallback is measured.
        if let width = proposal.width, width.isFinite { size.width = width }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        guard subviews.count > 1 else { return }
        let ideal = content.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: ideal, height: 0))
    }
}
