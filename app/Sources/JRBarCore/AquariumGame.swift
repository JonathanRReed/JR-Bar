import Foundation

/// The idle game's tunables (docs/TOYS.md): every number the economy
/// runs on lives here, one table, so a rebalance is one edit. Times
/// are seconds, sizes are Int pearls/stages.
public enum AquariumRules {
    /// Seconds of any session in `working` that mint one pearl.
    public static let workSecondsPerPearl: Double = 5 * 60
    /// Each extra concurrently-working session adds this much to the
    /// earn multiplier: 1 + 0.25·(n−1).
    public static let concurrencyBonusPerExtra: Double = 0.25
    /// The multiplier never grows past this.
    public static let concurrencyCap: Double = 3
    /// Pearls for a session that completes.
    public static let completionBonus: Int = 5
    /// Pearls for each pellet a fish eats.
    public static let pelletPearl: Int = 1
    /// Feedings needed per growth stage…
    public static let feedingsPerStage: Int = 3
    /// …plus this much session work-time (the fish grows because the
    /// tank is lived in, not because it's clicked).
    public static let growthWorkSeconds: Double = 10 * 60
    /// Three size stages: 0 small, 1 grown, 2 full.
    public static let maxStage = 2
    /// A fish that has had no feeding and no work for this long shrinks
    /// one stage — never dies — and the clock restarts per stage.
    public static let starveAfter: TimeInterval = 6 * 60 * 60
    /// A full-grown fish drops a collectable pearl this often while the
    /// app runs.
    public static let pearlDropInterval: TimeInterval = 20 * 60
    /// Only a fully grown fish drops.
    public static let dropStage = AquariumRules.maxStage
    /// Each dropped pearl is worth this much when collected.
    public static let dropPearlValue = 1
    /// The tank holds at most this many uncollected drops.
    public static let maxDrops = 24
    /// An owned snail picks up a drop after it has sat this long.
    public static let snailCollectAfter: TimeInterval = 10
    /// Pet records kept at most — the oldest non-live go first.
    public static let maxPets = 64
    /// The most raised fish that keep swimming after their sessions
    /// are gone — enough for a tank that never reads empty, few enough
    /// that the live roster still stands out.
    public static let maxResidents = 6
    /// How often the toy feeds the model a tick (its own constant —
    /// the model takes whatever `dt` the tick carries).
    public static let tickInterval: TimeInterval = 20
}

/// The tank's shop: every spendable thing is one case. `rawValue` is
/// the save file's key — never rename a shipped case.
public enum ShopItem: String, Codable, CaseIterable, Sendable {
    // Decor — drawn on the sand once owned.
    case plant
    case rock
    case treasureChest
    case castle
    // Pets — live in the tank once owned.
    case snail
    case jellyfish
    case hermitCrab
    // Hats — worn by a chosen fish once owned.
    case hatBeanie
    case hatParty
    case hatCrown
    // Themes — water colour presets; midnight adds night lighting.
    case themeReef
    case themeLagoon
    case themeTwilight
    case themeMidnight

    public enum Category: String, Equatable, Sendable, CaseIterable {
        case decor, pets, themes, hats

        public var displayName: String {
            switch self {
            case .decor: return "Decor"
            case .pets: return "Pets"
            case .themes: return "Themes"
            case .hats: return "Hats"
            }
        }
    }

    public var category: Category {
        switch self {
        case .plant, .rock, .treasureChest, .castle: return .decor
        case .snail, .jellyfish, .hermitCrab: return .pets
        case .hatBeanie, .hatParty, .hatCrown: return .hats
        case .themeReef, .themeLagoon, .themeTwilight, .themeMidnight: return .themes
        }
    }

    public var price: Int {
        switch self {
        case .rock: return 10
        case .plant: return 15
        case .hatBeanie: return 12
        case .hatParty: return 18
        case .themeReef, .themeLagoon: return 25
        case .jellyfish: return 30
        case .themeTwilight: return 35
        case .treasureChest, .hermitCrab: return 40
        case .hatCrown: return 45
        case .snail: return 50
        case .themeMidnight, .castle: return 60
        }
    }

    public var displayName: String {
        switch self {
        case .plant: return "Leafy plant"
        case .rock: return "Big smooth rock"
        case .treasureChest: return "Treasure chest"
        case .castle: return "Little castle"
        case .snail: return "Snail"
        case .jellyfish: return "Jellyfish"
        case .hermitCrab: return "Hermit crab"
        case .hatBeanie: return "Beanie"
        case .hatParty: return "Party hat"
        case .hatCrown: return "Crown"
        case .themeReef: return "Reef"
        case .themeLagoon: return "Lagoon"
        case .themeTwilight: return "Twilight"
        case .themeMidnight: return "Midnight"
        }
    }

