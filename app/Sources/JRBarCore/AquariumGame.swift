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
    /// Pellets per fish per day that count toward growth, pearls and the
    /// day's chore — past that, supper is just supper (it still
    /// nourishes). Sized to the pellets goal's target, so a one-fish
    /// tank can still finish the chore; ten pearls a day stays a trickle
    /// beside honest work's twelve an hour.
    public static let feedingsPerFishPerDay = 10
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
    /// With the tank closed, an owned snail picks up a drop after it
    /// has sat this long.
    public static let snailCollectAfter: TimeInterval = 10
    /// With the tank open the snail fetches drops itself — the view
    /// sends `.snailCollected` when it gets there — and the tick only
    /// sweeps up what has waited this long, so a drop it never reached
    /// is still paid.
    public static let snailBackstop: TimeInterval = 120
    /// Pet records kept at most. The prune lets passers-by go first —
    /// fish that never grew, the nameless before the named — then the
    /// oldest, and never a live session's fish or a resident.
    public static let maxPets = 64
    /// The most raised fish that keep swimming after their sessions
    /// are gone — enough for a tank that never reads empty, few enough
    /// that the live roster still stands out.
    public static let maxResidents = 6
    /// How often the toy feeds the model a tick (its own constant —
    /// the model takes whatever `dt` the tick carries).
    public static let tickInterval: TimeInterval = 20
    /// The longest silence between working beats the marathon clock
    /// forgives — a beat arriving after this gap starts a fresh stretch
    /// instead of paying a stale bank to the whale.
    public static let workContinuityGap: TimeInterval = tickInterval * 2
    /// Pearls the daily goal pays when its chore is done.
    public static let dailyGoalReward = 15
    /// A buried treasure surfaces this often…
    public static let treasureInterval: TimeInterval = 90 * 60
    /// …waits this long for a digger before sinking back…
    public static let treasureLifetime: TimeInterval = 6 * 60 * 60
    /// …and takes this many taps to dig up.
    public static let treasureTaps = 3
    /// Its value is this plus a few pearls per tank level.
    public static let treasureBaseValue = 10
    public static let treasureValuePerLevel = 3
    /// No visitor crosses twice inside this window.
    public static let visitorCooldown: TimeInterval = 24 * 60 * 60
    /// The whale visits when the tank has worked this long straight.
    public static let whaleWorkSeconds: TimeInterval = 2 * 60 * 60
    /// The marathon achievement wants this much unbroken work.
    public static let marathonSeconds: TimeInterval = 4 * 60 * 60
    /// The diver visits on today's nth completion.
    public static let diverCompletions = 10
    /// "A school": this many live sub-agents with one session at once.
    public static let schoolSize = 6
    /// "Clean week": completion days with no failed run between them.
    public static let cleanWeekDays = 7
}

/// The tank's shop: every spendable thing is one case. `rawValue` is
/// the save file's key — never rename a shipped case.
public enum ShopItem: String, Codable, CaseIterable, Sendable {
    // Decor — drawn on the sand once owned.
    case plant
    case rock
    case treasureChest
    case castle
    case driftwood
    case amphora
    case bubbleWall
    case anemoneBed
    case sunkenStatue
    case shipwreck
    case ruinedColumns
    case coralGarden
    case moonJellyLamp
    case volcano
    // Pets — live in the tank once owned.
    case snail
    case jellyfish
    case hermitCrab
    case cleanerShrimp
    case tetraSchool
    case seaTurtle
    case axolotl
    case octopus
    case manta
    // Accessories — worn like hats, in a slot of their own.
    case sunglasses
    case bowTie
    case monocle
    case headphones
    case scarf
    case topHat
    case tinyLaptop
    // Hats — worn by a chosen fish once owned.
    case hatBeanie
    case hatParty
    case hatCrown
    // For the buddy — the Notch Buddy wears these; one purse for both
    // toys, so the tank's pearls dress the pet too.
    case buddyBeanie
    case buddyBow
    case buddyFlower
    // Themes — water colour presets; midnight adds night lighting.
    case themeReef
    case themeLagoon
    case themeTwilight
    case themeMidnight
    case themeDawn
    case themeSunset
    case themeKelpForest
    case themeBlackwater
    case themeAbyss
    // Substrate & backdrop — the floor and the back wall.
    case sandWhite
    case gravelBlack
    case reefWallBackdrop
    case rockyBackdrop
    // The Arcade set — a loud, bright tank, look only — and the pets
    // and decor that play with it. Appended: the raw values are save
    // keys, and a build that doesn't know them keeps them anyway.
    case themeArcade
    case gravelCandy
    case toyReefBackdrop

    public enum Category: String, Equatable, Sendable, CaseIterable {
        case decor, pets, accessories, hats, buddy, themes, substrates

        public var displayName: String {
            switch self {
            case .decor: return "Decor"
            case .pets: return "Pets"
            case .accessories: return "Accessories"
            case .hats: return "Hats"
            case .buddy: return "For the buddy"
            case .themes: return "Themes"
            case .substrates: return "Substrate & backdrop"
            }
        }
    }

    public var category: Category {
        switch self {
        case .plant, .rock, .treasureChest, .castle, .driftwood, .amphora,
             .bubbleWall, .anemoneBed, .sunkenStatue, .shipwreck,
             .ruinedColumns, .coralGarden, .moonJellyLamp, .volcano:
            return .decor
        case .snail, .jellyfish, .hermitCrab, .cleanerShrimp, .tetraSchool,
             .seaTurtle, .axolotl, .octopus, .manta:
            return .pets
        case .sunglasses, .bowTie, .monocle, .headphones, .scarf,
             .topHat, .tinyLaptop:
            return .accessories
        case .hatBeanie, .hatParty, .hatCrown: return .hats
        case .buddyBeanie, .buddyBow, .buddyFlower: return .buddy
        case .themeReef, .themeLagoon, .themeTwilight, .themeMidnight,
             .themeDawn, .themeSunset, .themeKelpForest, .themeBlackwater,
             .themeAbyss, .themeArcade:
            return .themes
        case .sandWhite, .gravelBlack, .reefWallBackdrop, .rockyBackdrop,
             .gravelCandy, .toyReefBackdrop:
            return .substrates
        }
    }

