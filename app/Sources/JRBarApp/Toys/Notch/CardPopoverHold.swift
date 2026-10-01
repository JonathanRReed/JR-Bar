import SwiftUI

/// The popovers open on the island's grown card right now.
///
/// A popover is a window of its own that hangs below the card, so the
/// pointer reaching for its field has left the island window, and a card
/// that was grown by hover folds 0.18 s after the pointer leaves. That
/// folded the card out from under the Custom timer entry, a stack's grid
/// and the new-reminder field the moment the person moved toward them. While
/// one is up the card holds; when the last one closes the usual leave check
/// runs again, so a pointer that is no longer over the card folds it then.
///
/// It only counts popovers: the card still lets go on Esc, on a click away
/// and when it is parked, and any of those clears the count, so a popover
/// that never reports its close can never keep a card open.
@MainActor
final class CardPopoverHold {
    private(set) var open: Set<String> = []

    /// A popover hangs from the card.
    var isHeld: Bool { !open.isEmpty }

    /// Told when the card goes from not held to held or back.
    var onChange: (@MainActor (Bool) -> Void)?

    /// A popover opened or closed. `id` names it, so two open at once
    /// release the card only when both have closed.
    func note(_ id: String, open isOpen: Bool) {
        let was = isHeld
        if isOpen { open.insert(id) } else { open.remove(id) }
        if was != isHeld { onChange?(isHeld) }
    }

    /// The card folded or was parked: whatever it held goes with it.
    func releaseAll() {
        guard isHeld else { return }
        open.removeAll()
        onChange?(false)
    }
}

private struct CardPopoverHoldKey: EnvironmentKey {
    static let defaultValue: CardPopoverHold? = nil
}

extension EnvironmentValues {
    /// The hold the card's popovers report to; nil outside a card.
    var cardPopoverHold: CardPopoverHold? {
        get { self[CardPopoverHoldKey.self] }
        set { self[CardPopoverHoldKey.self] = newValue }
    }
}

extension View {
    /// Tell the card a popover hangs from this view while `shown`. The
    /// view going away counts as the popover closing.
    func holdsCard(_ hold: CardPopoverHold?, id: String, while shown: Bool) -> some View {
        self
            .onChange(of: shown) { _, now in hold?.note(id, open: now) }
            .onDisappear { hold?.note(id, open: false) }
    }
}
