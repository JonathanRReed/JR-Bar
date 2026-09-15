import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Aquarium (docs/TOYS.md): every live session is a fish in a resizable
/// window — the provider picks the species & colour, a main session's
/// label rides in a chip under it, and its sub-agents join as fry
/// schooling around it. An ask rises to bob with a bubble, a failed
/// run sinks grey & settles on the sand, a completion drifts off the
/// edge — school and all. Reads `core.state.sessions` (mains AND
/// workers); the timeline pauses while the window is covered. Off by
/// default.
@MainActor
@Observable
final class AquariumToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?

    /// The tank's current fish: `AquariumModel.reduce` applied to
    /// `core.sessions` whenever it changes. The view integrates motion
    /// from the frame clock, so this list only moves with the sessions.
    private(set) var fish: [Fish] = []

    /// The idle game's document (docs/TOYS.md): loaded from
    /// `aquarium-save.json` at start, moved only by `AquariumEvent`s,
    /// written back after every batch. The game reads the session
    /// list and answers taps — it never touches the agent.
    private(set) var game: AquariumGame
    @ObservationIgnored private let saveFile = AquariumSaveFile()
    /// The "while you were away" summary the tank shows once, when the
    /// window reopens after earning with it closed.
    private(set) var awayNotice: AquariumAwaySummary?
    /// The latest game moment worth a toast ("+3 pearls", "a fish
    /// grew") — the view shows it briefly; the tick clears stale ones.
    private(set) var toast: (text: String, at: Date)?

    /// The window is covered or hidden; the view pauses its timeline.
    var windowOccluded = false

    @ObservationIgnored private var windowController: AquariumWindowController?
    @ObservationIgnored private var gameTimer: Timer?

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        game = saveFile.load().game
        // A relaunched app starts with the tank closed: if the save
        // still believed the window open, earnings would never count
        // as "away". Reopening reports the summary either way.
        game.apply(.setWindowOpen(false), now: Date())
        refreshFish()
        observeSessions()
        // The economy runs whenever the app does — the window being
        // closed is exactly when the away counters fill. Twenty
        // seconds of live time per tick; nothing accrues while the
        // app is not running (no wall-clock catch-up anywhere).
        gameTimer = Timer.scheduledTimer(
            withTimeInterval: AquariumRules.tickInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameTick() }
        }
        // Left on at quit: the tank comes back at launch, without
        // stealing focus for it.
        if isOn { present(activate: false) }
    }

    let id = "aquarium"
    let name = "Aquarium"
    let blurb = "Every session is a fish. Asks come up for air."
    let symbol = "fish.fill"

    var isOn: Bool {
        get { store?.state.aquarium.enabled ?? false }
        set {
            store?.state.aquarium.enabled = newValue
            if newValue {
                present(activate: true)
            } else {
                windowController?.close()
            }
        }
    }

    var status: ToyStatus { isOn ? .on : .off }

    var controls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: showLabels) {
                    SettingLabel(title: "Show labels", subtitle: "The session's name under its fish.")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: density, in: 0.25...2)
                            .frame(width: 180)
                        ValueText(text: String(format: "%.2f×", density.wrappedValue))
                    }
                } label: {
                    SettingLabel(title: "Density", subtitle: "How much plankton & bubbles the tank draws.")
                }
                LabeledContent {
                    Button("Fill screen") { self.fillScreen() }
                } label: {
                    SettingLabel(title: "Fill screen", subtitle: "The tank covers the whole screen. Esc leaves.")
                }
                LabeledContent {
                    Text(fact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "In the tank")
                }
            }
        )
    }

    /// "4 fish · a school of 6 · 1 at the surface · ◉ 12" / "Nothing
    /// swimming yet" — a fact, like the status chip, with the idle
    /// game's bank & beach folded in.
    private var fact: String {
        let now = Date()
        let live = fish.filter { !$0.isRetired(at: now) }
        var parts: [String] = []
        if !live.isEmpty {
            let adults = live.filter { !$0.isFry }
            if !adults.isEmpty { parts.append("\(adults.count) fish") }
            let fryCount = live.count - adults.count
            if fryCount == 1 { parts.append("1 fry") }
            if fryCount > 1 { parts.append("a school of \(fryCount)") }
            let surface = adults.filter { $0.state == .surfacing }.count
            if surface > 0 { parts.append("\(surface) at the surface") }
            let golden = adults.filter { AquariumBehavior.isGolden(seed: $0.seed) }.count
            if golden == 1 { parts.append("a golden one") }
            if golden > 1 { parts.append("\(golden) golden") }
        }
        if game.pearls > 0 { parts.append("◉ \(game.pearls)") }
        if !game.drops.isEmpty {
            parts.append("\(game.drops.count) pearl\(game.drops.count == 1 ? "" : "s") on the sand")
        }
        if parts.isEmpty { return "Nothing swimming yet" }
        if live.isEmpty { return "Nothing swimming yet · \(parts.joined(separator: " · "))" }
        return parts.joined(separator: " · ")
    }

    private var showLabels: Binding<Bool> {
        Binding(get: { self.store?.state.aquarium.showLabels ?? true },
                set: { self.store?.state.aquarium.showLabels = $0 })
    }

    private var density: Binding<Double> {
        Binding(get: { self.store?.state.aquarium.density ?? 1 },
                set: { self.store?.state.aquarium.density = $0 })
    }

    // MARK: Window

    /// "Fill screen" opens the tank first when the toy is off — the
    /// button is a reason to look, not a trapdoor.
    func fillScreen() {
        if !isOn { isOn = true }
        windowController?.fillScreen()
    }

    private func present(activate: Bool) {
        let controller = windowController ?? AquariumWindowController(toy: self)
        windowController = controller
        controller.show(activate: activate)
        let now = Date()
        note(game.apply(.setWindowOpen(true), now: now), now: now)
        persist()
    }

    /// The window's close button routes back through the store, so the
    /// card's toggle and the tank can never disagree.
    func windowDidClose() {
        windowController = nil
        windowOccluded = false
        store?.state.aquarium.enabled = false
        let now = Date()
        note(game.apply(.setWindowOpen(false), now: now), now: now)
        persist()
    }

    // MARK: Idle game

    /// One beat of the economy: work time mints pearls and nourishes
    /// the working fish, the heartbeat starves/drops/collects, and the
    /// roster prune keeps the save small. Reads `core.state.sessions`;
    /// writes nothing back — the game can never alter an agent.
    private func gameTick(now: Date = Date()) {
        let sessions = core.state?.sessions ?? []
        let working = sessions
            .filter { SessionActivity.reduce($0) == .working }
            .map(\.id)
        var effects = game.apply(
            .workTick(seconds: AquariumRules.tickInterval, working: working),
            now: now)
        effects += game.apply(.tick, now: now)
        effects += game.apply(.prune(liveIDs: Set(sessions.map(\.id))), now: now)
        note(effects, now: now)
        if let toast, now.timeIntervalSince(toast.at) > 6 {
            self.toast = nil
        }
        persist()
    }

    /// Session diffs that pay: a session reading `done` earns its
    /// completion bonus exactly once — the reducer dedupes by the
    /// care record, so firing on every refresh is safe.
    private func noteCompletions(now: Date) {
        let before = game
        for session in core.state?.sessions ?? []
        where SessionActivity.reduce(session) == .done {
            note(game.apply(.sessionCompleted(id: session.id), now: now), now: now)
        }
        if game != before { persist() }
    }

    /// A pellet reached a fish's mouth (the view calls this when the
    /// seeker arrives — food is a tap, not a session fact).
    func pelletEaten(by fishID: String) {
        let now = Date()
        note(game.apply(.pelletEaten(fishID: fishID), now: now), now: now)
        persist()
    }

    /// A clicked pearl drop on the sand.
    func collectDrop(_ id: String) {
        let now = Date()
        note(game.apply(.collectDrop(id), now: now), now: now)
        persist()
    }

    /// Shop: buy an item. Denials come back as effects; the view's
    /// buttons pre-disable, so a denied tap is just a shake anyway.
    func purchase(_ item: ShopItem) {
        let now = Date()
        note(game.apply(.purchase(item), now: now), now: now)
        persist()
    }

    /// Apply an owned theme.
    func selectTheme(_ item: ShopItem) {
        let now = Date()
        note(game.apply(.selectTheme(item), now: now), now: now)
        persist()
    }

    /// Put an owned hat on a fish, or take it off (`fishID` nil).
    func equipHat(_ item: ShopItem, to fishID: String?) {
        let now = Date()
        note(game.apply(.equipHat(item, fishID: fishID), now: now), now: now)
        persist()
    }

    func dismissAwayNotice() { awayNotice = nil }
    func dismissToast() { toast = nil }

    /// Effects worth surfacing: the away summary becomes the panel,
    /// the rest fold into the toast line.
    private func note(_ effects: [AquariumGameEffect], now: Date) {
        var earned = 0
        for effect in effects {
            switch effect {
            case .pearlsEarned(let n): earned += n
            case .awaySummary(let s): awayNotice = s
            case .fishGrew(let id):
                toast = ("\(label(for: id)) grew a stage", now)
            case .fishShrank(let id):
                toast = ("\(label(for: id)) got skinny — drop some food", now)
            case .streakDay(let days):
                toast = (days == 1 ? "A completion streak begins" : "\(days)-day streak", now)
            case .pearlsSpent, .purchaseDenied: break
            }
        }
        if earned > 0 {
            toast = ("+\(earned) pearl\(earned == 1 ? "" : "s")", now)
        }
    }

    private func label(for sessionID: String) -> String {
        fish.first { $0.id == sessionID }?.label ?? "A fish"
    }

    /// The save: small JSON, atomic write, its own file — a failed
    /// write is not worth interrupting a fish tank over.
    private func persist() {
        try? saveFile.save(AquariumSave(game: game))
    }

    // MARK: Fish

    private func refreshFish() {
        // The tank takes every listed session: `core.sessions` is mains
        // only, and a sub-agent is somebody's fry. Species come from the
        // settings' per-provider casting, falling back to the table.
        let settings = store?.state.aquarium ?? AquariumSettings()
        let now = Date()
        let sessions = core.state?.sessions ?? []
        // Remember each listed session's name and provider on its care
        // record, so the fish it raised can keep swimming as a resident
        // once the session is gone. The action touches only records
        // that already exist — nothing is minted for a passer-by.
        for session in sessions where game.pets[session.id] != nil {
            _ = game.apply(.identify(id: session.id, label: session.displayLabel,
                                     provider: session.provider), now: now)
        }
        let residents = game.residents(excluding: Set(sessions.map(\.id)))
        fish = AquariumModel.reduce(sessions: sessions, previous: fish, now: now,
                                    residents: residents) {
            settings.species(for: $0)
        }
        noteCompletions(now: now)
    }

    /// The inspector's species picker writes here — a per-provider
    /// recast, so every fish from that provider changes shape at once.
    func setSpecies(_ species: FishSpecies?, for provider: String) {
        store?.state.aquarium.speciesOverrides[provider.lowercased()] = species?.rawValue
        refreshFish()
    }

    /// What the inspector's picker shows for `provider`: the stored pick
    /// or the table default.
    func species(for provider: String) -> FishSpecies {
        (store?.state.aquarium ?? AquariumSettings()).species(for: provider)
    }

    /// The picker's raw selection for `provider`: the stored override,
    /// or nil when the provider swims as its table species.
    func speciesOverride(for provider: String) -> FishSpecies? {
        store?.state.aquarium.speciesOverrides[provider.lowercased()]
            .flatMap(FishSpecies.init(rawValue:))
    }

    /// Watches the session list like `NotchBuddyToy`: one observation
    /// per change, coalesced into a main-queue turn.
    private func observeSessions() {
        withObservationTracking {
            _ = core.state?.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshFish()
                self.observeSessions()
            }
        }
    }
}