    public var price: Int {
        switch self {
        case .rock: return 10
        case .plant: return 15
        case .hatBeanie: return 12
        case .buddyBow: return 22
        case .buddyBeanie: return 28
        case .buddyFlower: return 34
        case .hatParty: return 18
        case .bowTie: return 20
        case .themeReef, .themeLagoon, .sunglasses: return 25
        case .jellyfish, .monocle, .sandWhite: return 30
        case .themeTwilight, .driftwood, .scarf, .gravelCandy: return 35
        case .treasureChest, .hermitCrab, .themeDawn: return 40
        case .hatCrown, .headphones, .amphora, .gravelBlack: return 45
        case .snail: return 50
        case .bubbleWall, .themeKelpForest: return 55
        case .themeMidnight, .castle, .cleanerShrimp, .topHat, .themeSunset,
             .themeArcade:
            return 60
        case .anemoneBed: return 70
        case .themeBlackwater: return 75
        case .tinyLaptop, .rockyBackdrop: return 80
        case .ruinedColumns, .tetraSchool: return 90
        case .sunkenStatue: return 95
        case .reefWallBackdrop: return 100
        case .moonJellyLamp, .toyReefBackdrop: return 110
        case .shipwreck, .themeAbyss: return 120
        case .coralGarden: return 130
        case .axolotl: return 140
        case .volcano: return 150
        case .seaTurtle: return 160
        case .octopus: return 180
        case .manta: return 220
        }
    }

    /// The tank level the shop asks for before it sells this — a
    /// `tierUnlockLevel` index into `AquariumProgression`.
    public var tier: Int {
        switch self {
        case .castle, .themeMidnight, .snail, .hatCrown, .driftwood,
             .amphora, .bubbleWall, .cleanerShrimp, .monocle, .headphones,
             .scarf, .themeDawn, .gravelBlack, .themeArcade:
            return 1
        case .anemoneBed, .sunkenStatue, .shipwreck, .ruinedColumns,
             .tetraSchool, .seaTurtle, .topHat, .tinyLaptop, .themeSunset,
             .themeKelpForest, .themeBlackwater, .reefWallBackdrop,
             .rockyBackdrop, .toyReefBackdrop:
            return 2
        case .coralGarden, .moonJellyLamp, .volcano, .axolotl, .octopus,
             .themeAbyss:
            return 3
        case .manta: return 4
        default: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .plant: return "Leafy plant"
        case .rock: return "Big smooth rock"
        case .treasureChest: return "Treasure chest"
        case .castle: return "Little castle"
        case .driftwood: return "Driftwood"
        case .amphora: return "Amphora"
        case .bubbleWall: return "Bubble wall"
        case .anemoneBed: return "Anemone bed"
        case .sunkenStatue: return "Sunken statue"
        case .shipwreck: return "Shipwreck"
        case .ruinedColumns: return "Ruined columns"
        case .coralGarden: return "Coral garden"
        case .moonJellyLamp: return "Moon-jelly lamp"
        case .volcano: return "Bubble volcano"
        case .snail: return "Snail"
        case .jellyfish: return "Jellyfish"
        case .hermitCrab: return "Hermit crab"
        case .cleanerShrimp: return "Cleaner shrimp"
        case .tetraSchool: return "Tetra school"
        case .seaTurtle: return "Sea turtle"
        case .axolotl: return "Axolotl"
        case .octopus: return "Octopus"
        case .manta: return "Manta ray"
        case .sunglasses: return "Sunglasses"
        case .bowTie: return "Bow tie"
        case .monocle: return "Monocle"
        case .headphones: return "Headphones"
        case .scarf: return "Scarf"
        case .topHat: return "Top hat"
        case .tinyLaptop: return "Tiny laptop"
        case .hatBeanie: return "Beanie"
        case .hatParty: return "Party hat"
        case .hatCrown: return "Crown"
        case .buddyBeanie: return "Buddy beanie"
        case .buddyBow: return "Buddy bow"
        case .buddyFlower: return "Buddy flower"
        case .themeReef: return "Reef"
        case .themeLagoon: return "Lagoon"
        case .themeTwilight: return "Twilight"
        case .themeMidnight: return "Midnight"
        case .themeDawn: return "Dawn"
        case .themeSunset: return "Sunset"
        case .themeKelpForest: return "Kelp forest"
        case .themeBlackwater: return "Blackwater"
        case .themeAbyss: return "Abyss"
        case .sandWhite: return "White sand"
        case .gravelBlack: return "Black gravel"
        case .reefWallBackdrop: return "Reef wall"
        case .rockyBackdrop: return "Rocky backdrop"
        case .themeArcade: return "Arcade"
        case .gravelCandy: return "Candy gravel"
        case .toyReefBackdrop: return "Toy reef"
        }
    }

