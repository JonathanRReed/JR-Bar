import Foundation
import SwiftUI

/// One timer on Now: a finished timer waits for dismissal, otherwise
/// the nearest running timer stays visible while the person watches agents.
struct NotchTimerGlance: Equatable {
    enum Action: Equatable { case pause, resume, dismiss }

    let entry: ShelfTimerModel.Entry
    let count: Int
    let action: Action
    let timeText: String

    @MainActor
    init?(entries: [ShelfTimerModel.Entry], now: Date) {
        let done = entries.filter { $0.fired || $0.overdue(at: now) }
        let running = entries.filter { !$0.fired && !$0.paused && !$0.overdue(at: now) }
        let paused = entries.filter { !$0.fired && $0.paused }
        let candidates = !done.isEmpty ? done : !running.isEmpty ? running : paused
        guard let entry = candidates.min(by: {
            let left = $0.remaining(at: now), right = $1.remaining(at: now)
            return left == right ? $0.id < $1.id : left < right
        }) else { return nil }
        self.entry = entry
        count = entries.count
        if entry.fired || entry.overdue(at: now) {
            action = .dismiss
            timeText = "Done"
        } else {
            action = entry.paused ? .resume : .pause
            let remaining = entry.remaining(at: now)
            let seconds = remaining.isFinite
                ? Int(min(ShelfTimerModel.maxDuration, max(0, remaining)).rounded(.up)) : 0
            let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
            timeText = h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                : String(format: "%d:%02d", m, s)
        }
    }

    var actionLabel: String {
        switch action {
        case .pause: "Pause"
        case .resume: "Resume"
        case .dismiss: "Dismiss"
        }
    }

    var symbol: String {
        switch action {
        case .pause: "timer"
        case .resume: "pause.circle.fill"
        case .dismiss: "checkmark.circle.fill"
        }
    }

    /// Re-read the entry when clicked: a countdown can finish between
    /// drawing the pause button and the person pressing it.
    @MainActor
    func perform(on timers: ShelfTimerModel, now: Date = Date()) {
        guard let current = timers.entries.first(where: { $0.id == entry.id }) else { return }
        if current.fired || current.overdue(at: now) {
            // A button that read Pause must not dismiss a timer which
            // finished under the pointer. Its next draw offers Dismiss.
            if action == .dismiss { timers.remove(current) }
        } else if current.paused {
            if action == .resume { timers.resume(current) }
        } else if action == .pause {
            timers.pause(current)
        }
    }
}

struct NotchTimerGlanceRow: View {
    let timers: ShelfTimerModel
    let style: NotchCardStyle
    var onOpenShelf: () -> Void
    /// Render proofs supply a fixed date without starting a timer.
    var stillDate: Date? = nil

    var body: some View {
        if let stillDate {
            row(at: stillDate)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(at: context.date)
            }
        }
    }

    @ViewBuilder
    private func row(at now: Date) -> some View {
        if let glance = NotchTimerGlance(entries: timers.entries, now: now) {
            HStack(spacing: 8) {
                Button(action: onOpenShelf) {
                    HStack(spacing: 7) {
                        Image(systemName: glance.symbol)
                            .font(.system(size: 11, weight: .semibold)) // jrbar-token-exception: preserve the 0.9.17.2 notch layout
                            .foregroundStyle(glance.action == .dismiss ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(glance.entry.label)
                                .font(.system(size: 11, weight: .medium)) // jrbar-token-exception: preserve the 0.9.17.2 notch layout
                                .foregroundStyle(style.titleColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(glance.action == .resume ? "Paused" : glance.count > 1
                                 ? "\(glance.count) timers on Shelf" : "Timer on Shelf")
                                .font(.system(size: 9)) // jrbar-token-exception: preserve the 0.9.17.2 notch layout
                                .foregroundStyle(style.faintColor)
                        }
                        Spacer(minLength: 4)
                        Text(glance.timeText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded)) // jrbar-token-exception: preserve the 0.9.17.2 notch layout
                            .monospacedDigit()
                            .foregroundStyle(style.subColor)
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show all timers on Shelf")
                .accessibilityLabel("\(glance.entry.label), \(glance.timeText)\(glance.action == .resume ? ", paused" : "")")
                .accessibilityHint("Show all timers on Shelf")

                Button { glance.perform(on: timers) } label: {
                    Text(glance.actionLabel)
                        .font(.system(size: 10, weight: .medium)) // jrbar-token-exception: preserve the 0.9.17.2 notch layout
                        .foregroundStyle(style.subColor)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(style.chipFill, in: Capsule())
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(glance.actionLabel) \(glance.entry.label) timer")
            }
            .padding(8)
            .background(style.chipFaint, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
