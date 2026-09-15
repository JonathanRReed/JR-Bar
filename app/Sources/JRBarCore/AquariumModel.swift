import Foundation

/// What a session's fish is doing in the tank (docs/TOYS.md): working
/// swims, idle holds midwater and sips the surface now and then,
/// waiting on you comes up to the glass and pulses a ring, failed
/// goes grey and sinks onto its side, a finished run spirals up and
/// out the top-right. Reduced from `SessionActivity`, so the tank can
/// never disagree with the panel about what a session is.
public enum FishState: String, Equatable, Sendable, CaseIterable {
    case swimming
    /// Idle: a slow midwater drift with an occasional surface sip.
    case idling
    case surfacing
    case sinking
    case leaving
}

/// The kind of fish a provider swims as (docs/TOYS.md): pure data —
/// the view owns the silhouettes — so the mapping from provider id to
/// shape is testable. Anything the table doesn't know is a minnow.
public enum FishSpecies: String, Equatable, Sendable, CaseIterable {
    /// The generic fallback fish.
    case minnow
    /// Bold bars & rounded fins — claude's orange suits it.
    case clownfish
    /// A tall disc with long trailing fins.
    case angelfish
    /// Nearly round, spiky bumps & spots.
    case puffer
    /// A long blade of a fish with a tall dorsal.
    case shark
    /// Upright, curled tail, little crown.
    case seahorse
    /// An oval body under big flowing fins.
    case betta
    /// Minnow-shaped with a bold band over the tail end.
    case tang
    /// Small & slim with a bright stripe.
    case tetra

    /// The marking the view paints over the silhouette.
    public enum Pattern: String, Equatable, Sendable {
        case plain
        /// Vertical bars, clownfish-style.
        case bars
        /// A scatter of dark dots.
        case spots
        /// One bold band over the tail end.
        case band
    }

    /// The picker's name for the species.
    public var displayName: String {
        switch self {
        case .minnow: return "Minnow"
        case .clownfish: return "Clownfish"
        case .angelfish: return "Angelfish"
        case .puffer: return "Puffer"
        case .shark: return "Shark"
        case .seahorse: return "Seahorse"
        case .betta: return "Betta"
        case .tang: return "Tang"
        case .tetra: return "Tetra"
        }
    }

    /// Provider id → species. Case-insensitive; anything the table
    /// doesn't know is a minnow.
    public static func forProvider(_ provider: String) -> FishSpecies {
        switch provider.lowercased() {
        case "claude": return .clownfish
        case "codex", "grok": return .shark
        case "gemini": return .angelfish
        case "antigravity", "openclaw": return .puffer
        case "hermes": return .seahorse
        case "opencode", "kiro", "t3code": return .betta
        case "devin": return .tang
        case "cursor", "pi": return .tetra
        default: return .minnow
        }
    }

    /// Length multiplier on the base fish: a shark runs big, a tetra small.
    public var sizeScale: Double {
        switch self {
        case .shark: return 1.32
        case .angelfish: return 1.05
        case .betta: return 1.05
        case .clownfish, .tang: return 1.0
        case .minnow: return 0.95
        case .puffer: return 0.85
        case .seahorse: return 0.80
        case .tetra: return 0.70
        }
    }

    /// Body height as a fraction of length: a puffer is nearly round,
    /// a shark is a blade, a seahorse stands taller than it is long.
    public var aspect: Double {
        switch self {
        case .seahorse: return 1.15
        case .angelfish: return 1.05
        case .puffer: return 0.95
        case .clownfish, .betta: return 0.62
        case .tang: return 0.60
        case .minnow: return 0.52
        case .tetra: return 0.42
        case .shark: return 0.36
        }
    }

    public var pattern: Pattern {
        switch self {
        case .clownfish: return .bars
        case .puffer: return .spots
        case .tang: return .band
        case .minnow, .angelfish, .shark, .seahorse, .betta, .tetra: return .plain
        }
    }
}