    /// One line about what owning it does, for the shop row.
    public var detail: String {
        switch self {
        case .plant: return "A leafy cluster for the sand."
        case .rock: return "A place to lurk behind."
        case .treasureChest: return "Burps bubbles. Very pirate."
        case .castle: return "Every tank needs one."
        case .snail: return "Creeps the glass & collects dropped pearls for you."
        case .jellyfish: return "Drifts through the mid-water, unbothered."
        case .hermitCrab: return "Wanders the sand in a borrowed shell."
        case .hatBeanie: return "A warm hat for a hard-working fish."
        case .hatParty: return "For a fish that finishes things."
        case .hatCrown: return "Royalty. Obviously."
        case .themeReef: return "Cool reef blues."
        case .themeLagoon: return "Bright shallow turquoise."
        case .themeTwilight: return "Deeper violet water."
        case .themeMidnight: return "Night lighting: dark water, moon rays."
        }
    }

    /// Theme items only: the theme id `selectTheme` writes.
    public var themeID: String? {
        switch self {
        case .themeReef: return "reef"
        case .themeLagoon: return "lagoon"
        case .themeTwilight: return "twilight"
        case .themeMidnight: return "midnight"
        default: return nil
        }
    }
}

/// One session's care record (docs/TOYS.md: "sessions stay fish").
/// Keyed by session id inside `AquariumGame.pets`; created lazily the
/// first time the session earns, works, eats or finishes — so a fish
/// that simply swims through costs the save nothing.
public struct FishCare: Codable, Equatable, Sendable {
    /// Size stage, 0…`AquariumRules.maxStage`.
    public var stage: Int
    /// Pellets eaten toward the next stage.
    public var feedings: Int
    /// Session work-time banked toward the next stage.
    public var workSeconds: Double
    /// Epoch of the last feeding or work tick; hunger counts from here.
    public var lastNourishedAt: Double
    /// The next epoch at which continued neglect costs a stage.
    public var starvingAt: Double
    /// The last epoch a pearl drop was minted for this fish.
    public var lastDropAt: Double
    /// The completion bonus for this session was already granted —
    /// a listed-but-finished session can never pay twice.
    public var completionGranted: Bool
    /// When the record was made; pruning drops the oldest first.
    public var createdAt: Double
    /// What the tank called the session, remembered so a raised fish
    /// can keep swimming as a resident after its session is gone. Nil
    /// until `identify` lands (records from before the field decode
    /// nil and stay nameless until their session is seen again).
    public var label: String?
    /// The session's provider — the resident's species and colour.
    public var provider: String?

    public init(stage: Int = 0, feedings: Int = 0, workSeconds: Double = 0,
                lastNourishedAt: Double = 0, starvingAt: Double = 0,
                lastDropAt: Double = 0, completionGranted: Bool = false,
                createdAt: Double = 0, label: String? = nil, provider: String? = nil) {
        self.stage = stage
        self.feedings = feedings
        self.workSeconds = workSeconds
        self.lastNourishedAt = lastNourishedAt
        self.starvingAt = starvingAt
        self.lastDropAt = lastDropAt
        self.completionGranted = completionGranted
        self.createdAt = createdAt
        self.label = label
        self.provider = provider
    }

    /// No feeding and no work for `starveAfter`: the hungry mouth.
    public func hungry(at now: Date) -> Bool {
        starvingAt > 0 && now.timeIntervalSince1970 >= starvingAt
    }
}

/// A pearl a full-grown fish dropped into the tank: it sits on the
/// sand until the user clicks it or the snail reaches it.
public struct PearlDrop: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The fish that minted it; the view anchors it near that fish.
    public var fishID: String
    /// Mint epoch.
    public var at: Double
    public var value: Int

    public init(id: String, fishID: String, at: Double, value: Int) {
        self.id = id
        self.fishID = fishID
        self.at = at
        self.value = value
    }
}

/// What happened while the tank window was closed (docs/TOYS.md: the
/// "while you were away" panel). Counters accumulate only while
/// `windowOpen` is false; opening drains them into an effect.
public struct AquariumAwaySummary: Codable, Equatable, Sendable {
    /// When the accumulation window began (the close, or game start).
    public var since: Double
    public var pearlsEarned: Int
    public var feedings: Int
    public var completions: Int
    public var dropsCollected: Int

