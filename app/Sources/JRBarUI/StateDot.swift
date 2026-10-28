import SwiftUI

public struct StateDot: View {
    @Environment(\.jrbarInk) private var neutralInk
    public enum State: String, CaseIterable, Sendable {
        case working, asking, done, failed, stale, live

        public var breathDuration: Double? {
            switch self {
            case .working: 1.6
            case .asking: 1
            default: nil
            }
        }

        var ink: Color {
            switch self {
            case .working: Tone.working.color
            case .asking: Tone.ask.color
            case .done: Tone.done.color
            case .failed: Tone.failure.color
            case .stale: Tone.stale.color
            case .live: Tone.live.color
            }
        }
    }

    public let state: State
    private var overrideTone: Tone?
    private var overrideLabel: String?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.jrbarReduceMotion) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    /// Hosted breathing dots, used to verify that closed views stop animating.
    @MainActor public static private(set) var activePulses = 0

    public init(_ state: State) { self.state = state }
    /// The state's dot with its own spoken word, for states that share a
    /// dot: an idle, an ended and a stale row are all grey.
    public init(_ state: State, label: String) {
        self.state = state
        self.overrideLabel = label
    }
    public init(tone: Tone, label: String) {
        self.state = .stale
        self.overrideTone = tone
        self.overrideLabel = label
    }

    public var body: some View {
        Group {
            if let overrideTone {
                Circle().fill(overrideTone.color).frame(width: 8, height: 8)
            } else if let duration = state.breathDuration, !reduceMotion {
                BreathingDot(ink: state.ink, duration: duration).id(state)
            } else {
                Circle().fill(state == .stale ? neutralInk.tertiary : state.ink).frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(overrideLabel ?? state.rawValue.capitalized)
    }

    private struct BreathingDot: View {
        let ink: Color
        let duration: Double
        @UIState private var breathing = false

        var body: some View {
            Circle().fill(ink).frame(width: 8, height: 8)
                .opacity(breathing ? 0.35 : 1)
                .onAppear {
                    StateDot.activePulses += 1
                    withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) { breathing = true }
                }
                .onDisappear { StateDot.activePulses -= 1 }
        }
    }
}