/// One fish: one session's label, provider and place in the tank.
/// `lane`, `speed` and `direction` are assigned once, from a stable
/// hash of the session id, so a fish keeps its swim across reduces —
/// only the state word changes under it.
public struct Fish: Equatable, Sendable, Identifiable {
    /// The session id.
    public var id: String
    /// What the panel calls the session (`CoreSession.displayLabel`).
    public var label: String
    /// The provider id; the tank colours the fish with `ProviderStyle`.
    public var providerID: String
    /// What kind of fish it is, from `FishSpecies.forProvider` at
    /// reduce time; a fry anchored to a school wears its parent's.
    public var species: FishSpecies
    /// A sub-agent's fish: half-sized, schooling around `anchorID`,
    /// with no label or status bubbles of its own.
    public var isFry: Bool
    /// A raised fish whose session is gone — it idles, keeps its name,
    /// and lives on feeding alone. Never a plan, never a status bubble.
    public var isResident: Bool = false
    /// The fish this fry schools around — the parent session's fish
    /// when it's in the tank, else the largest same-provider fish,
    /// else nil and the fry free-swims on its own lane.
    public var anchorID: String?
    public var state: FishState
    /// Depth in the tank: 0 rides at the surface, 1 sits on the bottom.
    public var lane: Double
    /// Swim speed, as a fraction of the tank's width per second.
    public var speed: Double
    /// +1 heads right, -1 heads left.
    public var direction: Double
    /// When the fish entered `state`; the view integrates the bob, the
    /// sink and the drift off the edge from it.
    public var stateSince: Date
    /// When the fish joined the tank; the view swims it in from an edge
    /// over its first couple of seconds instead of popping it in.
    public var enteredAt: Date
    /// The session's `updated_at`; a recently active session's tail
    /// beats faster. Kept from the last reduce that carried one.
    public var lastUpdate: Date?
    /// `stableHash(id)`, taken once when the fish is created — the
    /// view's patrol phase, fry orbit and tail-beat all key off it, so
    /// like the swim it rides through `previous` untouched instead of
    /// being re-hashed per fish per frame.
    public var seed: UInt64
    /// W13's semantic plan — the AQ action + overlay the session's wire
    /// facts drove. Recomputed every reduce (it reads `now` and the
    /// session), so it rides `previous` as the freshest word.
    public var plan: FishPlan?

    public init(id: String, label: String, providerID: String, state: FishState,
                lane: Double, speed: Double, direction: Double, stateSince: Date,
                enteredAt: Date = .distantPast, lastUpdate: Date? = nil,
                species: FishSpecies = .minnow, isFry: Bool = false, anchorID: String? = nil,
                seed: UInt64? = nil, plan: FishPlan? = nil) {
        self.id = id
        self.label = label
        self.providerID = providerID
        self.species = species
        self.isFry = isFry
        self.anchorID = anchorID
        self.state = state
        self.lane = lane
        self.speed = speed
        self.direction = direction
        self.stateSince = stateSince
        self.enteredAt = enteredAt
        self.lastUpdate = lastUpdate
        self.seed = seed ?? AquariumModel.stableHash(id)
        self.plan = plan
    }

    /// Drawn-size proxy: species scale times the lane's depth scale.
    /// The loose-school anchor pick uses it, so "the largest
    /// same-provider fish" is the one that actually looks largest.
    var bodySize: Double {
        species.sizeScale * (1.08 - lane * 0.4)
    }

    /// How far through the drift off the right edge the fish is, 0...1.
    public func leaveProgress(at now: Date) -> Double {
        guard state == .leaving else { return 0 }
        return min(1, max(0, now.timeIntervalSince(stateSince) / AquariumModel.leaveDuration))
    }

    /// A leaving fish is retired once it has had `leaveDuration` to
    /// clear the edge; the view stops drawing it. It stays in the list
    /// while its session does — dropping it would only spawn a fresh
    /// leaver on the next pass, since a finished session is still
    /// listed until the user clears it.
    public func isRetired(at now: Date) -> Bool {
        state == .leaving && now.timeIntervalSince(stateSince) >= AquariumModel.leaveDuration
    }
}

/// One piece of tank dressing (docs/TOYS.md), seeded through
/// `AquariumModel.decorSet` so the layout is the same on every
/// launch. All unit space: `x` across the tank, `depth` toward the
/// glass (0 deep, 1 near — near pieces draw over the fish), `scale` a
/// size multiplier, `bits` spare hash bits for sway phases & shapes.
public struct TankDecor: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case chest
        case starfish
        case coral
        case kelp
        case rock
        /// A tuft of thin sea-grass blades.
        case grass
        /// A small scallop or spiral shell on the sand.
        case shell
        /// A bottle sunk to its shoulder.
        case bottle
    }

    public var id: Int
    public var kind: Kind
    /// 0...1 across the tank.
    public var x: Double
    /// 0 at the back, 1 against the glass. Deep pieces draw dimmer;
    /// pieces past ~0.6 draw in front of the fish.
    public var depth: Double
    /// Piece-specific size multiplier, ~0.7...1.4.
    public var scale: Double
    /// Hash bits for the view: sway phase, heights, which leaf.
    public var bits: UInt64

    public init(id: Int, kind: Kind, x: Double, depth: Double, scale: Double, bits: UInt64) {
        self.id = id
        self.kind = kind
        self.x = x
        self.depth = depth
        self.scale = scale
        self.bits = bits
    }
}

