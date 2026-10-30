import JRBarCore
import JRBarUI
import SwiftUI

/// The Agent Overview utility's card on the Utilities page —
/// `ToyCard`'s shell (docs/UTILITIES.md: one visual language, two
/// registries) over an `AgentUtility`. The Overview window is the
/// roster; this is where each agent's loudness is set.
struct AgentUtilityCard: View {
    let utility: AgentUtility
    let tint: Color

    var body: some View {
        ToyCard(toy: utility, tint: tint)
    }
}

/// The card's disclosure body: the per-provider alert rules, "quiet
/// while you watch", and the way into the Overview window, where every
/// session and its verbs live.
struct AgentUtilityControls: View {
    let utility: AgentUtility

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            if !utility.snapshot.live && utility.onOpenMonitorDetails != nil {
                SettingGroup("Connection") {
                    SettingRow("Monitor details", subtitle: "Check why agent activity is unavailable.") {
                        Button("Open monitor details") { utility.openMonitorDetails() }
                    }
                }
            }

            SettingGroup("Provider alerts") { AgentAlertRulesTable(utility: utility) }

            SettingGroup("While you watch") {
                Toggle(isOn: utility.bind(\.quietWhenPaneFrontmost)) {
                    SettingLabel(title: "Quiet while you watch",
                        subtitle: "Mute ask sounds and escalation while the session's terminal pane is in front. Banners still appear.")
                }
            }

            if utility.onOpenOverview != nil {
                SettingGroup("Sessions") {
                    LabeledContent {
                        Button("Open the Overview") { utility.openFullOverview() }
                            .controlSize(.small)
                    } label: {
                        SettingLabel(title: "Sessions",
                            subtitle: "Session status and controls in the panel and Overview.")
                    }
                }
            }
        }
    }
}