    public init(since: Double = 0, pearlsEarned: Int = 0, feedings: Int = 0,
                completions: Int = 0, dropsCollected: Int = 0) {
        self.since = since
        self.pearlsEarned = pearlsEarned
        self.feedings = feedings
        self.completions = completions
        self.dropsCollected = dropsCollected
    }

    public var isEmpty: Bool {
        pearlsEarned == 0 && feedings == 0 && completions == 0 && dropsCollected == 0
    }
}

/// Everything the reducer can be fed. `workTick` and `tick` come from
/// the toy's timer; the rest come off session diffs and view taps.
public enum AquariumEvent: Equatable, Sendable {
    /// `seconds` of live app time with `working` sessions in the
    /// working state (their session ids).
    case workTick(seconds: Double, working: [String])
    /// A session reached `done`; the reducer dedupes by pet record.
    case sessionCompleted(id: String)
    /// A fish reached a dropped pellet.
    case pelletEaten(fishID: String)
    /// Shop purchase; denied when unaffordable or already owned.
    case purchase(ShopItem)
    /// Apply an owned theme item's theme.
    case selectTheme(ShopItem)
    /// Put an owned hat on a fish (nil takes it off wherever it is).
    case equipHat(ShopItem, fishID: String?)
    /// A clicked pearl drop.
    case collectDrop(String)
    /// The heartbeat: starvation, pearl drops, snail collection.
    case tick
    /// Drop pet records over the cap — the oldest not in `liveIDs`.
    case prune(liveIDs: Set<String>)
    /// Remember what a listed session's fish is called and who it
    /// belongs to — only on a record that already exists; a session
    /// that merely swims through earns no record.
    case identify(id: String, label: String, provider: String)
    /// The tank window opened or closed; opening drains `away`.
    case setWindowOpen(Bool)
}

/// A raised fish still in the tank after its session left — the
/// reducer turns it into an idling `Fish` that feeding keeps alive.
public struct AquariumResident: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var provider: String
    public var stage: Int
    public var lastNourishedAt: Double

    public init(id: String, label: String, provider: String, stage: Int, lastNourishedAt: Double) {
        self.id = id
        self.label = label
        self.provider = provider
        self.stage = stage
        self.lastNourishedAt = lastNourishedAt
    }
}

/// What `apply` reports back, so the caller can animate or complain.
public enum AquariumGameEffect: Equatable, Sendable {
    case pearlsEarned(Int)
    case pearlsSpent(Int)
    case purchaseDenied(ShopItem)
    /// Emitted once on `setWindowOpen(true)` when things happened while
    /// the tank was closed; carries the drained counters.
    case awaySummary(AquariumAwaySummary)
    case fishGrew(String)
    case fishShrank(String)
    /// The streak moved to this many days.
    case streakDay(Int)
}

/// The aquarium's idle game (docs/TOYS.md): a pure reducer over a
/// Codable document. It moves only when events land — nothing accrues
/// off a wall-clock read, so a relaunched app resumes where it saved
/// instead of catching up on time it never ran.
///
/// The document decodes tolerantly: missing or mistyped fields fall
/// back to defaults, so a save written by an older or newer build
/// still loads.
public struct AquariumGame: Codable, Equatable, Sendable {
    public var pearls: Int
    /// All-time earnings; spending never touches it.
    public var lifetimePearls: Int
    /// Fractional progress toward the next work pearl.
    public var pearlProgress: Double
    /// Session id → care record.
    public var pets: [String: FishCare]
    /// ShopItem raw value → count owned (always 0 or 1 today).
    public var inventory: [String: Int]
    /// The active water theme: "classic" plus the shop's theme ids.
    public var themeID: String
    /// Session id → hat item raw value.
    public var hats: [String: String]
    /// Uncollected pearl drops sitting in the tank.
    public var drops: [PearlDrop]
    /// Consecutive days with ≥1 completed session.
    public var streakDays: Int
    /// `calendar.startOfDay` epoch of the last counted completion day;
    /// 0 means no streak yet.
    public var lastStreakDay: Double
    /// Whether the tank window is open — `away` only fills when closed.
    public var windowOpen: Bool
    public var away: AquariumAwaySummary
    /// Lifetime counters for the away panel & stats line.
    public var totals: Totals
    /// Monotonic id source for drops.
    public var dropSeq: Int
    /// When the save began; also the first `away.since`.
    public var createdAt: Double

