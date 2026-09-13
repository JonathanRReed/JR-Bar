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
                enteredAt: Date = .distantPast, lastUpdate: Date? = nil) {
        self.id = id
        self.label = label
        self.providerID = providerID
        self.state = state
        self.lane = lane
        self.speed = speed
        self.direction = direction
        self.stateSince = stateSince
        self.enteredAt = enteredAt
        self.lastUpdate = lastUpdate
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

/// The session list as fish (docs/TOYS.md). Pure, so the reducer can be
/// tested without a window: `reduce` maps sessions to fish through
/// `SessionActivity`, keeps each fish's swim across calls by id, and
/// assigns new fish a deterministic swim from a stable hash of the
/// session id — `Hasher` is seeded per run, so anything that must look
/// the same across launches goes through `stableHash`.
public enum AquariumModel {
    /// Seconds a finished fish gets to drift off the right edge.
    public static let leaveDuration: TimeInterval = 6

    /// The session set as fish, in the session list's order. A session
    /// that leaves the list takes its fish with it.
    public static func reduce(sessions: [CoreSession], previous: [Fish], now: Date) -> [Fish] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.map { session in
            let target = state(for: session)
            if var fish = previousByID[session.id] {
                // The swim belongs to the fish; only what the session
                // says about it now is rewritten.
                fish.label = session.displayLabel
                fish.providerID = session.provider
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
                lastUpdate: session.updatedAt.map { Date(timeIntervalSince1970: $0) })
        }
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
