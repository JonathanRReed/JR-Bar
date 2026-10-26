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
            case .working: JRBarTokens.Ink.working
            case .asking: JRBarTokens.Ink.attention
            case .done: JRBarTokens.Ink.done
            case .failed: JRBarTokens.Ink.failure
            case .stale: JRBarTokens.Ink.tertiary
            case .live: JRBarTokens.Ink.live
            }
        }
    }

    public let state: State
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.jrbarReduceMotion) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    /// Hosted breathing dots, used to verify that closed views stop animating.
    @MainActor public static private(set) var activePulses = 0

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Group {
            if let duration = state.breathDuration, !reduceMotion {
                BreathingDot(ink: state.ink, duration: duration).id(state)
            } else {
                Circle().fill(state == .stale ? neutralInk.tertiary : state.ink).frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(state.rawValue.capitalized)
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