    /// One line about what owning it does, for the shop row.
    public var detail: String {
        switch self {
        case .plant: return "A leafy cluster for the sand."
        case .rock: return "A place to lurk behind."
        case .treasureChest: return "Burps bubbles. Very pirate."
        case .castle: return "Every tank needs one."
        case .driftwood: return "Beachcombed. Almost free of charge."
        case .amphora: return "A pot with history. Excellent hiding."
        case .bubbleWall: return "A curtain of bubbles along the back glass."
        case .anemoneBed: return "A ticklish patch for brave fish."
        case .sunkenStatue: return "Nobody remembers who it was."
        case .shipwreck: return "Sank with full honours."
        case .ruinedColumns: return "Once held up something important."
        case .coralGarden: return "A whole reef in miniature."
        case .moonJellyLamp: return "A soft glow after dark."
        case .volcano: return "Glows at night. Erupts bubbles, not lava."
        case .snail: return "Creeps the glass & collects dropped pearls for you."
        case .jellyfish: return "Drifts through the mid-water, unbothered."
        case .hermitCrab: return "Wanders the sand in a borrowed shell."
        case .cleanerShrimp: return "Visits the fish. Everyone feels better."
        case .tetraSchool: return "Seven little fish moving as one."
        case .seaTurtle: return "Glides through like it owns the place."
        case .axolotl: return "Permanently delighted."
        case .octopus: return "Hides in the amphora if you own one, else a rock."
        case .manta: return "Glides through occasionally, majestic and late."
        case .sunglasses: return "For a fish with nothing to prove."
        case .bowTie: return "Business casual gills."
        case .monocle: return "Distinguished. Slightly alarming."
        case .headphones: return "Do not disturb the flow state."
        case .scarf: return "The deep lanes get chilly."
        case .topHat: return "Formal swimming."
        case .tinyLaptop: return "Worn only while its fish is working."
        case .hatBeanie: return "A warm hat for a hard-working fish."
        case .hatParty: return "For a fish that finishes things."
        case .hatCrown: return "Royalty. Obviously."
        case .buddyBeanie: return "A knit beanie for the pet at the notch."
        case .buddyBow: return "A bow, worn slightly askew."
        case .buddyFlower: return "A flower tucked behind one ear."
        case .themeReef: return "Cool reef blues."
        case .themeLagoon: return "Bright shallow turquoise."
        case .themeTwilight: return "Deeper violet water."
        case .themeMidnight: return "Night lighting: dark water, moon rays."
        case .themeDawn: return "Early light over the sand."
        case .themeSunset: return "Golden hour, all hours."
        case .themeKelpForest: return "Green, dappled, enormous."
        case .themeBlackwater: return "Dark tannin water, glowing fish."
        case .themeAbyss: return "Bioluminescence. Bring your own light."
        case .sandWhite: return "A bright Caribbean floor."
        case .gravelBlack: return "Moody substrate, dramatic fish."
        case .reefWallBackdrop: return "A living wall behind the glass."
        case .rockyBackdrop: return "Canyon walls for the tank."
        case .themeArcade: return "Loud, bright and bubbly. Pearls come as coins."
        case .gravelCandy: return "Pet-store gravel in five colours."
        case .toyReefBackdrop: return "A painted set that changes as the tank climbs."
        }
    }

    /// Theme items only: the theme id `selectTheme` writes.
    public var themeID: String? {
        switch self {
        case .themeReef: return "reef"
        case .themeLagoon: return "lagoon"
        case .themeTwilight: return "twilight"
        case .themeMidnight: return "midnight"
        case .themeDawn: return "dawn"
        case .themeSunset: return "sunset"
        case .themeKelpForest: return "kelp"
        case .themeBlackwater: return "blackwater"
        case .themeAbyss: return "abyss"
        case .themeArcade: return "arcade"
        default: return nil
        }
    }

    /// Substrate items only: the substrate id `selectSubstrate` writes.
    public var substrateID: String? {
        switch self {
        case .sandWhite: return "white"
        case .gravelBlack: return "black"
        case .gravelCandy: return "candy"
        default: return nil
        }
    }

    /// Backdrop items only: the backdrop id `selectBackdrop` writes.
    public var backdropID: String? {
        switch self {
        case .reefWallBackdrop: return "reefwall"
        case .rockyBackdrop: return "rocky"
        case .toyReefBackdrop: return "toyreef"
        default: return nil
        }
    }

    /// Hats and accessories ride on a fish; everything else stays put.
    public var isWearable: Bool {
        category == .hats || category == .accessories
    }

    /// Whether the tank level has reached this item's shelf.
    public func isUnlocked(atLevel level: Int) -> Bool {
        level >= AquariumProgression.tierUnlockLevel(tier: tier)
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
    /// `calendar.startOfDay` epoch `feedingsToday` counts against — the
    /// per-day feeding cap's rollover marker.
    public var fedDay: Double
    /// Pellets counted today toward growth, pearls and the day's chore.
    public var feedingsToday: Int
    /// Every second its session worked, lifetime — `workSeconds` is spent
    /// on growth, this one never is. The tide stripe reads it.
    public var workedTotal: Double = 0
    /// The mark it earned (`AquariumVariant` raw value), kept for life —
    /// a resident wears it after its session is gone.
    public var variant: String?

    public init(stage: Int = 0, feedings: Int = 0, workSeconds: Double = 0,
                lastNourishedAt: Double = 0, starvingAt: Double = 0,
                lastDropAt: Double = 0, completionGranted: Bool = false,
                createdAt: Double = 0, label: String? = nil, provider: String? = nil,
                fedDay: Double = 0, feedingsToday: Int = 0) {
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
        self.fedDay = fedDay
        self.feedingsToday = feedingsToday
    }

    private enum CodingKeys: String, CodingKey {
        case stage, feedings, workSeconds, lastNourishedAt, starvingAt
        case lastDropAt, completionGranted, createdAt, label, provider
        case fedDay, feedingsToday, workedTotal, variant
    }

    /// Field-by-field tolerant decode: a record missing a newer key —
    /// or carrying one mistyped — fills that one field instead of
    /// sinking the whole `pets` dictionary on `try?`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = max(0, (try? c.decodeIfPresent(Int.self, forKey: .stage)) ?? 0)
        feedings = max(0, (try? c.decodeIfPresent(Int.self, forKey: .feedings)) ?? 0)
        workSeconds = max(0, (try? c.decodeIfPresent(Double.self, forKey: .workSeconds)) ?? 0)
        lastNourishedAt = (try? c.decodeIfPresent(Double.self, forKey: .lastNourishedAt)) ?? 0
        starvingAt = (try? c.decodeIfPresent(Double.self, forKey: .starvingAt)) ?? 0
        lastDropAt = (try? c.decodeIfPresent(Double.self, forKey: .lastDropAt)) ?? 0
        completionGranted = (try? c.decodeIfPresent(Bool.self, forKey: .completionGranted)) ?? false
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil
        fedDay = max(0, (try? c.decodeIfPresent(Double.self, forKey: .fedDay)) ?? 0)
        feedingsToday = max(0, (try? c.decodeIfPresent(Int.self, forKey: .feedingsToday)) ?? 0)
        workedTotal = max(0, (try? c.decodeIfPresent(Double.self, forKey: .workedTotal)) ?? 0)
        let variantRaw = (try? c.decodeIfPresent(String.self, forKey: .variant)) ?? nil
        variant = variantRaw.flatMap(AquariumVariant.init(rawValue:))?.rawValue
    }

    /// The mark it earned, if any.
    public var earnedVariant: AquariumVariant? { variant.flatMap(AquariumVariant.init(rawValue:)) }

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
/// `windowOpen` is false; opening drains them into an effect. Every
/// field names something that can genuinely happen closed — pearls &
/// completions ride in on session diffs, and `dropsCollected` is the
/// snail's rounds, credited by the reopen catch-up. (Feedings never
/// land while closed — a pellet is a tap — so the summary carries no
/// counter for them.)
public struct AquariumAwaySummary: Codable, Equatable, Sendable {
    /// When the accumulation window began (the close, or game start).
    public var since: Double
    public var pearlsEarned: Int
    public var completions: Int
    /// Drops the snail picked up while the tank was closed.
    public var dropsCollected: Int

