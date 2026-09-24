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
    /// Where the game lives on disk — the real state directory only when
    /// the app asks for it, a scratch file otherwise.
    @ObservationIgnored private let saveFile: AquariumSaveFile
    /// Where this tank saves — the tests check a headless store's.
    var saveLocation: URL { saveFile.url }
    /// The "while you were away" summary the tank shows once, when the
    /// window reopens after earning with it closed.
    private(set) var awayNotice: AquariumAwaySummary?
    /// The latest game moment worth a toast ("+3 pearls", "a fish
    /// grew") — the view shows it briefly; the tick clears stale ones.
    private(set) var toast: (text: String, at: Date)?
    /// The reward moments that deserve more than a toast — an
    /// achievement, the daily goal, a dug-up chest — shown as a small
    /// card sliding in at the top-right (docs/TOYS.md). The view
    /// dismisses it; the tick clears stale ones as a backstop.
    private(set) var notice: (id: UUID, title: String, reward: String?,
                              symbol: String, at: Date)?

    /// The window is covered or hidden; the view pauses its timeline.
    var windowOccluded = false

    /// The water's slow mood (docs/TOYS.md): the tightest quota window
    /// and any unreviewed failure, read once per document; the view adds
    /// the reset's shaft at draw time. Written only when it moves, so a
    /// steady fleet redraws nothing.
    private(set) var waterBase = AquariumWaterMood.calm
    /// When the last quota reset landed — the shaft's clock.
    private(set) var lastResetAt: Date?

    func waterMood(at now: Date) -> AquariumWaterMood {
        waterBase.with(resetAt: lastResetAt, now: now)
    }

    /// The Toys page's room rule (`ToysStore.hushReason`): while JR-Bar
    /// is quiet or a Focus is on, the tank keeps its game moments to
    /// itself — no toast, no reward card sliding in, no
    /// visitor parade. The game still counts every one of them: a
    /// visitor waits in its queue, a reward card waits in `heldNotice`,
    /// and both come out once the room clears.
    var hushed: Bool { store?.hushReason() != nil }
    /// The reward card the room held back, shown on the first tick
    /// after it clears. The newest wins, like the live card.
    @ObservationIgnored private var heldNotice: (title: String, reward: String?, symbol: String)?

    @ObservationIgnored private var windowController: AquariumWindowController?
    @ObservationIgnored private var gameTimer: Timer?
    /// The tank outside its window: the live wallpaper and the idle
    /// screensaver, both opt-in from the card.
    @ObservationIgnored private var ambient: AquariumAmbientController?
    /// The two ambient settings the controller last synced to — the
    /// observation fires on any toys-state write, most of them not ours.
    @ObservationIgnored private var ambientSynced: (idle: Int, display: String?)?

    /// A save of its own in the temporary directory — the default for
    /// every tank the app didn't explicitly point at the real one.
    static func scratchSave() -> AquariumSaveFile {
        AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-scratch-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
    }

    init(core: CoreModel, store: ToysStore, saveFile: AquariumSaveFile = AquariumToy.scratchSave()) {
        self.core = core
        self.store = store
        self.saveFile = saveFile
        game = saveFile.load().game
        knownLevel = game.tankLevel
        // A relaunched app starts with the tank closed: if the save
        // still believed the window open, earnings would never count
        // as "away". Reopening reports the summary either way.
        game.apply(.setWindowOpen(false), now: Date())
        refreshFish()
        observeSessions()
        // The economy's tick runs only while the toy is on — the
        // window being closed is exactly when the away counters fill.
        // Twenty seconds of live time per tick; nothing accrues while
        // the app is not running (no wall-clock catch-up anywhere).
        // Off is not deaf, though: `observeSessions` and `noteEvent`
        // stay armed, so a completion or quota reset landing while the
        // tank is closed still applies to the game and persists — the
        // away summary depends on it.
        syncGameTimer()
        // Left on at quit: the tank comes back at launch, without
        // stealing focus for it.
        if isOn { present(activate: false) }
        observeAmbientSettings()
    }

    /// The wallpaper and the screensaver follow their two settings; the
    /// controller only exists once either is on.
    private func observeAmbientSettings() {
        let settings = store?.state.aquarium ?? AquariumSettings()
        withObservationTracking {
            _ = store?.state.aquarium.idleFillMinutes
            _ = store?.state.aquarium.ambientDisplay
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeAmbientSettings() }
        }
        let wanted = (idle: settings.idleFillMinutes, display: settings.ambientDisplay)
        if let synced = ambientSynced, synced.idle == wanted.idle, synced.display == wanted.display {
            return
        }
        ambientSynced = wanted
        if settings.idleFillMinutes > 0 || settings.ambientDisplay != nil {
            if ambient == nil { ambient = AquariumAmbientController(toy: self) }
            ambient?.sync()
        } else if let ambient {
            ambient.tearDown()
            self.ambient = nil
        }
    }

    /// The tick runs exactly while the toy is on.
    private func syncGameTimer() {
        if isOn {
            guard gameTimer == nil else { return }
            gameTimer = Timer.scheduledTimer(
                withTimeInterval: AquariumRules.tickInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.gameTick() }
            }
        } else {
            gameTimer?.invalidate()
            gameTimer = nil
        }
    }

    isolated deinit {
        gameTimer?.invalidate()
    }

    let id = "aquarium"
    let name = "Aquarium"
    let blurb = "Every session is a fish. Asks come up for air."
    let symbol = "fish.fill"

    var isOn: Bool {
        get { store?.state.aquarium.enabled ?? false }
        set {
            store?.state.aquarium.enabled = newValue
            syncGameTimer()
            if newValue {
                present(activate: true)
            } else {
                windowController?.close()
            }
        }
    }

    /// Frames the tank actually drew, window and scenery panels alike —
    /// the fish timeline ticks it.
    @ObservationIgnored let meter = ToyMeter()

    func cost(at now: TimeInterval) -> String? {
        let drawing = meter.drawing(at: now) ?? "Not drawing right now"
        var parts = [drawing, "30 fps while the tank shows, none when covered"]
        if isOn { parts.append("the game's beat every \(Int(AquariumRules.tickInterval)) s") }
        if (store?.state.aquarium.idleFillMinutes ?? 0) > 0 { parts.append("an idle check every 5 s") }
        return parts.joined(separator: " · ")
    }

    /// Off still watches: `observeSessions` and `noteEvent` keep the
    /// game's accrual alive while the tank is closed (the away summary
    /// needs it), so the chip never claims a fully-off state — it says so
    /// in a quiet neutral note, not a warning. The card's switch is the
    /// tank window; the live wallpaper and the screensaver have their
    /// own, and the chip says when one of them still draws.
    var status: ToyStatus {
        guard !isOn else { return .on }
        let settings = store?.state.aquarium ?? AquariumSettings()
        return Self.closedStatus(wallpaper: settings.ambientDisplay,
                                 connected: NSScreen.screens.map(\.localizedName),
                                 saverMinutes: settings.idleFillMinutes)
    }

    /// The chip with the tank window closed: a wallpaper on a connected
    /// display is drawing right now, so it comes first; an armed
    /// screensaver next; otherwise the game just keeps count.
    static func closedStatus(wallpaper: String?, connected: [String],
                             saverMinutes: Int) -> ToyStatus {
        if let wallpaper, connected.contains(wallpaper) {
            return .note("Live wallpaper on \(wallpaper)")
        }
        if saverMinutes > 0 { return .note("Screensaver after \(saverMinutes) min") }
        return .note("Watching quietly")
    }

    var controls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    TankSwatch(themeID: game.themeID, substrateID: game.substrateID)
                } label: {
                    SettingLabel(title: "In the tank", subtitle: fact)
                }

                Divider()
                    .padding(.vertical, 4)

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
                    Picker("", selection: dayNight) {
                        Text("Follow the clock").tag(DayNightMode.realTime)
                        Text("Follow the sun").tag(DayNightMode.sun)
                        Text("4-minute cycle").tag(DayNightMode.cycle)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                } label: {
                    SettingLabel(title: "Day & night", subtitle: dayNightSubtitle)
                }

                Divider()
                    .padding(.vertical, 4)

                LabeledContent {
                    Button("Fill screen") { self.fillScreen() }
                } label: {
                    SettingLabel(title: "Fill screen", subtitle: "The tank covers the whole screen. Esc leaves.")
                }
                LabeledContent {
                    Picker("", selection: ambientDisplay) {
                        Text("Off").tag(String?.none)
                        let connected = NSScreen.screens.map(\.localizedName)
                        ForEach(AquariumWallpaper.displayChoices(
                            connected: connected,
                            saved: store?.state.aquarium.ambientDisplay), id: \.self) { name in
                            Text(connected.contains(name) ? name : "\(name) (not connected)")
                                .tag(String?.some(name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                } label: {
                    SettingLabel(title: "Live wallpaper", subtitle: "The tank behind every window on a display, click-through. Draws while you can see it.")
                }
                LabeledContent {
                    Picker("", selection: idleFillMinutes) {
                        ForEach(AquariumSettings.idleFillChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Off" : "After \(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                } label: {
                    SettingLabel(title: "Screensaver", subtitle: "Idle that long, the tank fills your screens until you're back — never over a video, a call or a fullscreen app.")
                }
                if (store?.state.aquarium.idleFillMinutes ?? 0) > 0 {
                    Toggle(isOn: saverClock) {
                        SettingLabel(title: "Clock on the screensaver", subtitle: "The time and date, quietly, in a corner.")
                    }
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

    private var ambientDisplay: Binding<String?> {
        Binding(get: { self.store?.state.aquarium.ambientDisplay },
                set: { self.store?.state.aquarium.ambientDisplay = $0 })
    }

    private var saverClock: Binding<Bool> {
        Binding(get: { self.store?.state.aquarium.saverClock ?? true },
                set: { self.store?.state.aquarium.saverClock = $0 })
    }

    private var idleFillMinutes: Binding<Int> {
        Binding(get: { self.store?.state.aquarium.idleFillMinutes ?? 0 },
                set: { self.store?.state.aquarium.idleFillMinutes = $0 })
    }

    /// The picker's caption names the sun's source, so "Follow the
    /// sun" never pretends to know more than the time zone.
    private var dayNightSubtitle: String {
        guard store?.state.aquarium.dayNight == .sun else {
            return "The tank's night wash — the real clock, the sun, or a quick loop."
        }
        guard AquariumSun.coordinate(for: .current) != nil else {
            return "Your time zone names no city, so the tank keeps the clock's hours."
        }
        let city = TimeZone.current.identifier.split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        return "Sunrise & sunset for \(city), worked out on this Mac from your time zone."
    }

    private var dayNight: Binding<DayNightMode> {
        Binding(get: { self.store?.state.aquarium.dayNight ?? .realTime },
                set: { self.store?.state.aquarium.dayNight = $0 })
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
    /// card's toggle and the tank can never disagree. Goes through the
    /// `isOn` setter — writing `enabled` raw would leave the game timer
    /// running the economy on a tank the card reads as off.
    func windowDidClose() {
        windowController = nil
        windowOccluded = false
        isOn = false
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
        // The timer is created only while on, but guard anyway — a tick
        // already in flight when the tank switches off must not run the
        // economy once more.
        guard isOn else { return }
        let before = game
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
        if let notice, now.timeIntervalSince(notice.at) > 6 {
            self.notice = nil
        }
        roomChanged(at: now)
        // A live tick almost always moves the document (every working
        // fish's nourish stamp), so the heartbeat alone would write the
        // save every twenty seconds forever. Writes batch instead: at
        // most one per `persistInterval`, with the event-driven paths
        // (taps, purchases, open/close) still flushing immediately.
        if game != before,
           now.timeIntervalSince(lastPersistAt) >= Self.persistInterval {
            persist()
        }
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

    /// "Feed the tank" from outside the window — the buddy's menu today,
    /// the notch card or the command bar tomorrow: one pellet round to
    /// every fish in the tank, residents included, exactly as if each
    /// were tapped. The game's per-fish daily cap still counts, so a
    /// round from afar can't out-earn a day's work; it just keeps the
    /// residents from starving through a week with the window shut.
    /// Returns how many fish ate.
    @discardableResult
    func feedAll(at now: Date = Date()) -> Int {
        let eaters = fish.filter { !$0.isFry && !$0.isRetired(at: now) && $0.state != .sinking }
        guard !eaters.isEmpty else { return 0 }
        for fish in eaters {
            note(game.apply(.pelletEaten(fishID: fish.id), now: now), now: now)
        }
        persist()
        return eaters.count
    }

    /// A resident's logbook (`AquariumResidentLog`): the daemon's history
    /// rows for its session, from a little before the tank first raised
    /// it. A daemon that can't answer leaves only what the tank knows.
    func residentLog(for id: String) async -> AquariumResidentLog {
        let care = game.pets[id]
        let since = care.map { max(0, $0.createdAt - 86_400) }
        let rows = (try? await core.listHistory(since: since, limit: 500)) ?? []
        return AquariumResidentLog.make(sessionID: id, care: game.pets[id], rows: rows)
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

    /// Put an owned accessory on a fish — the second wearable slot.
    func equipAccessory(_ item: ShopItem, to fishID: String?) {
        let now = Date()
        note(game.apply(.equipAccessory(item, fishID: fishID), now: now), now: now)
        persist()
    }

    /// Apply an owned substrate — the tank floor.
    func selectSubstrate(_ item: ShopItem) {
        let now = Date()
        note(game.apply(.selectSubstrate(item), now: now), now: now)
        persist()
    }

    /// Apply an owned backdrop — the back wall.
    func selectBackdrop(_ item: ShopItem) {
        let now = Date()
        note(game.apply(.selectBackdrop(item), now: now), now: now)
        persist()
    }

    /// A tap on the buried treasure's spot on the sand.
    func digTreasure(_ id: String) {
        let now = Date()
        note(game.apply(.digTreasure(id), now: now), now: now)
        persist()
    }

    /// The view finished parading a queued visitor across the tank.
    func visitorShown(_ visitor: AquariumVisitor) {
        let now = Date()
        note(game.apply(.visitorShown(visitor), now: now), now: now)
        persist()
    }

    /// The parade ended — the visitor swam off the far edge. A quiet
    /// toast so the departure doesn't pass silently.
    func visitorDeparted(_ visitor: AquariumVisitor) {
        let now = Date()
        note(game.apply(.visitorDeparted(visitor), now: now), now: now)
        persist()
    }

    /// A core event the coordinator forwards — today only `quota_reset`
    /// matters: the submarine comes to look at a fresh lane.
    func noteEvent(_ event: CoreEvent) {
        guard event.kind == "quota_reset" else { return }
        let now = Date()
        lastResetAt = now
        note(game.apply(.quotaReset, now: now), now: now)
        persist()
    }

    /// The room may have cleared: a held reward card comes out. Quiet
    /// and Focus changes arrive with the daemon's document and the tick
    /// looks; the store also calls this on the call-presence edge, once
    /// something feeds it.
    func roomChanged(at now: Date = Date()) {
        guard let held = heldNotice, !hushed else { return }
        heldNotice = nil
        notice = (UUID(), held.title, held.reward, held.symbol, now)
    }

    func dismissAwayNotice() { awayNotice = nil }
    func dismissToast() { toast = nil }
    /// The view's fade timer answers with the card it drew; a stale
    /// id can't dismiss a newer card.
    func dismissNotice(id: UUID) {
        if notice?.id == id { notice = nil }
    }

    /// The tank level the last `note` saw — a rise is a milestone.
    @ObservationIgnored private var knownLevel = 0

    /// Effects worth surfacing: the away summary becomes the panel,
    /// the rest fold into the toast line. An achievement or a new tank
    /// level is a milestone, and asks Confetti for a burst — the toy
    /// decides whether its Milestones trigger is on.
    private func note(_ effects: [AquariumGameEffect], now: Date) {
        let toastBefore = toast?.at
        let noticeBefore = notice?.id
        var earned = 0
        var milestone = game.tankLevel > knownLevel
        knownLevel = max(knownLevel, game.tankLevel)
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
            case .achievementUnlocked(let a):
                notice = (UUID(), a.title, "+\(a.reward) pearls",
                          "checkmark.seal.fill", now)
                milestone = true
            case .dailyGoalMet:
                notice = (UUID(), "Daily goal met",
                          "+\(AquariumRules.dailyGoalReward) pearls",
                          "calendar.badge.checkmark", now)
            case .treasureFound(let v):
                notice = (UUID(), "Treasure dug up", "+\(v) pearls",
                          "shippingbox.fill", now)
            case .purchaseLocked(let item, let needs):
                toast = ("\(item.displayName) unlocks at tank level \(needs)", now)
            case .visitor(let v):
                toast = ("A \(v.displayName) drifts by", now)
            case .visitorDeparted(let v):
                toast = ("The \(v.displayName) drifts on", now)
            case .variantEarned(let id, let variant):
                switch variant {
                case .tide: toast = ("\(label(for: id)) earned its tide stripe", now)
                case .starry: toast = ("\(label(for: id)) is starry now", now)
                }
            case .pearlsSpent, .purchaseDenied: break
            }
        }
        if earned > 0 {
            toast = ("+\(earned) pearl\(earned == 1 ? "" : "s")", now)
        }
        // A hushed room: this batch's toast is dropped (a toast is a
        // passing remark) and its reward card is held for later.
        if hushed {
            if toast?.at != toastBefore { toast = nil }
            if let card = notice, card.id != noticeBefore {
                heldNotice = (card.title, card.reward, card.symbol)
                notice = nil
            }
        }
        if milestone { store?.confetti.fire(reason: .milestone, at: now) }
    }

    private func label(for sessionID: String) -> String {
        fish.first { $0.id == sessionID }?.label ?? "A fish"
    }

    /// The save: small JSON, atomic write, its own file — a failed
    /// write is not worth interrupting a fish tank over.
    private func persist() {
        lastPersistAt = Date()
        try? saveFile.save(AquariumSave(game: game))
    }

    /// The slowest the game document may be written — the heartbeat's
    /// own pace. Event-driven changes (taps, purchases, the window
    /// toggling) flush through `persist()` directly; the tick only
    /// writes when something moved and the interval has passed.
    private static let persistInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var lastPersistAt = Date.distantPast

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
        pruneIfDue(liveIDs: Set(sessions.map(\.id)), now: now)
        let residents = game.residents(excluding: Set(sessions.map(\.id)))
        fish = AquariumModel.reduce(sessions: sessions, previous: fish, now: now,
                                    residents: residents) {
            settings.species(for: $0)
        }
        noteCompletions(now: now)
        noteFleet(now: now)
        let base = AquariumWaterMood.base(core.state)
        if base != waterBase { waterBase = base }
    }

    /// The care records stay trimmed while the tank is closed too: the
    /// session list keeps minting records with the window shut, and the
    /// tick's prune only runs while it's open. At most once a minute, on
    /// a copy, written back (and saved) only when something went.
    private func pruneIfDue(liveIDs: Set<String>, now: Date) {
        guard now.timeIntervalSince(lastPruneAt) >= Self.pruneInterval else { return }
        lastPruneAt = now
        guard game.pets.count > AquariumRules.maxPets else { return }
        var next = game
        let effects = next.apply(.prune(liveIDs: liveIDs), now: now)
        guard next != game else { return }
        game = next
        note(effects, now: now)
        persist()
    }

    /// The slowest the session-driven prune runs.
    static let pruneInterval: TimeInterval = 60
    @ObservationIgnored private var lastPruneAt = Date.distantPast

    /// The work's own milestones (a school of six, a clean week, a week
    /// under budget, banked credits): the document's fleet facts, folded
    /// into the game on every change — the session list and the usage
    /// ride the same document. Read-only; the tank only notices. A
    /// milestone saves at once; the log's quiet moves ride the next save.
    private func noteFleet(now: Date) {
        guard let state = core.state else { return }
        // Applied to a copy and written back only when it moved: the
        // game is observed, and a document that changed nothing must
        // not redraw every view that reads it.
        var next = game
        let effects = next.apply(.fleet(AquariumFleetFacts.read(state, now: now)), now: now)
        if next != game { game = next }
        note(effects, now: now)
        if !effects.isEmpty { persist() }
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

/// The card's glimpse of the tank: the water in the theme it wears,
/// light falling through it and the floor it sits on — a still
/// picture, so the card costs nothing to show.
private struct TankSwatch: View {
    let themeID: String
    let substrateID: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Canvas { canvas, size in
            let rect = Path(CGRect(origin: .zero, size: size))
            canvas.fill(rect, with: .linearGradient(
                Gradient(stops: AquariumView.waterStops(forTheme: themeID)),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let light = AquariumView.water(forTheme: themeID)
            var shafts = canvas
            shafts.blendMode = .plusLighter
            for (x, w) in [(0.22, 0.10), (0.42, 0.06), (0.58, 0.12)] as [(Double, Double)] where light.shafts > 0 {
                var beam = Path()
                beam.move(to: CGPoint(x: size.width * (x - w / 2), y: 0))
                beam.addLine(to: CGPoint(x: size.width * (x + w / 2), y: 0))
                beam.addLine(to: CGPoint(x: size.width * (x + w * 1.4 + 0.12), y: size.height))
                beam.addLine(to: CGPoint(x: size.width * (x + 0.12), y: size.height))
                beam.closeSubpath()
                shafts.fill(beam, with: .linearGradient(
                    Gradient(colors: [TankPaint.color(light.light, 0.22 * light.shafts), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            var sand = Path()
            sand.move(to: CGPoint(x: 0, y: size.height * 0.80))
            sand.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.76),
                              control: CGPoint(x: size.width * 0.5, y: size.height * 0.70))
            sand.addLine(to: CGPoint(x: size.width, y: size.height))
            sand.addLine(to: CGPoint(x: 0, y: size.height))
            sand.closeSubpath()
            canvas.fill(sand, with: .linearGradient(
                Gradient(colors: AquariumView.sandSwatch(forSubstrate: substrateID)),
                startPoint: CGPoint(x: 0, y: size.height * 0.72), endPoint: CGPoint(x: 0, y: size.height)))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.15)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
        .frame(width: 76, height: 46)
        .accessibilityHidden(true)
    }
}
