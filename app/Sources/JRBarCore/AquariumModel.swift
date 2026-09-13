import Foundation

/// What a session's fish is doing in the tank (docs/TOYS.md): working
/// swims, waiting on you comes up for air, failed goes grey and sinks,
/// a finished run drifts off the right edge. Reduced from
/// `SessionActivity`, so the tank can never disagree with the panel
/// about what a session is.
public enum FishState: String, Equatable, Sendable, CaseIterable {
    case swimming
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

    public init(id: String, label: String, providerID: String, state: FishState,
                lane: Double, speed: Double, direction: Double, stateSince: Date,
                enteredAt: Date = .distantPast, lastUpdate: Date? = nil,
                species: FishSpecies = .minnow, isFry: Bool = false, anchorID: String? = nil) {
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
    /// as full fish; sub-agents (`session.isSubagent`) become fry
    /// schooling around their parent's fish — or, when the parent
    /// isn't listed, around the largest same-provider fish, or
    /// free-swimming when there isn't one. A parent that sinks or
    /// drifts off takes its school with it.
    public static func reduce(sessions: [CoreSession], previous: [Fish], now: Date) -> [Fish] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Mains first, so a fry can anchor to its parent's fish even
        // when the worker precedes it in the session list.
        var mainByID: [String: Fish] = [:]
        var mainsInOrder: [Fish] = []
        for session in sessions where !session.isSubagent {
            let fish = fishFor(session: session, previous: previousByID[session.id], now: now)
            mainByID[session.id] = fish
            mainsInOrder.append(fish)
        }

        var fryPerAnchor: [String: Int] = [:]
        var result: [Fish] = []
        result.reserveCapacity(sessions.count)
        for session in sessions {
            guard session.isSubagent else {
                result.append(mainByID[session.id] ?? fishFor(session: session, previous: previousByID[session.id], now: now))
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

            var fish = fishFor(session: session, previous: previousByID[session.id], now: now)
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
        return result
    }

    /// One session → fish, preserving the swim of the `previous` fish
    /// with the same id when there is one.
    static func fishFor(session: CoreSession, previous: Fish?, now: Date) -> Fish {
        let target = state(for: session)
        if var fish = previous {
            // The swim belongs to the fish; only what the session
            // says about it now is rewritten.
            fish.label = session.displayLabel
            fish.providerID = session.provider
            fish.species = FishSpecies.forProvider(session.provider)
            fish.isFry = false
            fish.anchorID = nil
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
            species: FishSpecies.forProvider(session.provider))
    }

    /// The tank's reading of a session, in `SessionActivity`'s words.
    /// `ended` sinks with `failed`: the run is over without a
    /// completion, which is not a drift off the edge.
    static func state(for session: CoreSession) -> FishState {
        switch SessionActivity.reduce(session) {
        case .working, .idle: return .swimming
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
        func bits(_ tag: String) -> UInt64 { stableHash("\(seed).\(tag)") }
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
        out.append(piece(.chest, "chest",
                         x: 0.10 + unit(chest, 0) * 0.80,
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
        let kelpCount = 3 + Int((counts >> 4) % 4)
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
        return out
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
