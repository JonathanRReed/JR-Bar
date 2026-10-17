import Foundation
import JRBarCore

/// The inspector's menu follows the fish still drawn in the tank.
enum AquariumInspection {
    static func visibleFish(_ fish: [Fish], at now: Date) -> [Fish] {
        fish.filter { !$0.isRetired(at: now) }
    }

    static func title(for fish: Fish, connected: Bool) -> String {
        var parts = [fish.label, fish.providerID]
        if fish.isResident {
            parts.append("Resident")
        } else {
            if fish.isFry { parts.append("Worker") }
            switch fish.state {
            case .swimming: parts.append("Working")
            case .idling: parts.append("Idle")
            case .surfacing: parts.append("Needs you")
            case .sinking: parts.append("Failed")
            case .leaving: parts.append("Finished")
            }
            if !connected { parts.append("Last known") }
        }
        return parts.joined(separator: " · ")
    }
}