    public init(since: Double = 0, pearlsEarned: Int = 0,
                completions: Int = 0, dropsCollected: Int = 0) {
        self.since = since
        self.pearlsEarned = pearlsEarned
        self.completions = completions
        self.dropsCollected = dropsCollected
    }

    public var isEmpty: Bool {
        pearlsEarned == 0 && completions == 0 && dropsCollected == 0
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
    /// Shop purchase; denied when unaffordable or already owned, and
    /// locked while the tank level hasn't reached the item's tier.
    case purchase(ShopItem)
    /// Apply an owned theme item's theme.
    case selectTheme(ShopItem)
    /// Put an owned hat on a fish (nil takes it off wherever it is).
    case equipHat(ShopItem, fishID: String?)
    /// Put an owned accessory on a fish — its own slot beside the hat
    /// (nil takes it off wherever it is). Non-accessories are denied.
    case equipAccessory(ShopItem, fishID: String?)
    /// Apply an owned substrate item's floor.
    case selectSubstrate(ShopItem)
    /// Apply an owned backdrop item's back wall.
    case selectBackdrop(ShopItem)
    /// A dig at the buried treasure by id.
    case digTreasure(String)
    /// A queued visitor finished its pass across the tank.
    case visitorShown(AquariumVisitor)
    /// The view's parade of this visitor ended — the departure beat,
    /// so the goodbye doesn't pass silently.
    case visitorDeparted(AquariumVisitor)
    /// A quota lane reset — the submarine comes to look.
    case quotaReset
    /// A clicked pearl drop.
    case collectDrop(String)
    /// The heartbeat: starvation, pearl drops, snail collection.
    case tick
    /// Drop pet records over the cap: never one in `liveIDs` or a
    /// current resident; small nameless fish first, then small named
    /// ones, then the oldest.
    case prune(liveIDs: Set<String>)
    /// The snail reached a drop on the sand and picked it up — paid
    /// exactly like a click. A drop already gone is a no-op.
    case snailCollected(dropID: String)
    /// Remember what a listed session's fish is called and who it
    /// belongs to — only on a record that already exists; a session
    /// that merely swims through earns no record.
    case identify(id: String, label: String, provider: String)
    /// The tank window opened or closed; opening drains `away`.
    case setWindowOpen(Bool)
    /// One daemon document's fleet facts — schools, failures, weekly
    /// windows, banked credits — for the milestones only the daemon
    /// could know about.
    case fleet(AquariumFleetFacts)
    /// Put a surface back to the tank's own: the classic water, sand or
    /// back wall. Always allowed — nothing has to be owned to go home.
    case useClassic(AquariumSurface)
}

/// The three surfaces a tank dresses: the water, the floor and the
/// back wall. Each has a classic look the tank starts with.
public enum AquariumSurface: String, Codable, CaseIterable, Sendable {
    case water, floor, wall
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
    /// The item's tier sits above the tank level — how far it needs.
    case purchaseLocked(ShopItem, needsLevel: Int)
    /// A milestone paid its reward; `unlocked` remembers it.
    case achievementUnlocked(AquariumAchievement)
    /// Today's chore hit its target and paid the reward.
    case dailyGoalMet(AquariumDailyGoal)
    /// The third dig landed; carries the pearls it paid.
    case treasureFound(Int)
    /// A visitor queued — the view parades it, then `visitorShown`.
    case visitor(AquariumVisitor)
    /// The visitor's parade ended — the toast's goodbye.
    case visitorDeparted(AquariumVisitor)
    /// Emitted once on `setWindowOpen(true)` when things happened while
    /// the tank was closed; carries the drained counters.
    case awaySummary(AquariumAwaySummary)
    case fishGrew(String)
    case fishShrank(String)
    /// The streak moved to this many days.
    case streakDay(Int)
    /// A fish earned its mark from what its session did.
    case variantEarned(String, AquariumVariant)
}

/// A mark a fish earns from its session's real work (docs/TOYS.md) —
/// rarity that means something, instead of the golden fish's seeded
/// dice. One per fish, first earned wins, kept for life. The raw value
/// is the save's key: never rename a shipped case.
public enum AquariumVariant: String, Codable, CaseIterable, Sendable {
    /// A pale stripe down the flank: its session worked two hours.
    case tide
    /// Six star specks: its session led six sub-agents at once.
    case starry

    /// The inspector's word for it.
    public var word: String {
        switch self {
        case .tide: return "tide-striped"
        case .starry: return "starry"
        }
    }

    /// Two hours of a session's work earn the tide stripe.
    public static let tideSeconds: Double = 2 * 60 * 60
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
    /// Items a newer build sold that this one doesn't know, kept as they
    /// were and written back beside `inventory` — so opening the tank in
    /// an older build never throws away a purchase or the pearls it cost.
    public var unknownInventory: [String: Int] = [:]
    /// The active water theme: "classic" plus the shop's theme ids.
    public var themeID: String
    /// Session id → hat item raw value.
    public var hats: [String: String]
    /// Session id → accessory item raw value — the second wearable slot.
    public var accessories: [String: String]
    /// The active floor: "classic" plus the shop's substrate ids.
    public var substrateID: String
    /// The active back wall: "classic" plus the shop's backdrop ids.
    public var backdropID: String
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
    /// Achievement raw value → the epoch it unlocked.
    public var unlocked: [String: Double]
    /// Today's chore; nil until the first event of the save's day.
    public var dailyGoal: AquariumDailyGoal?
    /// Leftover work seconds toward the goal's whole minutes.
    public var goalCarrySeconds: Double
    /// The buried treasure, while one is in the sand.
    public var treasure: AquariumTreasure?
    /// The epoch the last treasure spawned (or was dug); paces the next.
    public var lastTreasureAt: Double
    /// Visitors queued for a pass across the tank.
    public var pendingVisitors: [AquariumVisitor]
    /// Visitor raw value → the epoch it last queued (the 24 h gate).
    public var lastVisitorAt: [String: Double]
    /// Unbroken work time — feeds the whale and the marathon.
    public var continuousWorkSeconds: Double
    /// Epoch of the last working `workTick`; a quiet tick decays it.
    public var lastWorkAt: Double
    /// Completions on the current streak day; feeds the diver.
    public var completionsToday: Int
    /// The fleet the tank has watched, for the milestones about the
    /// work itself (`AquariumFleetLog`).
    public var fleet: AquariumFleetLog = AquariumFleetLog()
    /// Card › Fine-tune › Visitors: while false no visitor queues at all,
    /// the alien included. A setting, not part of the save — the toy
    /// keeps it in step with the card.
    public var visitorsWelcome = true

