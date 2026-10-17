import SwiftUI

enum MenuBarInventoryState: Equatable, Sendable {
    case unavailable, checking, partial, complete

    static func assess(granted: Bool, generation: Int, complete: Bool) -> Self {
        guard granted else { return .unavailable }
        if complete { return .complete }
        return generation > 0 ? .partial : .checking
    }
}

struct MenuBarInventoryNotice: View {
    let state: MenuBarInventoryState

    var body: some View {
        switch state {
        case .checking:
            CardNote("Checking which apps have menu bar items.", symbol: "clock")
        case .partial:
            CardNote("Some apps haven't answered yet. The list may be incomplete or include last known items.",
                     symbol: "exclamationmark.triangle")
        case .unavailable, .complete:
            EmptyView()
        }
    }
}
