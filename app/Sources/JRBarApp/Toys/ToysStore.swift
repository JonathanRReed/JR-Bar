import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Owns the toy objects and `ToysState`, the persisted half of the Toys
/// page (docs/TOYS.md). Created once in `AppDelegate` next to
/// `SettingsStore`; the page reaches it through `SettingsStore.toys`.
///
/// Persistence rides the app's own `app-state.json`: the delegate hands
/// back a single `onPersist` that drops `state` into the `AppState` it
/// already owns, so there is exactly one writer of the file and a toys
/// save can never clobber the delegate's fields (or the other way
/// around). Writes are debounced 300 ms — sliders would otherwise stream
/// a file write per tick.
@MainActor
@Observable
final class ToysStore {
    let core: CoreModel
    /// The daemon-document store: Alcove's follow toggle is a real
    /// setting (`screen_bar_follow_alcove`) written through it.
    let settings: SettingsStore

    /// Everything the toys persist; mirrors `AppState.toys`.
    var state: ToysState {
        didSet { scheduleSave() }
    }

    /// The cards, in contract order: Fold, Aquarium, Notch Buddy,
    /// Confetti, Alcove. The page renders whatever is here.
    private(set) var toys: [any Toy]

    /// Typed handles for the toys that other parts of the app drive:
    /// the HUD hosts the buddy, the event coordinator fires confetti,
    /// the page lists the external apps.
    let notchBuddy: NotchBuddyToy
    let confetti: ConfettiToy
    let externalApps: ExternalAppsToy

    /// The island asks the fold whether its overlay owns the screen.
    /// Found in `toys`, not stored: `FoldToy` takes `store: self` in its
    /// init, so it can't sit in a stored property.
    var fold: FoldToy? { toys.lazy.compactMap { $0 as? FoldToy }.first }

    /// Drops `state` into the delegate's `AppState` and writes the file.
    var onPersist: (@MainActor (ToysState) -> Void)?

    /// The capsule Alcove's follower currently sees, poked in from the
    /// delegate's `AlcoveFollower.onChange` so the Alcove card can quote
    /// its width.
    var alcoveCapsule: AlcoveCapsule?

    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(core: CoreModel, settings: SettingsStore, state: ToysState) {
        self.core = core
        self.settings = settings
        self.state = state
        // Toys take `store: self`, so they are built only once every
        // stored property above has a value and `self` is complete.
        let notchBuddy = NotchBuddyToy(core: core)
        let confetti = ConfettiToy()
        let externalApps = ExternalAppsToy()
        self.notchBuddy = notchBuddy
        self.confetti = confetti
        self.externalApps = externalApps
        self.toys = []
        var cards: [any Toy] = []
        cards.append(FoldToy(core: core, store: self))
        cards.append(AquariumToy(core: core, store: self))
        notchBuddy.store = self
        cards.append(notchBuddy)
        confetti.store = self
        cards.append(confetti)
        cards.append(AlcoveToy(core: core, store: self))
        externalApps.store = self
        self.toys = cards
    }

    // MARK: Persistence

    /// A burst of slider/toggle edits becomes one write, last wins.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes `state` now; also the debounce's target. Never throws — the
    /// delegate logs a failed write the way `persistAppState` does.
    func save() {
        saveWork?.cancel()
        saveWork = nil
        onPersist?(state)
    }

    // MARK: Alcove

    /// The delegate's `AlcoveFollower.onChange` lands here.
    func noteAlcoveCapsule(_ capsule: AlcoveCapsule?) {
        alcoveCapsule = capsule
    }

    // MARK: External apps

    /// Called once after launch: opens every external toy app the user
    /// flagged "Launch with JR-Bar" that is not already running.
    func launchExternalAppsAtStartup() {
        externalApps.launchAtStartup()
    }
}
