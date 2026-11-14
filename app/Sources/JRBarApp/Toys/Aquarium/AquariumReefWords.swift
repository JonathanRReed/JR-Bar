import Foundation
import JRBarCore

/// Which page of the tank's sheet is showing.
enum TankSheetPage: Hashable, Sendable {
    case reef, shop, goals
}

/// The Reef page's sentences, kept apart from the view so they can be
/// read and tested as words.
enum TankReefWords {
    static func symbol(_ builder: ReefBuilder) -> String {
        switch builder {
        case .kelp: "leaf.fill"
        case .oyster: "circle.circle.fill"
        case .anemone: "sparkles"
        case .tide: "water.waves"
        }
    }

    /// A pearl amount in words: whole from a hundred up, one decimal
    /// below, and never a trailing ".0".
    static func pearls(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value >= 100 { return Int(value.rounded()).formatted() }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// What the builder pays now, or what it takes to open it, and when
    /// its yield next doubles.
    static func line(_ builder: ReefBuilder, game: AquariumGame) -> String {
        let level = game.reef.level(builder)
        switch game.growDenial(builder) {
        case .locked(let needs):
            return "Opens at tank level \(needs). \(builder.detail)"
        default:
            break
        }
        guard level > 0 else {
            let first = AquariumReef.rate(builder, level: 1, careBonus: game.reefCareBonus)
            return "\(builder.detail) The first level pays \(pearls(first)) pearls \(builder.unitWords)."
        }
        var text = "\(pearls(game.reefRate(builder))) pearls \(builder.unitWords)."
        if case .full(let cap) = game.growDenial(builder) {
            text += " As big as this tank holds; level \(cap + 1) opens with the next tank level."
        } else if let next = AquariumReef.nextMilestone(after: level) {
            text += " Doubles at level \(next)."
        }
        let waiting = game.reef.waiting(at: builder)
        if waiting > 0 { text += " \(waiting.formatted()) waiting." }
        return text
    }

    /// What the tank around the reef adds, in a sentence.
    static func care(_ game: AquariumGame) -> String {
        let bonus = game.reefCareBonus
        let raised = min(AquariumRules.maxResidents,
                         game.pets.values.filter { $0.stage >= AquariumRules.maxStage }.count)
        let decor = ShopItem.allCases.filter { $0.category == .decor && game.shows($0) }.count
        guard bonus > 0 else {
            return "Every builder pays more in a tank that is looked after: 5 % for each fish you raise, 2 % for each day of a streak, 1 % for each decor piece on the sand."
        }
        var parts: [String] = []
        if raised > 0 { parts.append("\(raised) raised fish") }
        if game.streakDays > 0 { parts.append("a \(game.streakDays)-day streak") }
        if decor > 0 { parts.append("\(decor) decor piece\(decor == 1 ? "" : "s")") }
        return "This tank adds \(Int((bonus * 100).rounded())) % to every builder: \(parts.joined(separator: ", "))."
    }
}
