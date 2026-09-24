import JRBarCore
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
        VStack(alignment: .leading, spacing: 4) {
            AgentAlertRulesTable(utility: utility)

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: utility.bind(\.quietWhenPaneFrontmost)) {
                SettingLabel(title: "Quiet while you watch",
                             subtitle: "An ask whose terminal pane is already in front gets no pulse, chime or sound — the banner still lands for the record.")
            }

            if utility.onOpenOverview != nil {
                HStack {
                    SettingLabel(title: "Sessions",
                                 subtitle: "Every session and its verbs are in the panel and the Overview.")
                    Spacer(minLength: 10)
                    Button("Open the Overview") { utility.openFullOverview() }
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }
}