    public struct Totals: Codable, Equatable, Sendable {
        public var feedings: Int
        public var completions: Int
        public var purchases: Int
        public var dropsCollected: Int

        public init(feedings: Int = 0, completions: Int = 0,
                    purchases: Int = 0, dropsCollected: Int = 0) {
            self.feedings = feedings
            self.completions = completions
            self.purchases = purchases
            self.dropsCollected = dropsCollected
        }
    }

    public init(pearls: Int = 0, lifetimePearls: Int = 0, pearlProgress: Double = 0,
                pets: [String: FishCare] = [:], inventory: [String: Int] = [:],
                themeID: String = "classic", hats: [String: String] = [:],
                drops: [PearlDrop] = [], streakDays: Int = 0, lastStreakDay: Double = 0,
                windowOpen: Bool = false, away: AquariumAwaySummary = AquariumAwaySummary(),
                totals: Totals = Totals(), dropSeq: Int = 0, createdAt: Double = 0) {
        self.pearls = pearls
        self.lifetimePearls = lifetimePearls
        self.pearlProgress = pearlProgress
        self.pets = pets
        self.inventory = inventory
        self.themeID = themeID
        self.hats = hats
        self.drops = drops
        self.streakDays = streakDays
        self.lastStreakDay = lastStreakDay
        self.windowOpen = windowOpen
        self.away = away
        self.totals = totals
        self.dropSeq = dropSeq
        self.createdAt = createdAt
    }

    // MARK: Reducer

