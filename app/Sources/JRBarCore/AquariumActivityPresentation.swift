import Foundation

/// The visible fish's semantic states, not how fast their sprites move.
/// Residents are counted separately because they no longer represent a run.
public enum AquariumActivityPresentation {
    public static let rewardHelp = "Idle fish earn no work-time pearls. Feeding and grown-fish rewards follow separate game rules. Completion rewards are separate and deduplicated."

    public static func summary(states: [FishState], residents: Int, connected: Bool) -> String {
        var parts: [String]
        if connected {
            parts = ["\(states.filter { $0 == .swimming }.count) working"]
            let idle = states.filter { $0 == .idling }.count
            if idle > 0 || (states.isEmpty && residents == 0) { parts.append("\(idle) idle") }
            let waiting = states.filter { $0 == .surfacing }.count
            if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
            let settled = states.filter { $0 == .sinking }.count
            if settled > 0 { parts.append("\(settled) settled") }
            let leaving = states.filter { $0 == .leaving }.count
            if leaving > 0 { parts.append("\(leaving) leaving") }
        } else {
            parts = ["Disconnected", "0 confirmed working"]
            if !states.isEmpty {
                parts.append("\(states.count) last-known session\(states.count == 1 ? "" : "s")")
            }
        }
        if residents > 0 { parts.append("\(residents) resident\(residents == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