    public struct Totals: Codable, Equatable, Sendable {
        public var feedings: Int
        public var completions: Int
        public var purchases: Int
        public var dropsCollected: Int
        public var treasuresFound: Int
        public var visitorsSeen: Int

        public init(feedings: Int = 0, completions: Int = 0,
                    purchases: Int = 0, dropsCollected: Int = 0,
                    treasuresFound: Int = 0, visitorsSeen: Int = 0) {
            self.feedings = feedings
            self.completions = completions
            self.purchases = purchases
            self.dropsCollected = dropsCollected
            self.treasuresFound = treasuresFound
            self.visitorsSeen = visitorsSeen
        }

        // Tolerant like the game itself: a save written before
        // `treasuresFound`/`visitorsSeen` existed still loads its
        // counters — synthesized decoding would throw on the missing
        // keys and the `try?` in the game's decoder would drop them all.
        private enum CodingKeys: String, CodingKey {
            case feedings, completions, purchases, dropsCollected,
                 treasuresFound, visitorsSeen
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            feedings = max(0, (try? c.decodeIfPresent(Int.self, forKey: .feedings)) ?? 0)
            completions = max(0, (try? c.decodeIfPresent(Int.self, forKey: .completions)) ?? 0)
            purchases = max(0, (try? c.decodeIfPresent(Int.self, forKey: .purchases)) ?? 0)
            dropsCollected = max(0, (try? c.decodeIfPresent(Int.self, forKey: .dropsCollected)) ?? 0)
            treasuresFound = max(0, (try? c.decodeIfPresent(Int.self, forKey: .treasuresFound)) ?? 0)
            visitorsSeen = max(0, (try? c.decodeIfPresent(Int.self, forKey: .visitorsSeen)) ?? 0)
        }
    }