    /// Apply one event; returns the effects worth animating or
    /// surfacing. Pure apart from the receiver — the same state plus
    /// the same event always produces the same state and effects, so
    /// the economy is testable end to end without the app.
    @discardableResult
    public mutating func apply(_ event: AquariumEvent, now: Date,
                               calendar: Calendar = .current) -> [AquariumGameEffect] {
        if createdAt == 0 { createdAt = now.timeIntervalSince1970 }
        var effects: [AquariumGameEffect] = []
        switch event {
        case .workTick(let seconds, let working):
            guard seconds > 0, !working.isEmpty else { break }
            // +1 pearl per `workSecondsPerPearl` of working, scaled by
            // concurrency: 1 + 0.25 per extra worker, capped.
            let extra = max(0, working.count - 1)
            let mult = min(AquariumRules.concurrencyCap,
                           1 + AquariumRules.concurrencyBonusPerExtra * Double(extra))
            pearlProgress += seconds / AquariumRules.workSecondsPerPearl * mult
            let earned = Int(pearlProgress.rounded(.down))
            if earned > 0 {
                pearlProgress -= Double(earned)
                earn(earned)
                effects.append(.pearlsEarned(earned))
            }
            // Work nourishes: a working fish can't starve, and the time
            // banks toward its next stage.
            for id in working {
                var care = pet(id, now: now)
                care.workSeconds += seconds
                nourish(&care, now: now)
                grow(&care, effects: &effects, id: id)
                pets[id] = care
            }

        case .sessionCompleted(let id):
            var care = pet(id, now: now)
            guard !care.completionGranted else { break }
            care.completionGranted = true
            pets[id] = care
            totals.completions += 1
            if !windowOpen { away.completions += 1 }
            earn(AquariumRules.completionBonus)
            effects.append(.pearlsEarned(AquariumRules.completionBonus))
            // The daily streak: one counted completion per calendar
            // day, consecutive days extend it, a gap restarts it.
            let today = calendar.startOfDay(for: now).timeIntervalSince1970
            if lastStreakDay != today {
                let yesterday = calendar.date(
                    byAdding: .day, value: -1,
                    to: Date(timeIntervalSince1970: today))?.timeIntervalSince1970 ?? 0
                streakDays = lastStreakDay == yesterday ? streakDays + 1 : 1
                lastStreakDay = today
                effects.append(.streakDay(streakDays))
            }

        case .pelletEaten(let fishID):
            var care = pet(fishID, now: now)
            care.feedings += 1
            nourish(&care, now: now)
            grow(&care, effects: &effects, id: fishID)
            pets[fishID] = care
            totals.feedings += 1
            if !windowOpen { away.feedings += 1 }
            earn(AquariumRules.pelletPearl)
            effects.append(.pearlsEarned(AquariumRules.pelletPearl))

        case .purchase(let item):
            guard inventory[item.rawValue, default: 0] == 0 else {
                effects.append(.purchaseDenied(item))
                break
            }
            guard pearls >= item.price else {
                effects.append(.purchaseDenied(item))
                break
            }
            pearls -= item.price
            totals.purchases += 1
            inventory[item.rawValue] = 1
            effects.append(.pearlsSpent(item.price))
            // A theme applies on purchase; the picker can still switch.
            if let theme = item.themeID { themeID = theme }

        case .selectTheme(let item):
            guard inventory[item.rawValue, default: 0] > 0,
                  let theme = item.themeID else {
                effects.append(.purchaseDenied(item))
                break
            }
            themeID = theme

        case .equipHat(let item, let fishID):
            guard item.category == .hats,
                  inventory[item.rawValue, default: 0] > 0 else {
                effects.append(.purchaseDenied(item))
                break
            }
            // One hat, one head: take it off wherever it rides first.
            for (k, v) in hats where v == item.rawValue { hats.removeValue(forKey: k) }
            if let fishID { hats[fishID] = item.rawValue }

        case .collectDrop(let dropID):
            if let drop = drops.first(where: { $0.id == dropID }) {
                collect(drop)
            }

        case .tick:
            let nowS = now.timeIntervalSince1970
            for id in pets.keys.sorted() {
                var care = pets[id]!
                // Starvation: one stage per `starveAfter` of neglect,
                // floored at zero — a fish gets skinny, never dead.
                if care.stage > 0, nowS >= care.starvingAt {
                    care.stage -= 1
                    care.starvingAt = nowS + AquariumRules.starveAfter
                    pets[id] = care
                    effects.append(.fishShrank(id))
                }
                // A full-grown fish mints a drop every interval.
                if care.stage >= AquariumRules.dropStage,
                   nowS - care.lastDropAt >= AquariumRules.pearlDropInterval,
                   drops.count < AquariumRules.maxDrops {
                    dropSeq += 1
                    drops.append(PearlDrop(id: "drop-\(dropSeq)", fishID: id,
                                           at: nowS, value: AquariumRules.dropPearlValue))
                    care.lastDropAt = nowS
                    pets[id] = care
                }
            }
            // The snail collects whatever has sat long enough.
            if inventory[ShopItem.snail.rawValue, default: 0] > 0 {
                for drop in drops where nowS - drop.at >= AquariumRules.snailCollectAfter {
                    collect(drop)
                }
            }

        case .identify(let id, let label, let provider):
            guard var care = pets[id] else { break }
            if care.label != label || care.provider != provider {
                care.label = label
                care.provider = provider
                pets[id] = care
            }

        case .prune(let liveIDs):
            if pets.count > AquariumRules.maxPets {
                let dead = pets.filter { !liveIDs.contains($0.key) }
                    .sorted { $0.value.createdAt < $1.value.createdAt }
                for (id, _) in dead.prefix(pets.count - AquariumRules.maxPets) {
                    pets.removeValue(forKey: id)
                    hats.removeValue(forKey: id)
                }
            }
            // Drops whose fish is gone keep their value but lose the
            // anchor; leave them — the snail or a click still collects.

        case .setWindowOpen(let open):
            if open && !windowOpen {
                windowOpen = true
                if !away.isEmpty {
                    effects.append(.awaySummary(away))
                }
                away = AquariumAwaySummary(since: now.timeIntervalSince1970)
            } else if !open && windowOpen {
                windowOpen = false
                away = AquariumAwaySummary(since: now.timeIntervalSince1970)
            }
        }
        return effects
    }

    // MARK: Helpers

    /// The care record for `id`, creating it on first touch: a new
    /// fish starts nourished, with its starve clock and drop clock
    /// both counting from now.
    private mutating func pet(_ id: String, now: Date) -> FishCare {
        if let existing = pets[id] { return existing }
        let t = now.timeIntervalSince1970
        let fresh = FishCare(lastNourishedAt: t,
                             starvingAt: t + AquariumRules.starveAfter,
                             lastDropAt: t, createdAt: t)
        pets[id] = fresh
        return fresh
    }

    private func nourish(_ care: inout FishCare, now: Date) {
        let t = now.timeIntervalSince1970
        care.lastNourishedAt = t
        care.starvingAt = t + AquariumRules.starveAfter
    }

