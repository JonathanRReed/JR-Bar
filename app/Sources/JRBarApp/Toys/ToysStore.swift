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
    /// Confetti. The Notch toy lives on the Utilities page. The page
    /// renders whatever is here.
    private(set) var toys: [any Toy]

    /// Typed handles for the toys that other parts of the app drive:
    /// the HUD hosts the buddy, the event coordinator fires confetti and
    /// feeds the island's event capsules. `notch` is implicitly
    /// unwrapped for the same reason `fold` is a lookup: `NotchToy`
    /// takes `store: self`, so it can only be built after every stored
    /// property has a value.
    let notchBuddy: NotchBuddyToy
    let confetti: ConfettiToy
    private(set) var notch: NotchToy!

    /// The island asks the fold whether its overlay owns the screen.
    /// Found in `toys`, not stored: `FoldToy` takes `store: self` in its
    /// init, so it can't sit in a stored property.
    var fold: FoldToy? { toys.lazy.compactMap { $0 as? FoldToy }.first }

    /// The event coordinator feeds it quota resets (the submarine).
    var aquarium: AquariumToy? { toys.lazy.compactMap { $0 as? AquariumToy }.first }

    /// Drops `state` into the delegate's `AppState` and writes the file.
    var onPersist: (@MainActor (ToysState) -> Void)?

    /// The capsule Alcove's follower currently sees, poked in from the
    /// delegate's `AlcoveFollower.onChange` so the Alcove card can quote
    /// its width.
    var alcoveCapsule: AlcoveCapsule?

    @ObservationIgnored private var saveWork: DispatchWorkItem?

    /// `cardModel` is the grown island's model — the delegate builds it
    /// on the shared timer/tray stores so the glass card and the island
    /// card can never disagree about a timer or a tray file.
    ///
    /// `aquariumSave` is where the tank keeps its game. The real save is
    /// opt-in: only the app's own store passes `AquariumSaveFile()` (the
    /// state directory). Every other store — any test, whatever its
    /// runtime flag — gets a scratch file of its own, so a test can
    /// neither read the user's real tank nor pay pearls into it.
    init(core: CoreModel, settings: SettingsStore, state: ToysState,
         cardModel: NotchCardModel, notchRuntimeEnabled: Bool = true,
         aquariumSave: AquariumSaveFile? = nil) {
        self.core = core
        self.settings = settings
        self.state = state
        // Toys take `store: self`, so they are built only once every
        // stored property above has a value and `self` is complete.
        let notchBuddy = NotchBuddyToy(core: core)
        let confetti = ConfettiToy()
        self.notchBuddy = notchBuddy
        self.confetti = confetti
        self.toys = []
        var cards: [any Toy] = []
        cards.append(FoldToy(core: core, store: self))
        cards.append(AquariumToy(core: core, store: self,
                                 saveFile: aquariumSave ?? AquariumToy.scratchSave()))
        notchBuddy.store = self
        cards.append(notchBuddy)
        confetti.store = self
        cards.append(confetti)
        let notch = NotchToy(core: core, store: self, cardModel: cardModel,
                             runtimeEnabled: notchRuntimeEnabled)
        self.notch = notch
        // The Notch card renders on the Utilities page — it manages a
        // real macOS surface, so it is a utility, not a toy; `toys`
        // keeps only the page's cards.
        self.toys = cards
    }

    isolated deinit {
        saveWork?.cancel()
        notch?.shutdown()
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

    // MARK: The hinge

    /// The lid's angle as the fold's sensor last read it, in whole
    /// degrees — one shared signal (docs/TOYS.md). The fold publishes it
    /// and never reads it back; the buddy pulls on its nightcap as the
    /// lid comes down. nil until the sensor speaks, and only written
    /// when the whole degree changes, so a lid at rest redraws nothing.
    private(set) var hingeAngle: Double?
    @ObservationIgnored private var hingeSeenAt: Date?

    /// Where the lid reads "on its way down": below the angle a laptop is
    /// used at, above shut.
    static let lidClosingBelow: Double = 60
    static let lidShutAtOrBelow: Double = 5

    func noteHinge(_ angle: Double?, at now: Date = Date()) {
        guard let angle, angle.isFinite else {
            if hingeAngle != nil { hingeAngle = nil }
            hingeSeenAt = nil
            return
        }
        hingeSeenAt = now
        let whole = angle.rounded()
        if hingeAngle != whole { hingeAngle = whole }
    }

    /// The lid is coming down: a fresh reading (the sensor polls at
    /// least 10 times a second while it runs) between shut and the
    /// closing line.
    func lidClosing(at now: Date = Date()) -> Bool {
        guard let angle = hingeAngle, let seen = hingeSeenAt,
              now.timeIntervalSince(seen) < 2 else { return false }
        return angle > Self.lidShutAtOrBelow && angle < Self.lidClosingBelow
    }

    // MARK: The room

    /// A call has the mic or the camera: `PresenceReporter`'s call
    /// fact, fed here (`noteCallPresence`) — the notch's own mic and
    /// camera reading the moment it moves, carried by the daemon's
    /// `state.presence` while it is connected. It outranks the daemon's
    /// quiet and Focus, the most specific reason there is.
    private(set) var onCall = false

    /// The presence edge — mic or camera in use by a call. A held burst
    /// looks at the room again the moment it clears.
    func noteCallPresence(_ onCall: Bool) {
        guard self.onCall != onCall else { return }
        self.onCall = onCall
        confetti.roomChanged()
        aquarium?.roomChanged()
    }

    /// Why the toys are keeping it down right now, or nil when they may
    /// play: nil whenever the page's switch is off. Read from the
    /// daemon's `focus` — the same reading that quiets the lights — plus
    /// call presence.
    func hushReason(now: Date = Date()) -> ToysHush.Reason? {
        guard state.hushDuringQuiet else { return nil }
        let focus = core.state?.focus
        return ToysHush.reason(mode: focus?.mode, source: focus?.source, until: focus?.until,
                               onCall: onCall, now: now)
    }

    // MARK: Search into a card

    /// The card row a Settings search just landed on, by its title — a
    /// card that folds rows away (the Aquarium's Fine-tune) opens to
    /// show it. nil when the hit isn't inside a card.
    var revealRow: String? {
        guard let hit = settings.searchHit, hit.card != nil else { return nil }
        return hit.title
    }

    // MARK: The aquarium's shop

    /// The Aquarium card's Look menu asked for the shop: the tank opens
    /// its shop the moment it shows, then clears this.
    var wantsAquariumShop = false

    // MARK: Confetti's aim

    /// The provider of the session the Screen Bar is focused on, wired
    /// by the delegate: the colour the card's Try it and the palette's
    /// Fire Confetti wear — the one `jrbar://confetti` picks too. nil
    /// until wired, and while nothing is focused.
    @ObservationIgnored var focusedProvider: @MainActor () -> String? = { nil }

    /// Where JR-Bar's own menu-bar icon is (AppKit screen space), wired
    /// by the delegate: the Icon origin fires from under it. nil until
    /// wired, and while the icon is parked.
    @ObservationIgnored var iconFrame: @MainActor () -> NSRect? = { nil }
}
