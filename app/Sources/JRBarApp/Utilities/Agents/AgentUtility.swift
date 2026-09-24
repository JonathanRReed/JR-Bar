import JRBarCore
import Observation
import SwiftUI

/// The Agent Overview utility (docs/UTILITIES.md): how loud each
/// provider's agents may be, whether an ask whose pane is already in
/// front stays quiet, and the way into the Overview window. The roster
/// itself lives in the panel and the Overview — this card keeps no list
/// and no session verbs of its own, so there is one place to answer an
/// ask and one to manage a session.
@MainActor
@Observable
final class AgentUtility: Toy {
    /// The daemon model — which providers have hooks or sessions.
    let core: CoreModel
    /// Live read of the persisted settings — the store wires it to
    /// `state.agents`, so the card's observation of the store's `state`
    /// still registers through the closure.
    @ObservationIgnored var settings: @MainActor () -> AgentOrganizerSettings = { AgentOrganizerSettings() }
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it.
    @ObservationIgnored var onSettingsChange: (@MainActor (AgentOrganizerSettings) -> Void)?
    /// The "Open the Overview" button's target — the delegate wires it
    /// to `OverviewWindowController.show()`. Left unset the button hides,
    /// so the utility stands alone.
    @ObservationIgnored var onOpenOverview: (@MainActor () -> Void)?

    init(core: CoreModel) { self.core = core }

    // MARK: Toy

    let id = "agents"
    let name = "Agent Overview"
    let blurb = "How loud each agent may be, and quiet while you watch — the roster itself lives in the panel and the Overview."
    let symbol = "person.2"

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        return core.isLive ? .on : .paused("Monitor not connected")
    }

    var controls: AnyView { AnyView(AgentUtilityControls(utility: self)) }

    // MARK: Settings writes

    /// A card edit: mutate a copy of the persisted settings and hand it
    /// to the store, whose `state` write persists it — the same shape
    /// `MenuBarUtility` uses.
    func update(_ mutate: (inout AgentOrganizerSettings) -> Void) {
        var draft = settings()
        mutate(&draft)
        onSettingsChange?(draft)
    }

    /// A binding into the persisted settings.
    func bind<T>(_ keyPath: WritableKeyPath<AgentOrganizerSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// The store's `applySettings` reaches every utility through here.
    /// Nothing to start or stop — the rules are read where each event
    /// is delivered; the seat matches the other utilities anyway.
    func applySettings() {}

    // MARK: Alert rules — the card's own job

    /// The providers the rules table offers: every one with hooks
    /// installed or a session on record, plus any that already carry a
    /// rule, in the settings' provider order.
    var alertProviders: [String] {
        var present = Set(settings().alertRules.keys)
        present.formUnion(core.sessions.filter { !$0.isRemote }.map(\.provider))
        if let hooks = core.state?.health?["hooks"]?.objectValue {
            present.formUnion(hooks.compactMap { provider, state in state.stringValue == "missing" ? nil : provider })
        }
        let known = SettingsKey.providers.filter(present.contains)
        return known + present.subtracting(known).sorted()
    }

    func alertRule(for provider: String) -> AgentAlertRule {
        settings().alertRules[provider] ?? .followGlobal
    }

    /// Writes one provider's rule; a rule edited back to "follow the
    /// global settings" is removed rather than stored as a no-op.
    func setAlertRule(_ rule: AgentAlertRule, for provider: String) {
        update { settings in
            if rule.isDefault {
                settings.alertRules.removeValue(forKey: provider)
            } else {
                settings.alertRules[provider] = rule
            }
        }
    }

    func bindRule<T>(_ provider: String, _ keyPath: WritableKeyPath<AgentAlertRule, T>) -> Binding<T> {
        Binding(
            get: { self.alertRule(for: provider)[keyPath: keyPath] },
            set: { value in
                var rule = self.alertRule(for: provider)
                rule[keyPath: keyPath] = value
                self.setAlertRule(rule, for: provider)
            })
    }

    /// The "Open the Overview" button — the delegate's Overview window.
    func openFullOverview() { onOpenOverview?() }
}
