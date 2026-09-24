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

    /// The grace a stray reading gets before the panel closes — covers
    /// the gap between dock and panel and jitter across item edges.
    static let grace: TimeInterval = 0.22
    /// How long a reading of "no tile" is forgiven before the rest
    /// clock restarts: the pointer crossing the seam between two
    /// tiles reads as nothing for a tick, and a sweep along the Dock
    /// never opened anything when each seam started the clock over.
    static let seamGrace: TimeInterval = 0.12

    @discardableResult
    mutating func note(hovered item: String?, pointerInPanel: Bool,
                       now: TimeInterval, delay: TimeInterval) -> Action {
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
        // A rested item opens — or retargets — the panel.
        if let item, shown != item, let since = hoveredSince, now - since >= delay {
            shown = item
            return .show(item)
        }
        // Off the dock, off the panel, past the grace — close.
        if shown != nil, item == nil, !pointerInPanel,
           let left = emptySince, now - left >= Self.grace {
            shown = nil
            return .hide
        }
        return .none
    }

    mutating func reset() {
        hovered = nil
        shown = nil
        hoveredSince = nil
        emptySince = nil
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
