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

/// The Advanced rows for where things stand: the icon's seat, where new
/// apps go, the clock and Control Center, and the layout table.
struct MenuBarPlacementRows: View {
    let utility: MenuBarUtility

    var body: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.curation.newItems)) {
                Text("Where macOS puts them").tag(MenuBarNewItemsPlacement.asPlaced)
                Text("Shown").tag(MenuBarNewItemsPlacement.shown)
                Text("Hidden").tag(MenuBarNewItemsPlacement.hidden)
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
        } label: {
            SettingLabel(title: "New menu bar items",
                         subtitle: "An app's first item: ask on the ear, keep it shown, or tuck it away.")
        }
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
            MenuBarLayoutTableRows(utility: utility)
        }
    }
}

/// macOS's layout table: the grant, what was read, and the apps whose
/// section and place disagree, each with its one-click fix.
struct MenuBarLayoutTableRows: View {
    let utility: MenuBarUtility

    private var granted: Bool { utility.settings().curation.layoutTableBookmark != nil }

    private var status: String {
        guard granted else {
            return "Pick macOS's own record of your bar's order once, and JR-Bar reads it: a ⌘-drag still confirms when Accessibility is slow to answer, the Item Bar follows macOS's order, and on the slot seat a mismatch shows here. Never written."
        }
        if let failure = utility.layoutTableReader.failure { return failure }
        guard let table = utility.layoutTable else { return "Reading…" }
        return "Read \(table.entries.count) items — the Item Bar and the editor follow this order."
    }

    var body: some View {
        LabeledContent {
            if granted {
                Button("Forget") { utility.forgetLayoutTable() }
                    .controlSize(.small)
                    .fixedSize()
            } else {
                Button("Grant access…") { utility.grantLayoutTable() }
                    .controlSize(.small)
                    .fixedSize()
            }
        } label: {
            SettingLabel(title: "Menu bar layout table", subtitle: status)
        }
        ForEach(utility.layoutTableMismatches) { mismatch in
            HStack(spacing: SettingsMetrics.s) {
                CardNote(Self.words(mismatch, name: name(of: mismatch.app)),
                         symbol: "arrow.left.arrow.right", tint: .orange)
                Spacer(minLength: SettingsMetrics.s)
                Button(mismatch.fix == .shown ? "Show it" : "Hide it") {
                    utility.fixLayoutMismatch(mismatch)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func name(of app: String) -> String {
        (utility.listedItems.first { $0.bundleID == app } ?? utility.knownItems[app]?.first)?.ownerName ?? app
    }

    /// A mismatch in the card's words.
    static func words(_ mismatch: MenuBarLayoutTable.Mismatch, name: String) -> String {
        mismatch.side == .right
            ? "\(name) is hidden but sits right of the icon — a reveal brings it back there."
            : "\(name) is shown but sits left of the icon."
    }
}

/// "Relaunch menu bar apps": items take a new spacing only as their
/// apps relaunch. A confirm lists every app it will quit and reopen;
/// nothing runs on its own, and Apple's agents are never touched.
struct MenuBarSpacingRelaunchRow: View {
    let utility: MenuBarUtility
    @ViewState private var confirming = false

    var body: some View {
        let apps = utility.spacingRelaunchApps
        let names = apps.map(\.name).joined(separator: ", ")
        LabeledContent {
            Button(utility.relaunchingApps.isEmpty ? "Relaunch…" : "Relaunching…") { confirming = true }
                .controlSize(.small)
                .fixedSize()
                .disabled(apps.isEmpty || !utility.relaunchingApps.isEmpty)
        } label: {
            SettingLabel(title: "Relaunch menu bar apps",
                         subtitle: "Items take a new spacing as their apps relaunch. This quits and reopens the apps with items on your bar, never Apple's own.")
        }
        .confirmationDialog("Relaunch \(apps.count) menu bar apps?", isPresented: $confirming) {
            Button("Relaunch") { utility.relaunchForSpacing(apps.map(\.bundleID)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("JR-Bar asks each to quit and opens it again in the background: \(names).")
        }
    }
}
