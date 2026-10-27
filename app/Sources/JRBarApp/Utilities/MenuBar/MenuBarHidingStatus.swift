import Foundation
import JRBarCore

/// What the Menu Bar page tells the person about hiding, right now, in
/// one place: whether it works, and when it does not, why and what one
/// click puts right. It speaks for the cases that read as "broken":
/// JR-Bar's icon having no room on a crowded bar, nothing hidden yet, a
/// "Show all" that was really a restore. Pure over its inputs so a test
/// pins every line and every fix.
///
/// The model it speaks for is one sentence. Everything left of the icon
/// is hidden and everything right of it stays. Hidden items come back
/// from a hover or a click on the blank bar, or from the Item Bar.
/// Showing everything, or turning the utility off, always gives every
/// item back.
struct MenuBarHidingStatus: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Hiding works; the line only reminds how to reach things.
        case ok
        /// Hiding works differently than the person might expect, or has
        /// not begun.
        case note
        /// Hiding is paused or impossible, or the way back is hard to see.
        case warning
    }

    /// The one-click answers. The card draws the button; the utility
    /// performs it (`MenuBarUtility.perform(fix:)`).
    enum Fix: Equatable, Sendable {
        /// Every item back, on a standing overlay that keeps the picks.
        case showEverything
        /// The hidden picks back after a Show all or Hide all.
        case restoreBar
        case openAccessibility
        case quitRival(String)
        /// The whole utility off: every item back, nothing running.
        case turnOff
        /// Take the picked counterpart's name and open it.
        case openProvider
    }

    var tone: Tone
    var headline: String
    var detail: String
    /// The button that answers the headline, if one does.
    var fix: Fix?
    var fixTitle: String?
    /// Whether the banner also offers "Show everything" on its own:
    /// something is hidden, or hiding is meant to be.
    var offersShowEverything: Bool

    struct Inputs: Equatable, Sendable {
        var enabled: Bool = true
        /// The engine's own health (`MenuBarEngineHealth`).
        var engine: MenuBarEngineHealth = .divider
        /// Another manager renders: its display name, nil while JR-Bar does.
        var externalProvider: String?
        var externalProviderRunning = false
        /// The overlay in force (a Hide all, a Show all, a rule's), with
        /// the clock line when it lapses.
        var overlay: MenuBarOverlay.Kind?
        var overlayNote: String?
        var accessibilityGranted = true
        var inventoryComplete = true
        var rivals: [String] = []
        /// Items left of the icon right now, by position.
        var dividerHidden = 0
        var revealed = false
        var recovery: MenuBarWakeRecovery.Verdict = .idle
        /// The divider found no room for the icon on this bar.
        var noRoom = false
        /// What a crowded bar costs, in items (`MenuBarRoomHelp.line`).
        var noRoomHelp: String?
        /// The icon stands at the left end of the drawn bar: no app is left
        /// of it to hide, so the gesture is to drag the icon itself.
        var iconLeftmost = false
    }

    nonisolated static func assess(_ i: Inputs) -> MenuBarHidingStatus {
        // Off: the guarantee, stated.
        guard i.enabled else {
            return MenuBarHidingStatus(
                tone: .note, headline: "Menu Bar is off",
                detail: "Every item shows exactly as macOS draws it. Your picks are kept for when you turn it back on.",
                fix: nil, fixTitle: nil, offersShowEverything: false)
        }
        if let name = i.externalProvider {
            return MenuBarHidingStatus(
                tone: .note, headline: "\(name) is hiding the bar",
                detail: i.externalProviderRunning
                    ? "JR-Bar's own hiding is parked while \(name) is the pick."
                    : "\(name) isn't running, so nothing is hidden. Open it, or pick JR-Bar again.",
                fix: i.externalProviderRunning ? nil : .openProvider,
                fixTitle: i.externalProviderRunning ? nil : "Open \(name)",
                offersShowEverything: false)
        }
        // A standing overlay explains everything else first.
        if let overlay = i.overlay {
            switch overlay {
            case .showEverything:
                return MenuBarHidingStatus(
                    tone: .note, headline: "Showing everything",
                    detail: i.overlayNote ?? "Every item is on the bar. Your picks are kept.",
                    fix: .restoreBar, fixTitle: "Hide my picks again",
                    offersShowEverything: false)
            case .hideEverything:
                return MenuBarHidingStatus(
                    tone: .note, headline: "Everything is tucked away",
                    detail: i.overlayNote ?? "Every app waits in the Item Bar. Your picks are kept.",
                    fix: .showEverything, fixTitle: "Show everything",
                    offersShowEverything: false)
            }
        }
        // The card is up before the utility has run its first pass.
        if i.engine == .parked {
            return MenuBarHidingStatus(
                tone: .note, headline: "Starting up",
                detail: "JR-Bar is checking how this Mac can hide items.",
                fix: nil, fixTitle: nil, offersShowEverything: false)
        }
        // Problems that need a person's action come before the planned count.
        if let rival = i.rivals.first {
            return MenuBarHidingStatus(
                tone: .warning, headline: "\(rival) is also hiding items",
                detail: "Two managers fight: \(rival)'s hiding can undo what JR-Bar hides, and the other way round.",
                fix: .quitRival(rival), fixTitle: "Quit \(rival)",
                offersShowEverything: true)
        }
        if !i.accessibilityGranted {
            return MenuBarHidingStatus(
                tone: .warning, headline: "Accessibility is off",
                detail: "Without it the Item Bar can't press hidden items for you, and the list can go stale.",
                fix: .openAccessibility, fixTitle: "Open Settings",
                offersShowEverything: true)
        }
        // The divider (Ice's model): the icon is the boundary and position
        // is the setting, so these lines name where things sit.
        if i.noRoom {
            let help = i.noRoomHelp
                ?? "Quit or switch off a menu bar item to give the JR-Bar icon a place."
            return MenuBarHidingStatus(
                tone: .warning, headline: "The bar is too full for the JR-Bar icon",
                detail: "macOS has parked the icon, so nothing can hide by position. \(help) Switch items off in System Settings › Control Center › Menu Bar Only, or quit the apps that draw them.",
                fix: nil, fixTitle: nil, offersShowEverything: true)
        }
        if i.revealed {
            return MenuBarHidingStatus(
                tone: .note, headline: "Showing the hidden section",
                detail: "These items are showing temporarily. ⌘-drag one right of the JR-Bar icon to keep it shown.",
                fix: nil, fixTitle: nil, offersShowEverything: true)
        }
        if !i.inventoryComplete {
            return MenuBarHidingStatus(
                tone: .warning, headline: "Enabled, hiding is unverified",
                detail: "macOS hasn't reported a complete set of items. The counts are from the last complete reading.",
                fix: nil, fixTitle: nil, offersShowEverything: true)
        }
        let placementGuide = i.iconLeftmost
            ? "The JR-Bar icon is at the left end of the reported items. Hold ⌘ and drag the icon right, past the apps you want hidden. Click the blank bar left of the icon to bring them back."
            : "Hold ⌘ and drag an item left of the JR-Bar icon: it disappears. Click the blank bar left of the icon to bring it back, then drag it right of the icon to keep it shown."
        let recoveryDetail = MenuBarWakeRecovery.line(for: i.recovery)
            ?? "JR-Bar has not confirmed that the divider stands on the bar."
        switch i.recovery {
        case .idle:
            return MenuBarHidingStatus(
                tone: .note, headline: "Enabled, hiding has not been checked",
                detail: i.dividerHidden == 0 ? "\(recoveryDetail) \(placementGuide)" : recoveryDetail,
                fix: nil, fixTitle: nil, offersShowEverything: true)
        case .settling:
            return MenuBarHidingStatus(
                tone: .note, headline: "Enabled, checking the divider",
                detail: "The menu bar is settling. JR-Bar will check the divider after a fresh reading.",
                fix: nil, fixTitle: nil, offersShowEverything: true)
        case .reseated:
            return MenuBarHidingStatus(
                tone: .note, headline: "Enabled, checking the divider",
                detail: recoveryDetail,
                fix: nil, fixTitle: nil, offersShowEverything: true)
        case .unverified:
            return MenuBarHidingStatus(
                tone: .warning, headline: "Enabled, hiding is unverified",
                detail: recoveryDetail,
                fix: nil, fixTitle: nil, offersShowEverything: true)
        case .stuck:
            return MenuBarHidingStatus(
                tone: .warning, headline: "Divider needs checking",
                detail: recoveryDetail,
                fix: nil, fixTitle: nil, offersShowEverything: true)
        case .clear, .recovered:
            break
        }
        if i.dividerHidden == 0 {
            return MenuBarHidingStatus(
                tone: .note, headline: "No hidden items reported",
                detail: placementGuide,
                fix: nil, fixTitle: nil, offersShowEverything: true)
        }
        let noun = i.dividerHidden == 1 ? "item" : "items"
        return MenuBarHidingStatus(
            tone: .ok, headline: "Hiding \(i.dividerHidden) \(noun) left of the icon",
            detail: "Click the icon to reveal them. ⌘-drag one right of the icon to bring it back for good, or left of it to hide it.",
            fix: nil, fixTitle: nil, offersShowEverything: true)
    }
}