/// The session list as fish (docs/TOYS.md). Pure, so the reducer can be
/// tested without a window: `reduce` maps sessions to fish through
/// `SessionActivity`, keeps each fish's swim across calls by id, and
/// assigns new fish a deterministic swim from a stable hash of the
/// session id — `Hasher` is seeded per run, so anything that must look
/// the same across launches goes through `stableHash`.
public enum AquariumModel {
    /// Seconds a finished fish gets to drift off the right edge.
    public static let leaveDuration: TimeInterval = 6
    /// Fry length as a fraction of their parent's.
    public static let fryScale = 0.45
    /// The most fry one school draws; extra workers merge visually.
    public static let maxFryPerSchool = 8

    /// The session set as fish, in the session list's order. A session
    /// that leaves the list takes its fish with it. Main sessions swim
    /// as full fish; workers with a named parent become fry schooling
    /// around their parent's fish — or, when the parent isn't listed,
    /// around the largest same-provider fish, or free-swimming when
    /// there isn't one. A parent that sinks or drifts off takes its
    /// school with it.
    public static func reduce(sessions: [CoreSession], previous: [Fish], now: Date,
                              residents: [AquariumResident] = [],
                              species: (String) -> FishSpecies = FishSpecies.forProvider) -> [Fish] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Mains first, so a fry can anchor to its parent's fish even
        // when the worker precedes it in the session list. "Main" is
        // the panel's own rule (`mainSessions`): `isSubagent` would
        // wrongly fry a `kind == "main"` session that merely names a
        // parent, or a worker with no parent to school under.
        var mainByID: [String: Fish] = [:]
        var mainsInOrder: [Fish] = []
        for session in sessions where isMain(session) {
            let fish = fishFor(session: session, previous: previousByID[session.id], now: now, species: species)
            mainByID[session.id] = fish
            mainsInOrder.append(fish)
        }