    public init(pearls: Int = 0, lifetimePearls: Int = 0, pearlProgress: Double = 0,
                pets: [String: FishCare] = [:], inventory: [String: Int] = [:],
                themeID: String = "classic", hats: [String: String] = [:],
                drops: [PearlDrop] = [], streakDays: Int = 0, lastStreakDay: Double = 0,
                windowOpen: Bool = false, away: AquariumAwaySummary = AquariumAwaySummary(),
                totals: Totals = Totals(), dropSeq: Int = 0, createdAt: Double = 0,
                accessories: [String: String] = [:], substrateID: String = "classic",
                backdropID: String = "classic", unlocked: [String: Double] = [:],
                dailyGoal: AquariumDailyGoal? = nil, goalCarrySeconds: Double = 0,
                treasure: AquariumTreasure? = nil, lastTreasureAt: Double = 0,
                pendingVisitors: [AquariumVisitor] = [],
                lastVisitorAt: [String: Double] = [:],
                continuousWorkSeconds: Double = 0, lastWorkAt: Double = 0,
                completionsToday: Int = 0) {
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
        self.accessories = accessories
        self.substrateID = substrateID
        self.backdropID = backdropID
        self.unlocked = unlocked
        self.dailyGoal = dailyGoal
        self.goalCarrySeconds = goalCarrySeconds
        self.treasure = treasure
        self.lastTreasureAt = lastTreasureAt
        self.pendingVisitors = pendingVisitors
        self.lastVisitorAt = lastVisitorAt
        self.continuousWorkSeconds = continuousWorkSeconds
        self.lastWorkAt = lastWorkAt
        self.completionsToday = completionsToday
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
        // Every event keeps the day's chore current before it lands.
        syncDailyGoal(now: now, calendar: calendar)
        switch event {
        case .workTick(let seconds, let working):
            // A beat with nobody working snaps the marathon clock.
            if working.isEmpty {
                continuousWorkSeconds = 0
                break
            }
            guard seconds > 0 else { break }
            // A beat arriving long after the last working one is a new
            // stretch, not a continuation — a stale bank mustn't pay
            // the whale or the marathon for time nobody saw. The quiet
            // `.tick` decay below is the same clock for the pause side.
            if lastWorkAt > 0,
               now.timeIntervalSince1970 - lastWorkAt > AquariumRules.workContinuityGap {
                continuousWorkSeconds = 0
            }
            continuousWorkSeconds += seconds
            lastWorkAt = now.timeIntervalSince1970
            // Two unbroken hours at it and the whale comes to look.
            if continuousWorkSeconds >= AquariumRules.whaleWorkSeconds {
                queueVisitor(.whale, now: now, effects: &effects)
            }
            // The goal counts whole minutes; the carry keeps the rest.
            goalCarrySeconds += seconds
            let wholeMinutes = Int(goalCarrySeconds / 60)
            if wholeMinutes > 0 {
                goalCarrySeconds -= Double(wholeMinutes) * 60
                advanceDailyGoal(.workMinutes, by: wholeMinutes,
                                 effects: &effects)
            }
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
                care.workedTotal += seconds
                if care.variant == nil, care.workedTotal >= AquariumVariant.tideSeconds {
                    care.variant = AquariumVariant.tide.rawValue
                    effects.append(.variantEarned(id, .tide))
                }
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
            advanceDailyGoal(.completions, by: 1, effects: &effects)
            // The daily streak: one counted completion per calendar
            // day, consecutive days extend it, a gap restarts it.
            let today = calendar.startOfDay(for: now).timeIntervalSince1970
            fleet.noteCompletion(day: today)
            completionsToday = lastStreakDay == today ? completionsToday + 1 : 1
            if completionsToday >= AquariumRules.diverCompletions {
                queueVisitor(.diver, now: now, effects: &effects)
            }
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
            // A fish counts only so many pellets a day — past the cap,
            // supper is just supper. It still nourishes (a fed fish is
            // a fed fish), but growth, the pearl, the totals and the
            // day's chore stop listening, so tapping can't out-earn
            // honest work or stockpile stages.
            let today = calendar.startOfDay(for: now).timeIntervalSince1970
            if care.fedDay != today {
                care.fedDay = today
                care.feedingsToday = 0
            }
            let counted = care.feedingsToday < AquariumRules.feedingsPerFishPerDay
            if counted {
                care.feedings += 1
                care.feedingsToday += 1
            }
            nourish(&care, now: now)
            if counted {
                grow(&care, effects: &effects, id: fishID)
            }
            pets[fishID] = care
            if counted {
                totals.feedings += 1
                earn(AquariumRules.pelletPearl)
                effects.append(.pearlsEarned(AquariumRules.pelletPearl))
                advanceDailyGoal(.pellets, by: 1, effects: &effects)
            }

        case .purchase(let item):
            guard inventory[item.rawValue, default: 0] == 0 else {
                effects.append(.purchaseDenied(item))
                break
            }
            // The deeper shelves wait for the tank to climb the ladder.
            let needsLevel = AquariumProgression.tierUnlockLevel(tier: item.tier)
            guard tankLevel >= needsLevel else {
                effects.append(.purchaseLocked(item, needsLevel: needsLevel))
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
            // Same for the floor and the back wall.
            if let theme = item.themeID { themeID = theme }
            if let substrate = item.substrateID { substrateID = substrate }
            if let backdrop = item.backdropID { backdropID = backdrop }

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

        case .equipAccessory(let item, let fishID):
            guard item.category == .accessories,
                  inventory[item.rawValue, default: 0] > 0 else {
                effects.append(.purchaseDenied(item))
                break
            }
            // Same rule as hats: one accessory, one fish at a time.
            for (k, v) in accessories where v == item.rawValue {
                accessories.removeValue(forKey: k)
            }
            if let fishID { accessories[fishID] = item.rawValue }

        case .selectSubstrate(let item):
            guard inventory[item.rawValue, default: 0] > 0,
                  let substrate = item.substrateID else {
                effects.append(.purchaseDenied(item))
                break
            }
            substrateID = substrate

        case .selectBackdrop(let item):
            guard inventory[item.rawValue, default: 0] > 0,
                  let backdrop = item.backdropID else {
                effects.append(.purchaseDenied(item))
                break
            }
            backdropID = backdrop

        case .digTreasure(let treasureID):
            guard var find = treasure, find.id == treasureID else { break }
            find.taps += 1
            if find.taps >= AquariumRules.treasureTaps {
                treasure = nil
                lastTreasureAt = now.timeIntervalSince1970
                totals.treasuresFound += 1
                earn(find.value)
                effects.append(.treasureFound(find.value))
            } else {
                treasure = find
            }

        case .visitorShown(let visitor):
            if pendingVisitors.contains(visitor) {
                pendingVisitors.removeAll { $0 == visitor }
                totals.visitorsSeen += 1
            }

        case .visitorDeparted(let visitor):
            // Nothing to write down — the departure is a beat for the
            // toast, the goodbye to the arrival's hello.
            effects.append(.visitorDeparted(visitor))

        case .quotaReset:
            queueVisitor(.submarine, now: now, effects: &effects)

        case .collectDrop(let dropID):
            if let drop = drops.first(where: { $0.id == dropID }) {
                collect(drop, effects: &effects)
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
            // The snail collects whatever has sat long enough. With the
            // window closed that is its old ten seconds; with it open the
            // snail fetches in the view, and this is only the backstop.
            if owns(.snail) {
                let wait = windowOpen ? AquariumRules.snailBackstop
                    : AquariumRules.snailCollectAfter
                for drop in drops where nowS - drop.at >= wait {
                    collect(drop, effects: &effects)
                }
            }
            // Quiet too long after the last work beat — the marathon
            // clock runs out (a beat with nobody working snaps it too,
            // and a stale bank on the next working beat is the same gap).
            if nowS - lastWorkAt > AquariumRules.workContinuityGap {
                continuousWorkSeconds = 0
            }
            // A treasure left buried eventually sinks back into the sand;
            // the interval paces the next glint from the sinking, not
            // the burial — else one would surface again the same tick.
            if let find = treasure, nowS - find.buriedAt >= AquariumRules.treasureLifetime {
                treasure = nil
                lastTreasureAt = nowS
            }
            // Every `treasureInterval` a new glint surfaces — the spot
            // is hashed off the interval bucket, so the same clock
            // buries the same chest in every tank.
            if treasure == nil,
               nowS - lastTreasureAt >= AquariumRules.treasureInterval {
                let bucket = Int(nowS / AquariumRules.treasureInterval)
                let hash = AquariumModel.stableHash("treasure-\(bucket)")
                treasure = AquariumTreasure(
                    id: "treasure-\(bucket)",
                    x: 0.08 + 0.84 * Double(hash & 0xFFFF) / 0xFFFF,
                    taps: 0, buriedAt: nowS,
                    value: AquariumRules.treasureBaseValue
                        + AquariumRules.treasureValuePerLevel * tankLevel)
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
                let keep = liveIDs.union(residents(excluding: liveIDs).map(\.id))
                let dead = pets.filter { !keep.contains($0.key) }
                    .sorted { a, b in
                        let ra = Self.pruneRank(a.value), rb = Self.pruneRank(b.value)
                        if ra != rb { return ra < rb }
                        if a.value.createdAt != b.value.createdAt {
                            return a.value.createdAt < b.value.createdAt
                        }
                        return a.key < b.key
                    }
                for (id, _) in dead.prefix(pets.count - AquariumRules.maxPets) {
                    pets.removeValue(forKey: id)
                    hats.removeValue(forKey: id)
                    accessories.removeValue(forKey: id)
                }
            }
            // Drops whose fish is gone keep their value but lose the
            // anchor; leave them — the snail or a click still collects.

        case .setWindowOpen(let open):
            if open && !windowOpen {
                // The snail kept its rounds while the tank was closed:
                // before the reopen drains the summary it picks up
                // every drop that has sat past `snailCollectAfter` —
                // the same pass `.tick` runs, once per qualifying drop,
                // credited to the away window it ripened in. Drops only
                // age in place (the tick that mints them doesn't run
                // while closed), so this is deterministic catch-up, not
                // a wall-clock guess.
                if inventory[ShopItem.snail.rawValue, default: 0] > 0 {
                    let nowS = now.timeIntervalSince1970
                    for drop in drops
                    where nowS - drop.at >= AquariumRules.snailCollectAfter {
                        collect(drop, effects: &effects)
                    }
                }
                windowOpen = true
                if !away.isEmpty {
                    effects.append(.awaySummary(away))
                }
                away = AquariumAwaySummary(since: now.timeIntervalSince1970)
            } else if !open && windowOpen {
                windowOpen = false
                away = AquariumAwaySummary(since: now.timeIntervalSince1970)
            }

        case .fleet(let facts):
            // The log moves for the milestone sweep below; a session
            // leading a school of six earns its fish the star specks.
            fleet.note(facts, now: now)
            for (parent, size) in facts.schools.sorted(by: { $0.key < $1.key })
            where size >= AquariumRules.schoolSize {
                var care = pet(parent, now: now)
                guard care.variant == nil else { continue }
                care.variant = AquariumVariant.starry.rawValue
                pets[parent] = care
                effects.append(.variantEarned(parent, .starry))
            }

        case .snailCollected(let dropID):
            if owns(.snail), let drop = drops.first(where: { $0.id == dropID }) {
                collect(drop, effects: &effects)
            }

        case .useClassic(let surface):
            switch surface {
            case .water: themeID = "classic"
            case .floor: substrateID = "classic"
            case .wall: backdropID = "classic"
            }
        }
        checkAchievements(now: now, event: event,
                          calendar: calendar, effects: &effects)
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

    /// Who the prune lets go first: a fish that never grew and was
    /// never named (0), a small named one (1), then everything else (2).
    private static func pruneRank(_ care: FishCare) -> Int {
        guard care.stage == 0 else { return 2 }
        return (care.label ?? "").isEmpty ? 0 : 1
    }

    private mutating func earn(_ count: Int) {
        pearls += count
        lifetimePearls += count
        if !windowOpen { away.pearlsEarned += count }
    }

    private mutating func collect(_ drop: PearlDrop,
                                  effects: inout [AquariumGameEffect]) {
        drops.removeAll { $0.id == drop.id }
        totals.dropsCollected += 1
        if !windowOpen { away.dropsCollected += 1 }
        earn(drop.value)
        advanceDailyGoal(.dropsCollected, by: 1, effects: &effects)
    }

    /// Keeps `dailyGoal` on today's chore: a nil goal or a goal dated
    /// to another `startOfDay` is replaced fresh — progress never
    /// carries across midnight.
    private mutating func syncDailyGoal(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        if let goal = dailyGoal, goal.day == today { return }
        let kind = AquariumDailyGoal.Kind.forDay(today)
        dailyGoal = AquariumDailyGoal(kind: kind, target: kind.target,
                                      day: today)
        goalCarrySeconds = 0
    }

    /// Feeds progress into today's goal when the kinds match; hitting
    /// the target claims the reward once — a `claimed` goal is inert
    /// for the rest of its day.
    private mutating func advanceDailyGoal(
        _ kind: AquariumDailyGoal.Kind, by amount: Int,
        effects: inout [AquariumGameEffect]
    ) {
        guard amount > 0, var goal = dailyGoal,
              goal.kind == kind, !goal.claimed else { return }
        goal.progress += amount
        if goal.progress >= goal.target {
            goal.claimed = true
            earn(AquariumRules.dailyGoalReward)
            effects.append(.dailyGoalMet(goal))
        }
        dailyGoal = goal
    }

    /// Queues a visitor once per cooldown — the stamp lands when it
    /// queues, so a trigger that fires while it's already pending or
    /// still inside the window does nothing. With visitors turned off
    /// nothing queues and no cooldown starts.
    private mutating func queueVisitor(
        _ visitor: AquariumVisitor, now: Date,
        effects: inout [AquariumGameEffect]
    ) {
        let nowS = now.timeIntervalSince1970
        guard visitorsWelcome,
              nowS - (lastVisitorAt[visitor.rawValue] ?? 0)
                >= AquariumRules.visitorCooldown,
              !pendingVisitors.contains(visitor) else { return }
        pendingVisitors.append(visitor)
        lastVisitorAt[visitor.rawValue] = nowS
        effects.append(.visitor(visitor))
    }

    /// The milestone sweep — run after every event so an old save
    /// that's already earned things collects them on its first tick.
    /// `unlocked` is the memory: each achievement pays exactly once.
    private mutating func checkAchievements(
        now: Date, event: AquariumEvent, calendar: Calendar,
        effects: inout [AquariumGameEffect]
    ) {
        func unlock(_ achievement: AquariumAchievement, _ earned: Bool) {
            guard earned, unlocked[achievement.rawValue] == nil else { return }
            unlocked[achievement.rawValue] = now.timeIntervalSince1970
            earn(achievement.reward)
            effects.append(.achievementUnlocked(achievement))
        }
        unlock(.firstPearl, lifetimePearls >= 1)
        unlock(.firstPurchase, totals.purchases >= 1)
        unlock(.fullGrown,
               pets.values.contains { $0.stage >= AquariumRules.maxStage })
        unlock(.fiveResidents,
               pets.values.filter { $0.stage >= 1 }.count >= 5)
        unlock(.streak7, streakDays >= 7)
        unlock(.streak30, streakDays >= 30)
        unlock(.hundredPellets, totals.feedings >= 100)
        unlock(.hundredCompletions, totals.completions >= 100)
        if case .sessionCompleted = event {
            let hour = calendar.component(.hour, from: now)
            unlock(.nightOwl, hour < 5)
            unlock(.earlyBird, hour >= 5 && hour < 7)
        }
        let ownedCount = inventory.values.reduce(0, +)
        unlock(.collector, ownedCount >= 10)
        unlock(.curator, ownedCount >= 25)
        unlock(.level5, tankLevel >= 5)
        unlock(.level9, tankLevel >= 9)
        unlock(.treasureHunter, totals.treasuresFound >= 1)
        unlock(.marathon,
               continuousWorkSeconds >= AquariumRules.marathonSeconds)
        // The work's own milestones, from the fleet the tank watched.
        unlock(.school, fleet.largestSchool >= AquariumRules.schoolSize)
        unlock(.cleanWeek, fleet.cleanDays >= AquariumRules.cleanWeekDays)
        unlock(.underBudget, fleet.underBudgetResets >= 1)
        unlock(.bankedCredits, fleet.creditGains >= 1)
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

    /// Where the tank sits on the ladder — derived, never stored, so
    /// an old save's lifetime earnings place it immediately.
    public var tankLevel: Int {
        AquariumProgression.tankLevel(lifetimePearls: lifetimePearls)
    }

    /// The item the fish wears, if any.
    public func hat(for fishID: String) -> ShopItem? {
        hats[fishID].flatMap(ShopItem.init(rawValue:))
    }

    /// The accessory the fish wears, if any — the second slot.
    public func accessory(for fishID: String) -> ShopItem? {
        accessories[fishID].flatMap(ShopItem.init(rawValue:))
    }

    public func owns(_ item: ShopItem) -> Bool {
        inventory[item.rawValue, default: 0] > 0
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case pearls, lifetimePearls, pearlProgress, pets, inventory, themeID,
             hats, drops, streakDays, lastStreakDay, windowOpen, away, totals,
             dropSeq, createdAt, accessories, substrateID, backdropID,
             unlocked, dailyGoal, goalCarrySeconds, treasure, lastTreasureAt,
             pendingVisitors, lastVisitorAt, continuousWorkSeconds,
             lastWorkAt, completionsToday, fleet
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pearls = max(0, (try? c.decodeIfPresent(Int.self, forKey: .pearls)) ?? 0)
        lifetimePearls = max(0, (try? c.decodeIfPresent(Int.self, forKey: .lifetimePearls)) ?? 0)
        pearlProgress = max(0, (try? c.decodeIfPresent(Double.self, forKey: .pearlProgress)) ?? 0)
        pets = (try? c.decodeIfPresent([String: FishCare].self, forKey: .pets)) ?? [:]
        let owned = ((try? c.decodeIfPresent([String: Int].self, forKey: .inventory)) ?? [:])
            .filter { $0.value > 0 }
        inventory = owned.filter { ShopItem(rawValue: $0.key) != nil }
        unknownInventory = owned.filter { ShopItem(rawValue: $0.key) == nil }
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
        accessories = ((try? c.decodeIfPresent([String: String].self, forKey: .accessories)) ?? [:])
            .filter { ShopItem(rawValue: $0.value)?.category == .accessories }
        substrateID = (try? c.decodeIfPresent(String.self, forKey: .substrateID)) ?? "classic"
        backdropID = (try? c.decodeIfPresent(String.self, forKey: .backdropID)) ?? "classic"
        unlocked = (try? c.decodeIfPresent([String: Double].self, forKey: .unlocked)) ?? [:]
        dailyGoal = try? c.decodeIfPresent(AquariumDailyGoal.self, forKey: .dailyGoal)
        goalCarrySeconds = max(0, (try? c.decodeIfPresent(Double.self, forKey: .goalCarrySeconds)) ?? 0)
        treasure = try? c.decodeIfPresent(AquariumTreasure.self, forKey: .treasure)
        lastTreasureAt = max(0, (try? c.decodeIfPresent(Double.self, forKey: .lastTreasureAt)) ?? 0)
        pendingVisitors = ((try? c.decodeIfPresent([String].self, forKey: .pendingVisitors)) ?? [])
            .compactMap(AquariumVisitor.init(rawValue:))
        lastVisitorAt = (try? c.decodeIfPresent([String: Double].self, forKey: .lastVisitorAt)) ?? [:]
        continuousWorkSeconds = max(0, (try? c.decodeIfPresent(Double.self, forKey: .continuousWorkSeconds)) ?? 0)
        lastWorkAt = max(0, (try? c.decodeIfPresent(Double.self, forKey: .lastWorkAt)) ?? 0)
        completionsToday = max(0, (try? c.decodeIfPresent(Int.self, forKey: .completionsToday)) ?? 0)
        fleet = (try? c.decodeIfPresent(AquariumFleetLog.self, forKey: .fleet)) ?? AquariumFleetLog()
        // A corrupt care record can't sink the file — clamp the stage.
        for (id, var care) in pets where care.stage < 0 || care.stage > AquariumRules.maxStage {
            care.stage = min(AquariumRules.maxStage, max(0, care.stage))
            pets[id] = care
        }
    }

    /// Every field, as the decoder reads it — with the items this build
    /// doesn't know folded back into `inventory`, so a newer build's
    /// purchases survive a round trip through this one.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pearls, forKey: .pearls)
        try c.encode(lifetimePearls, forKey: .lifetimePearls)
        try c.encode(pearlProgress, forKey: .pearlProgress)
        try c.encode(pets, forKey: .pets)
        try c.encode(inventory.merging(unknownInventory) { known, _ in known }, forKey: .inventory)
        try c.encode(themeID, forKey: .themeID)
        try c.encode(hats, forKey: .hats)
        try c.encode(drops, forKey: .drops)
        try c.encode(streakDays, forKey: .streakDays)
        try c.encode(lastStreakDay, forKey: .lastStreakDay)
        try c.encode(windowOpen, forKey: .windowOpen)
        try c.encode(away, forKey: .away)
        try c.encode(totals, forKey: .totals)
        try c.encode(dropSeq, forKey: .dropSeq)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(accessories, forKey: .accessories)
        try c.encode(substrateID, forKey: .substrateID)
        try c.encode(backdropID, forKey: .backdropID)
        try c.encode(unlocked, forKey: .unlocked)
        try c.encodeIfPresent(dailyGoal, forKey: .dailyGoal)
        try c.encode(goalCarrySeconds, forKey: .goalCarrySeconds)
        try c.encodeIfPresent(treasure, forKey: .treasure)
        try c.encode(lastTreasureAt, forKey: .lastTreasureAt)
        try c.encode(pendingVisitors, forKey: .pendingVisitors)
        try c.encode(lastVisitorAt, forKey: .lastVisitorAt)
        try c.encode(continuousWorkSeconds, forKey: .continuousWorkSeconds)
        try c.encode(lastWorkAt, forKey: .lastWorkAt)
        try c.encode(completionsToday, forKey: .completionsToday)
        try c.encode(fleet, forKey: .fleet)
    }
}
