import Foundation
import JRBarCore

/// The inspector's menu follows the fish still drawn in the tank.
enum AquariumInspection {
    static func visibleFish(_ fish: [Fish], at now: Date) -> [Fish] {
        fish.filter { !$0.isRetired(at: now) }
    }

    /// No deadline when every fish is stable or already gone. Fry retire too.
    static func nextRetirement(_ fish: [Fish], after now: Date) -> Date? {
        fish.filter { $0.state == .leaving && !$0.isRetired(at: now) }
            .map { $0.stateSince.addingTimeInterval(AquariumModel.leaveDuration) }.min()
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

/// Keep each shelf short, with purchases before the pieces already owned.
enum AquariumShopShelf {
    static func items(category: ShopItem.Category, game: AquariumGame) -> [ShopItem] {
        let shelf = ShopItem.allCases.filter { $0.category == category }
        return shelf.filter { !game.owns($0) } + shelf.filter { game.owns($0) }
    }
}
