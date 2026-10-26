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
    @UIState private var breathing = false

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Circle().fill(state == .stale ? neutralInk.tertiary : state.ink).frame(width: 8, height: 8)
            .opacity(breathing && !reduceMotion ? 0.35 : 1)
            .task(id: "\(state.rawValue)-\(reduceMotion)") {
                breathing = false
                if let duration = state.breathDuration, !reduceMotion {
                    withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) { breathing = true }
                }
            }
            .accessibilityLabel(state.rawValue.capitalized)
    }
}
