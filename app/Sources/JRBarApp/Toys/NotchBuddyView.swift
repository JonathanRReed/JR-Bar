import AppKit
import JRBarCore
import SwiftUI

/// The buddy itself: a small drawn blob with two eyes, one character
/// ("dot") to start. Pose and tint come from `NotchBuddyToy.mood`;
/// `TimelineView(.animation)` drives the drift/bob/hop, and Reduce
/// Motion swaps the moving poses for still ones.
struct NotchBuddyView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window a hop plays across; `NotchBuddyToy.hopUntil` sets it.
    private static let hopDuration: TimeInterval = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let mood = toy.mood(at: context.date)
            DotBuddy(
                mood: mood,
                phase: context.date.timeIntervalSince1970,
                hopProgress: hopProgress(at: context.date),
                still: reduceMotion
            )
        }
        .frame(width: 18, height: 18)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .fixedSize()
        .accessibilityLabel("Notch Buddy")
    }

    /// 0→1 across the hop; nil when no hop is playing.
    private func hopProgress(at now: Date) -> Double? {
        guard let hopUntil = toy.hopUntil else { return nil }
        let remaining = hopUntil.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return 1.0 - remaining / Self.hopDuration
    }
}

/// The "dot" character: one round body, two eyes. Drawn from shapes so
/// each mood is just a pose — slump squashes, pace drifts, the wave
/// leans, the hop rises and falls once.
private struct DotBuddy: View {
    let mood: NotchBuddyToy.Mood
    /// Seconds, monotonic — the animation clock.
    let phase: TimeInterval
    /// 0→1 while a completion hop plays, else nil.
    let hopProgress: Double?
    /// Reduce Motion: poses stay, motion goes.
    let still: Bool

    private var tint: Color {
        switch mood {
        case .asleep: return Color(nsColor: .tertiaryLabelColor)
        case .pacing: return .accentColor
        case .waving: return .orange
        case .slumped: return .red
        case .celebrating: return .green
        }
    }

    /// Centre offset and squash for the pose at this instant.
    private var offset: CGSize {
        guard !still else { return .zero }
        switch mood {
        case .asleep:
            // A slow breath: barely there.
            return CGSize(width: 0, height: sin(phase * 1.2) * 0.7)
        case .pacing:
            return CGSize(width: sin(phase * 2.6) * 3.0, height: 0)
        case .waving:
            return CGSize(width: 0, height: -abs(sin(phase * 4.0)) * 1.5)
        case .slumped:
            return CGSize(width: 0, height: 1.5)
        case .celebrating:
            guard let hopProgress else { return .zero }
            return CGSize(width: 0, height: -sin(hopProgress * .pi) * 6)
        }
    }

    private var squash: CGSize {
        guard !still else { return mood == .slumped ? CGSize(width: 1.2, height: 0.75) : CGSize(width: 1, height: 1) }
        switch mood {
        case .slumped: return CGSize(width: 1.2, height: 0.75)
        case .celebrating:
            // Stretch on the way up, land flat: squash and stretch.
            guard let hopProgress else { return CGSize(width: 1, height: 1) }
            let stretch = sin(hopProgress * .pi) * 0.25
            return CGSize(width: 1 - stretch * 0.6, height: 1 + stretch)
        default: return CGSize(width: 1, height: 1)
        }
    }

    private var lean: Double {
        guard !still, mood == .waving else { return 0 }
        return sin(phase * 4.0) * 10
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: 11, height: 11)
            eyes
        }
        .scaleEffect(x: squash.width, y: squash.height)
        .rotationEffect(.degrees(lean))
        .offset(offset)
    }

    /// Open dots while awake; flat lines while asleep or slumped.
    @ViewBuilder private var eyes: some View {
        switch mood {
        case .asleep, .slumped:
            HStack(spacing: 2.5) {
                Capsule().frame(width: 2.4, height: 0.9)
                Capsule().frame(width: 2.4, height: 0.9)
            }
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        case .pacing:
            // Looking the way it is walking.
            HStack(spacing: 2.5) {
                Circle().frame(width: 1.8, height: 1.8)
                Circle().frame(width: 1.8, height: 1.8)
            }
            .offset(x: cos(phase * 2.6) * 1.2, y: -1)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        case .waving, .celebrating:
            HStack(spacing: 2.5) {
                Circle().frame(width: 1.8, height: 1.8)
                Circle().frame(width: 1.8, height: 1.8)
            }
            .offset(y: -1)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        }
    }
}