        var fryPerAnchor: [String: Int] = [:]
        var result: [Fish] = []
        result.reserveCapacity(sessions.count)
        for session in sessions {
            guard !isMain(session) else {
                result.append(mainByID[session.id] ?? fishFor(session: session, previous: previousByID[session.id], now: now, species: species))
                continue
            }
            // The anchor: the parent session's fish when it's here,
            // else the largest same-provider fish, else nobody and the
            // fry free-swims.
            var anchor: Fish?
            if let parentID = session.parent {
                anchor = mainByID[parentID]
            }
            if anchor == nil {
                anchor = mainsInOrder
                    .filter { $0.providerID == session.provider }
                    .max(by: { $0.bodySize < $1.bodySize })
            }
            let key = anchor?.id ?? "\u{0}free"
            let count = fryPerAnchor[key, default: 0]
            guard count < maxFryPerSchool else { continue }
            fryPerAnchor[key] = count + 1

            var fish = fishFor(session: session, previous: previousByID[session.id], now: now, species: species)
            fish.isFry = true
            fish.anchorID = anchor?.id
            // A school looks like its parent: same species. The colour
            // stays the worker's own provider (usually the same one).
            if let anchor { fish.species = anchor.species }
            // The school's fate is the parent's: a parent that sinks
            // or drifts off takes its fry with it, on the same clock.
            if let anchor, anchor.state == .sinking || anchor.state == .leaving,
               fish.state != anchor.state {
                fish.state = anchor.state
                fish.stateSince = anchor.stateSince
            }
            result.append(fish)
        }
        // The residents: raised fish whose sessions left. A resident
        // whose session is listed again is simply that session's fish
        // (same id, same swim) — never a twin.
        let listed = Set(sessions.map(\.id))
        for resident in residents where !listed.contains(resident.id) {
            result.append(residentFish(resident, previous: previousByID[resident.id],
                                       now: now, species: species))
        }
        return result
    }

    /// A resident → fish: idling midwater on the swim its session's
    /// fish had (or a fresh deterministic one), under its remembered
    /// name, in its provider's species and colour. No plan — nothing
    /// is running — so the inspector cites nothing for it.
    static func residentFish(_ resident: AquariumResident, previous: Fish?, now: Date,
                             species resolve: (String) -> FishSpecies) -> Fish {
        if var fish = previous {
            fish.label = resident.label
            fish.providerID = resident.provider
            fish.species = resolve(resident.provider)
            fish.isFry = false
            fish.anchorID = nil
            fish.isResident = true
            fish.plan = nil
            if fish.state != .idling {
                fish.state = .idling
                fish.stateSince = now
            }
            return fish
        }
        var fish = Fish(
            id: resident.id,
            label: resident.label,
            providerID: resident.provider,
            state: .idling,
            lane: lane(for: resident.id),
            speed: speed(for: resident.id),
            direction: direction(for: resident.id),
            stateSince: now,
            enteredAt: now,
            species: resolve(resident.provider),
            seed: stableHash(resident.id))
        fish.isResident = true
        return fish
    }

    /// A full-sized fish, matching the panel's `mainSessions` rule:
    /// `kind == "main"`, or a worker with no parent to swim under.
    static func isMain(_ session: CoreSession) -> Bool {
        session.kind == "main" || session.parent == nil
    }

    /// One session → fish, preserving the swim of the `previous` fish
    /// with the same id when there is one. The plan is recomputed on
    /// every pass — `state` comes from it (the AQ23 stale degradation
    /// lives there), so a fish's displayed state and its cited evidence
    /// are the same decision.
    static func fishFor(session: CoreSession, previous: Fish?, now: Date,
                        species resolve: (String) -> FishSpecies = FishSpecies.forProvider) -> Fish {
        let plan = AquariumPlanner.plan(for: session, axes: session.axes, now: now)
        let target = plan.state
        if var fish = previous {
            // The swim belongs to the fish; only what the session
            // says about it now is rewritten.
            fish.label = session.displayLabel
            fish.providerID = session.provider
            fish.species = resolve(session.provider)
            fish.isFry = false
            fish.anchorID = nil
            // A resident whose session came back is the session's again.
            fish.isResident = false
            fish.plan = plan
            if let updated = session.updatedAt {
                fish.lastUpdate = Date(timeIntervalSince1970: updated)
            }
            if fish.state != target {
                fish.state = target
                fish.stateSince = now
            }
            return fish
        }
        return Fish(
            id: session.id,
            label: session.displayLabel,
            providerID: session.provider,
            state: target,
            lane: lane(for: session.id),
            speed: speed(for: session.id),
            direction: direction(for: session.id),
            stateSince: now,
            enteredAt: now,
            lastUpdate: session.updatedAt.map { Date(timeIntervalSince1970: $0) },
            species: resolve(session.provider),
            seed: stableHash(session.id),
            plan: plan)
    }

    /// The tank's reading of a session, in `SessionActivity`'s words.
    /// `ended` sinks with `failed`: the run is over without a
    /// completion, which is not a drift off the edge.
    static func state(for session: CoreSession) -> FishState {
        switch SessionActivity.reduce(session) {
        case .working: return .swimming
        case .idle: return .idling
        case .waiting: return .surfacing
        case .failed, .ended: return .sinking
        case .done: return .leaving
        }
    }

    /// FNV-1a over the string's UTF-8. Stable across runs and processes.
    public static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }

    /// The tank's dressing: kelp, rocks, corals, a starfish and a
    /// treasure chest, all seeded so the layout never rearranges
    /// between launches. The signature pieces come first, so a sparse
    /// `density` (the view draws a prefix) keeps them.
    public static func decorSet(seed: String = "tank") -> [TankDecor] {
        // FNV-1a's low bits barely change between tags that differ only
        // in the last byte ("kelp-0"…"kelp-4"), which parked every
        // strand on the same spot — run each tag's hash through a
        // murmur-style finalizer so the pieces spread across the tank.
        func bits(_ tag: String) -> UInt64 {
            var h = stableHash("\(seed).\(tag)")
            h ^= h >> 33
            h &*= 0xff51afd7ed558ccd
            h ^= h >> 33
            return h
        }
        func unit(_ b: UInt64, _ shift: UInt64) -> Double {
            Double((b >> shift) & 0xFFFF) / 0xFFFF
        }
        var out: [TankDecor] = []
        func piece(_ kind: TankDecor.Kind, _ tag: String,
                   x: Double, depth: Double, scale: Double) -> TankDecor {
            TankDecor(id: out.count, kind: kind, x: x, depth: depth,
                      scale: scale, bits: bits(tag))
        }

        let chest = bits("chest")
        // The chest starts past the empty-tank caption's capsule,
        // which sits in the left ~30% of the bed.
        out.append(piece(.chest, "chest",
                         x: 0.34 + unit(chest, 0) * 0.58,
                         depth: 0.42,
                         scale: 0.85 + unit(chest, 16) * 0.4))
        let star = bits("starfish")
        out.append(piece(.starfish, "starfish",
                         x: 0.06 + unit(star, 0) * 0.88,
                         depth: 0.50,
                         scale: 0.70 + unit(star, 16) * 0.5))

        let counts = bits("counts")
        let corals = 1 + Int(counts & 1)
        for i in 0..<corals {
            let b = bits("coral-\(i)")
            out.append(piece(.coral, "coral-\(i)",
                             x: 0.05 + unit(b, 0) * 0.90,
                             depth: 0.38 + unit(b, 16) * 0.16,
                             scale: 0.80 + unit(b, 32) * 0.5))
        }
        let kelpCount = 2 + Int((counts >> 4) % 3)
        for i in 0..<kelpCount {
            let b = bits("kelp-\(i)")
            out.append(piece(.kelp, "kelp-\(i)",
                             x: 0.04 + unit(b, 0) * 0.92,
                             depth: 0.25 + unit(b, 16) * 0.70,
                             scale: 0.70 + unit(b, 32) * 0.6))
        }
        let rocks = 2 + Int((counts >> 8) & 1)
        for i in 0..<rocks {
            let b = bits("rock-\(i)")
            out.append(piece(.rock, "rock-\(i)",
                             x: 0.05 + unit(b, 0) * 0.90,
                             depth: 0.44 + unit(b, 16) * 0.12,
                             scale: 0.75 + unit(b, 32) * 0.5))
        }
        let grass = 2 + Int((counts >> 12) & 1)
        for i in 0..<grass {
            let b = bits("grass-\(i)")
            out.append(piece(.grass, "grass-\(i)",
                             x: 0.04 + unit(b, 0) * 0.92,
                             depth: 0.42 + unit(b, 16) * 0.45,
                             scale: 0.70 + unit(b, 32) * 0.6))
        }
        let shells = 2 + Int((counts >> 14) & 1)
        for i in 0..<shells {
            let b = bits("shell-\(i)")
            out.append(piece(.shell, "shell-\(i)",
                             x: 0.05 + unit(b, 0) * 0.90,
                             depth: 0.50 + unit(b, 16) * 0.25,
                             scale: 0.60 + unit(b, 32) * 0.5))
        }
        if (counts >> 20) & 1 == 1 {
            let b = bits("bottle")
            out.append(piece(.bottle, "bottle",
                             x: 0.08 + unit(b, 0) * 0.84,
                             depth: 0.38 + unit(b, 16) * 0.18,
                             scale: 0.80 + unit(b, 32) * 0.4))
        }
        // Two tall near-glass plants so the tank always has a
        // foreground; they draw over the fish as dark silhouettes.
        for i in 0..<2 {
            let b = bits("kelp-front-\(i)")
            out.append(piece(.kelp, "kelp-front-\(i)",
                             x: 0.08 + unit(b, 0) * 0.84,
                             depth: 0.78 + unit(b, 16) * 0.18,
                             scale: 1.15 + unit(b, 32) * 0.35))
        }
        return out
    }

    /// A finished fish drops a meal: two or three pellet seeds, scrambled
    /// off the fish's own seed so the same completion always scatters
    /// the same food and a replayed frame draws it identically.
    public static func pelletSeeds(for fish: Fish) -> [UInt64] {
        let count = 2 + Int((fish.seed >> 11) & 1)
        return (0..<count).map { i in
            var h = fish.seed &+ UInt64(i &+ 61) &* 0x9E3779B97F4A7C15
            h ^= h >> 29
            h &*= 0xBF58476D1CE4E5B9
            h ^= h >> 32
            return h
        }
    }

    /// A burst of finishes close together pops the chest: this many
    /// fish leaving inside the window earns a bubble plume.
    public static let milestoneCount = 3
    public static let milestoneWindow: TimeInterval = 5

    /// Whether the leavers in `fish` count as a milestone right now —
    /// pure, so the view replays the same burst every frame. Fry don't
    /// count: the plume celebrates mains finishing, matching the view's
    /// burst filter.
    public static func isMilestone(fish: [Fish], at now: Date) -> Bool {
        fish.filter {
            $0.state == .leaving && !$0.isFry
                && now.timeIntervalSince($0.stateSince) < milestoneWindow
        }.count >= milestoneCount
    }

    /// Depths keep clear of the surface and the floor so a surfacing or
    /// sinking fish has room to move.
    static func lane(for id: String) -> Double {
        0.18 + 0.72 * Double(stableHash(id) & 0xFFFF) / 0xFFFF
    }

    static func speed(for id: String) -> Double {
        0.05 + 0.09 * Double((stableHash(id) >> 16) & 0xFFFF) / 0xFFFF
    }

    static func direction(for id: String) -> Double {
        (stableHash(id) >> 32) & 1 == 0 ? 1 : -1
    }
}
