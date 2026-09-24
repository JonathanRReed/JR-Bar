import JRBarCore
import SwiftUI

/// The panel's keep-awake line: the one hold (`state.power.hold`) in a few
/// quiet words at the foot of the panel — "Awake · 42 min left", "Awake ·
/// 3 agents working", "Awake paused · too warm" — in the trailing slot of
/// the Devices header, right above the footer's cup mark. The footer row
/// itself has no room to give: its buttons already need all of the
/// panel's fixed 360 pt. Laid over the header, the line never moves a
/// row or changes the panel's computed height (`PanelLayout`), and the
/// header's trailing slot is empty while the monitor is live — the only
/// time there is a hold to name. A countdown steps on its own; nothing
/// else needs a clock. A battery or charger that will not carry the run
/// takes the line, the grace names the time it lets go, a recent release
/// says when and why, and the tooltip lists every power fact.
struct KeepAwakeFooter: View {
    /// `state.power` while the monitor is live; nil otherwise.
    let power: CorePower?

    var body: some View {
        let reading = KeepAwakeReading(power: power)
        if reading.footerLine(now: Date()) != nil {
            Group {
                if reading.showsCountdown {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        line(reading, now: context.date)
                    }
                } else {
                    line(reading, now: Date())
                }
            }
            // The header's own inset and baseline.
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func line(_ reading: KeepAwakeReading, now: Date) -> some View {
        if let words = reading.footerLine(now: now) {
            ViewThatFits(in: .horizontal) {
                label(words.full)
                label(words.short)
            }
            .help(([words.full] + reading.facts()).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.full)
            // The line names the hold; a right-click on it changes it.
            .contextMenu { KeepAwakeMenuItems() }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}
