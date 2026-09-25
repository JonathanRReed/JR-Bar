import AppKit
import JRBarCore

/// What `NotchToy.reconcile` depends on from the inputs its observation
/// watches, with the churn left out. Two docs that reduce to equal
/// inputs need no second reconcile: nothing the island draws, sizes or
/// gates on could have moved between them.
struct NotchReconcileInputs: Equatable {
    /// The card's own inputs, carried only while it is grown.
    struct Card: Equatable {
        /// The header's focus — `PanelStore.screenBarFocus`.
        var focus: ScreenBarFocus?
        /// Where each live session works, for the shelf.
        var homes: [ShelfTrayModel.SessionHome]
    }

    var notch: NotchSettings
    var summary: NotchIslandSummary
    var asks: [CoreAsk]
    var meters: [NotchIslandMeter]
    var focus: CoreFocus?
    /// `core.settings?.generation` — the int, not the document, so the
    /// gate's compare stays O(1). A republished identical doc reconciles
    /// once extra; the daemon rarely does that.
    var settingsGeneration: Int?
    var screenBarShown: Bool
    var displayVersion: Int
    var mirror: ShelfMirrorModel.State
    var page: NotchCardModel.Page
    var card: Card?
}
