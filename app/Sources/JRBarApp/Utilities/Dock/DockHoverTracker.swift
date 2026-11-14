import AppKit
import JRBarCore

// MARK: - Hover debounce (pure, tested)

/// The state machine behind hover previews: a dock item must hold the
/// pointer for `delay` before its panel opens; once open, the panel
/// survives quick trips across other icons and the gap onto the panel
/// itself, and only closes after the pointer has been off both the
/// dock and the panel for `grace`.
struct DockHoverTracker {
    enum Action: Equatable {
        case none
        /// The named item earned a panel (first show or a retarget).
        case show(String)
        /// Pointer is gone — close the panel.
        case hide
    }

    private(set) var hovered: String?
    private(set) var shown: String?
    private var hoveredSince: TimeInterval?
    private var emptySince: TimeInterval?
    private var offBothSince: TimeInterval?

    /// The grace a stray reading gets before the panel closes — covers
    /// the gap between dock and panel and jitter across item edges.
    static let grace: TimeInterval = 0.22
    /// How long a reading of "no tile" is forgiven before the rest
    /// clock restarts: the pointer crossing the seam between two
    /// tiles reads as nothing for a tick, and a sweep along the Dock
    /// never opened anything when each seam started the clock over.
    static let seamGrace: TimeInterval = 0.12

    /// The rest a second tile needs once a panel is open. The first show
    /// waits out the person's own delay, which keeps a pointer passing
    /// over the Dock from opening anything; with a panel already up the
    /// intent is settled, and paying the full delay again on every tile
    /// made a sweep along the Dock feel like separate hovers.
    static let retargetDelay: TimeInterval = 0.06

    /// The rest `item` needs before it takes the panel: the full delay
    /// for a first show, and for a pointer that is on its way up to the
    /// open panel and only crossing a neighbour; the short one for a
    /// second tile the pointer came to along the Dock.
    static func rest(delay: TimeInterval, panelOpen: Bool, aimingAtPanel: Bool) -> TimeInterval {
        guard panelOpen, !aimingAtPanel else { return delay }
        return min(delay, retargetDelay)
    }

    @discardableResult
    mutating func note(hovered item: String?, pointerInPanel: Bool,
                       now: TimeInterval, delay: TimeInterval,
                       aimingAtPanel: Bool = false) -> Action {
        let delay = Self.rest(delay: delay, panelOpen: shown != nil, aimingAtPanel: aimingAtPanel)
        if let item {
            if item != hovered {
                hovered = item
                hoveredSince = now
            }
            emptySince = nil
        } else {
            if emptySince == nil { emptySince = now }
            if let left = emptySince, now - left >= Self.seamGrace {
                hovered = nil
                hoveredSince = nil
            }
        }
        if item != nil || pointerInPanel {
            offBothSince = nil
        } else if offBothSince == nil {
            offBothSince = now
        }
        // A rested item opens — or retargets — the panel.
        if let item, shown != item, let since = hoveredSince, now - since >= delay {
            shown = item
            return .show(item)
        }
        // Off the dock, off the panel, past the grace — close.
        if shown != nil, item == nil, !pointerInPanel,
           let left = offBothSince, now - left >= Self.grace {
            shown = nil
            return .hide
        }
        return .none
    }

    /// The show this tracker granted was abandoned before its panel came
    /// up: the pointer settled somewhere else while the app's windows
    /// were still being read. `item` is the tile whose panel is on screen
    /// now, nil for none, and the tracker goes on from there: the tile
    /// under the pointer earns its own show, and an open panel the
    /// pointer has left closes after the usual grace.
    mutating func abandonShow(backTo item: String?) {
        shown = item
    }

    mutating func reset() {
        hovered = nil
        shown = nil
        hoveredSince = nil
        emptySince = nil
        offBothSince = nil
    }

    /// A deliberate summon — a middle click or an upward scroll on the
    /// tile — opens the panel now, without waiting out the rest; from
    /// there the usual grace rules close it. The same tile again is a
    /// no-op (the caller decides whether a repeat means "close").
    @discardableResult
    mutating func summon(_ item: String, now: TimeInterval) -> Action {
        hovered = item
        hoveredSince = now
        emptySince = nil
        offBothSince = nil
        guard shown != item else { return .none }
        shown = item
        return .show(item)
    }

    /// What the tick hands `note` under a trigger mode: every tile for
    /// Hover; with ⌥ only a tile rested on while ⌥ is held; for Middle
    /// Click nothing rests open a panel. The tile already shown always
    /// passes, so letting go of ⌥ — or never having pressed it — doesn't
    /// close the panel under the pointer.
    static func trackedItem(_ hovered: String?, shown: String?,
                            trigger: DockPreviewTrigger, optionHeld: Bool) -> String? {
        guard let hovered else { return nil }
        if hovered == shown { return hovered }
        switch trigger {
        case .hover: return hovered
        case .optionHover: return optionHeld ? hovered : nil
        case .middleClick: return nil
        }
    }
}

/// Which way the pointer is going, read over a short window: the pointer's
/// moves can run the tick many times in a few milliseconds, and the
/// distance between two such readings says nothing about a direction.
struct DockPointerAim {
    /// The shortest stretch a direction is read over.
    static let window: TimeInterval = 0.03

    private var reference: (point: CGPoint, at: TimeInterval)?
    private(set) var aimingAtPanel = false

    /// Note where the pointer is now; answers whether it is heading off
    /// the Dock toward the panel.
    mutating func note(pointer: CGPoint, at now: TimeInterval, edge: DockEdge) -> Bool {
        guard let reference else {
            self.reference = (pointer, now)
            return aimingAtPanel
        }
        guard now - reference.at >= Self.window else { return aimingAtPanel }
        aimingAtPanel = DockEnhanceMath.aimsAtPanel(from: reference.point, to: pointer, edge: edge)
        self.reference = (pointer, now)
        return aimingAtPanel
    }
}