    /// Stage up while both budgets are met; the costs are spent, so
    /// each stage is K feedings + W work-seconds of its own.
    private func grow(_ care: inout FishCare, effects: inout [AquariumGameEffect], id: String) {
        while care.stage < AquariumRules.maxStage,
              care.feedings >= AquariumRules.feedingsPerStage,
              care.workSeconds >= AquariumRules.growthWorkSeconds {
            care.stage += 1
            care.feedings -= AquariumRules.feedingsPerStage
            care.workSeconds -= AquariumRules.growthWorkSeconds
            effects.append(.fishGrew(id))
        }
    }

    private mutating func earn(_ count: Int) {
        pearls += count
        lifetimePearls += count
        if !windowOpen { away.pearlsEarned += count }
    }

    private mutating func collect(_ drop: PearlDrop) {
        drops.removeAll { $0.id == drop.id }
        totals.dropsCollected += 1
        if !windowOpen { away.dropsCollected += 1 }
        earn(drop.value)
    }

    /// The raised fish that keep swimming while their sessions are
    /// gone (docs/TOYS.md: "sessions stay fish"): every pet at stage 1
    /// or above with a remembered name and provider, minus the live
    /// roster, best-raised first (then most recently fed), capped at
    /// `AquariumRules.maxResidents`. A resident is nourished only by
    /// feeding — that is what the pellets are for once the agents are
    /// off — and starvation still costs it stages, so a tank left
    /// alone for days quietly empties again.
    public func residents(excluding liveIDs: Set<String>) -> [AquariumResident] {
        pets.compactMap { id, care -> AquariumResident? in
            guard !liveIDs.contains(id), care.stage >= 1,
                  let label = care.label, !label.isEmpty,
                  let provider = care.provider, !provider.isEmpty else { return nil }
            return AquariumResident(id: id, label: label, provider: provider,
                                    stage: care.stage, lastNourishedAt: care.lastNourishedAt)
        }
        .sorted { a, b in
            a.stage != b.stage ? a.stage > b.stage
                : a.lastNourishedAt != b.lastNourishedAt ? a.lastNourishedAt > b.lastNourishedAt
                : a.id < b.id
        }
        .prefix(AquariumRules.maxResidents)
        .map { $0 }
    }

    /// The item the fish wears, if any.
    public func hat(for fishID: String) -> ShopItem? {
        hats[fishID].flatMap(ShopItem.init(rawValue:))
    }

    public func owns(_ item: ShopItem) -> Bool {
        inventory[item.rawValue, default: 0] > 0
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case pearls, lifetimePearls, pearlProgress, pets, inventory, themeID,
             hats, drops, streakDays, lastStreakDay, windowOpen, away, totals,
             dropSeq, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pearls = max(0, (try? c.decodeIfPresent(Int.self, forKey: .pearls)) ?? 0)
        lifetimePearls = max(0, (try? c.decodeIfPresent(Int.self, forKey: .lifetimePearls)) ?? 0)
        pearlProgress = max(0, (try? c.decodeIfPresent(Double.self, forKey: .pearlProgress)) ?? 0)
        pets = (try? c.decodeIfPresent([String: FishCare].self, forKey: .pets)) ?? [:]
        inventory = ((try? c.decodeIfPresent([String: Int].self, forKey: .inventory)) ?? [:])
            .filter { ShopItem(rawValue: $0.key) != nil && $0.value > 0 }
        themeID = (try? c.decodeIfPresent(String.self, forKey: .themeID)) ?? "classic"
        hats = ((try? c.decodeIfPresent([String: String].self, forKey: .hats)) ?? [:])
            .filter { ShopItem(rawValue: $0.value)?.category == .hats }
        drops = (try? c.decodeIfPresent([PearlDrop].self, forKey: .drops)) ?? []
        streakDays = max(0, (try? c.decodeIfPresent(Int.self, forKey: .streakDays)) ?? 0)
        lastStreakDay = max(0, (try? c.decodeIfPresent(Double.self, forKey: .lastStreakDay)) ?? 0)
        windowOpen = (try? c.decodeIfPresent(Bool.self, forKey: .windowOpen)) ?? false
        away = (try? c.decodeIfPresent(AquariumAwaySummary.self, forKey: .away)) ?? AquariumAwaySummary()
        totals = (try? c.decodeIfPresent(Totals.self, forKey: .totals)) ?? Totals()
        dropSeq = max(0, (try? c.decodeIfPresent(Int.self, forKey: .dropSeq)) ?? 0)
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        // A corrupt care record can't sink the file — clamp the stage.
        for (id, var care) in pets where care.stage < 0 || care.stage > AquariumRules.maxStage {
            care.stage = min(AquariumRules.maxStage, max(0, care.stage))
            pets[id] = care
        }
    }
}
