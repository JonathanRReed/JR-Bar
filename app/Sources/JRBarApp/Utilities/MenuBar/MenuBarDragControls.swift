import AppKit
import JRBarCore
import SwiftUI

/// The Menu Bar card's ⌘-drag rows, under the card's first note: the
/// drag itself, the reveal while dragging, and Apple's extras. Only where
/// macOS's concealer exists — under the spacer engine a ⌘-drag across
/// the icon already is the section, natively.
struct MenuBarDragRows: View {
    let utility: MenuBarUtility

    /// The card's first note: how hiding works on this engine.
    static func cardNote(concealing: Bool, dragToHide: Bool) -> String {
        guard concealing else {
            return "Everything left of the JR-Bar icon is tucked away. ⌘-drag an item across the icon, or drag its tile below, to hide or show it."
        }
        if dragToHide {
            return "⌘-drag an item across the JR-Bar icon, or drag its tile below, to hide or show its app. Apps hide as a whole; hidden apps keep running, and the icon's ‹ brings them back."
        }
        return "Drag an app to Hidden or Always below and macOS hides it. The JR-Bar icon stands at the right end of the gap, with a ‹ that brings hidden items back; hidden apps keep running and stay reachable in the Item Bar."
    }

    var body: some View {
        if utility.concealerAvailable {
            Toggle(isOn: utility.bind(\.curation.dragToHide)) {
                SettingLabel(title: "⌘-drag across the icon hides or shows",
                             subtitle: "Drop an item left of the JR-Bar icon to hide its app, right of it to show it. Hold ⌥ at the drop for Always Hidden.")
            }
            if utility.settings().curation.dragToHide {
                Toggle(isOn: utility.bind(\.curation.revealWhileDragging)) {
                    SettingLabel(title: "Show hidden items while ⌘-dragging",
                                 subtitle: "The hidden run comes in beside the icon for the drag, so a drop can land among it. macOS may drop a drag when the bar changes under it.")
                }
            }
            Toggle(isOn: utility.bind(\.curation.concealAppleExtras)) {
                SettingLabel(title: "Hide Apple's extras like apps",
                             subtitle: "Weather, Passwords and Time Machine hide through macOS instead of getting a cover where they sit. Wi-Fi, the clock and Control Center stay macOS's.")
            }
        }
    }
}

/// "Item Bar opens at": under the icon's ‹, or under the pointer.
struct MenuBarItemBarAnchorRow: View {
    let utility: MenuBarUtility

    var body: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.curation.itemBarAt)) {
                Text("The icon").tag(MenuBarItemBarAnchor.icon)
                Text("The pointer").tag(MenuBarItemBarAnchor.pointer)
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
        } label: {
            SettingLabel(title: "Item Bar opens at",
                         subtitle: "Under the icon's ‹, or wherever the pointer is.")
        }
    }
}

/// The Advanced rows for where things stand: the icon's seat and the
/// clock and Control Center.
struct MenuBarPlacementRows: View {
    let utility: MenuBarUtility

    var body: some View {
        if utility.concealerAvailable {
            LabeledContent {
                Picker(selection: utility.bind(\.curation.mirrorSeat)) {
                    Text("Beside the first shown item").tag(MenuBarMirrorSeat.gap)
                    Text("On JR-Bar's own slot").tag(MenuBarMirrorSeat.slot)
                } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
            } label: {
                SettingLabel(title: "Icon seat",
                             subtitle: "On its own slot, left of the icon is macOS's own order; the slot takes the icon's width.")
            }
            Toggle(isOn: utility.bind(\.curation.concealSystemItems)) {
                SettingLabel(title: "Hide the clock and Control Center",
                             subtitle: "Experimental: lets a ⌘-drag hide them through macOS's own list. Wi-Fi, the battery and sound always stay.")
            }
        }
    }
}
