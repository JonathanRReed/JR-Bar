import Foundation
import JRBarCore

/// The words the Menu Bar card and its notes use for the position model,
/// in one place so a test pins every sentence. Plain, in the person's
/// terms: what is hidden, what is shown, what one gesture does.
enum MenuBarPositionCopy {
    /// The model in one breath — the card's lead.
    static let model = "Position is the setting. Everything left of the JR-Bar icon is hidden; everything right of it stays. Hold ⌘ and drag an item across the icon to change it."

    /// The two ends of the gesture, for the diagram's captions.
    static let hiddenCaption = "Hidden"
    static let shownCaption = "Shown"
    static let hiddenHint = "Drag an item here to hide it"
    static let shownHint = "Drag an item here to keep it"

    /// What JR-Bar can and cannot do for an item, said once and honestly.
    static let cannotMove = "JR-Bar can't move another app's icon for you. Hold ⌘ and drag it yourself; clicking the icon first draws what is hidden so you can reach it."

    /// A pick that needs the person's hand: the gesture that does it.
    static func guide(name: String, to section: MenuBarItemSection, parked: Bool) -> String {
        switch section {
        case .hidden:
            return "Hold ⌘ and drag \(name) left of the JR-Bar icon to hide it."
        case .shown:
            return parked
                ? "\(name) is hidden beyond what the bar can draw at once. Open it from the Item Bar, or hide something else to make room, then hold ⌘ and drag it right of the icon."
                : "Hold ⌘ and drag \(name) right of the JR-Bar icon to keep it shown. The hidden items are drawn now so you can reach it."
        case .alwaysHidden:
            return "Always hidden covers \(name) where it sits."
        }
    }

    /// The engine line the card gives under the diagram.
    static let engineExplanation = "Hiding with the icon as the divider. Nothing here asks macOS to hide anything, so the real icon is always drawn and can be dragged."

    /// The one-line hint a new divider shows until it is closed.
    static let hint = "Hold ⌘ and drag an app left of the JR-Bar icon to hide it"

    /// The suggestions' lead: the old list, offered and never acted on.
    static func suggestionsLead(count: Int) -> String {
        count == 1
            ? "1 saved pick needs a placement check."
            : "\(count) saved picks need placement checks."
    }

    /// One suggested app's line.
    static func suggestionLine(name: String, state: MenuBarSuggestionsContent.State) -> String {
        switch state {
        case .shown: return "\(name) is shown. Hold ⌘ and drag it left of the icon to hide it."
        case .absent:
            if name.hasSuffix(" (not installed)") { return name }
            return "macOS hasn't reported \(name)'s item. Its visibility is unverified."
        }
    }

    /// The card's reach line when a reveal could not draw everything.
    static func remainder(count: Int) -> String {
        count == 1
            ? "1 hidden item doesn't fit on the bar at once. It waits in the Item Bar."
            : "\(count) hidden items don't fit on the bar at once. They wait in the Item Bar."
    }
}
