import Foundation

/// The one keep-awake hold as every surface draws it — the notch card's
/// Awake chip and its tooltip, the panel footer's line — read from the
/// daemon's `state.power.hold` (docs/CORE-PROTOCOL.md). Three states, in
/// the daemon's own words: off; the agents holding the Mac (their own
/// switch, not the person's); or the person's lease — a countdown, until
/// the agents finish, or until turned off. A yield to heat or the battery
/// floor is said too: the demand stands, the hold does not. Pure, so the
/// words are pinned without a daemon.
public struct KeepAwakeReading: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// The agents' own hold: `count` main sessions working, 0 in the
        /// few minutes of grace after they stop.
        case agents(count: Int)
        /// The person's lease.
        case lease(Lease)
    }

    public enum Lease: Equatable, Sendable {
        /// A countdown to this moment.
        case until(Date)
        /// Until the agents it waits on stop working.
        case agentsFinish
        /// Until the person lets go.
        case indefinite
    }

    public var state: State
    /// `thermal` or `battery` while a yield has taken the hold away.
    public var suspended: String?
    /// The screen is held too — no screen saver, no lock.
    public var display: Bool

    public init(state: State, suspended: String? = nil, display: Bool = false) {
        self.state = state
        self.suspended = suspended
        self.display = display
    }

    /// The daemon's hold; off when it sent none.
    public init(hold: CoreAwakeHold?) {
        guard let hold else {
            self.init(state: .off)
            return
        }
        let state: State
        switch hold.state {
        case "manual":
            switch hold.lease?.kind {
            case "duration":
                state = .lease(hold.lease?.until.map { .until(Date(timeIntervalSince1970: $0)) } ?? .indefinite)
            case "agents":
                state = .lease(.agentsFinish)
            default:
                state = .lease(.indefinite)
            }
        case "agents":
            state = .agents(count: max(0, hold.agents ?? 0))
        default:
            state = .off
        }
        let suspended = hold.suspended?.trimmingCharacters(in: .whitespaces)
        self.init(state: state, suspended: suspended?.isEmpty == false ? suspended : nil,
                  display: hold.display == true)
    }

    /// The app's own assertion, the fallback while the daemon is away: a
    /// countdown or until turned off.
    public init(localHeld: Bool, until: Date?, display: Bool) {
        guard localHeld else {
            self.init(state: .off, display: display)
            return
        }
        self.init(state: .lease(until.map(Lease.until) ?? .indefinite), display: display)
    }

    /// The person's lease is in force: the chip's light, and what a tap
    /// on it ends. The agents' hold is theirs, said in the chip's word.
    public var leaseInForce: Bool {
        if case .lease = state { return true }
        return false
    }

    /// The Mac is held awake right now — by the agents or the lease, and
    /// not stood aside for heat or the battery floor.
    public var holding: Bool { state != .off && suspended == nil }

    /// A countdown is on show, so the chip's word needs a clock.
    public var showsCountdown: Bool {
        if case .lease(.until) = state { return suspended == nil }
        return false
    }

    // MARK: The chip

    /// The chip's word under the cup — short enough for a chip.
    public func chipTitle(now: Date) -> String {
        if suspended != nil { return "Paused" }
        switch state {
        case .off, .lease(.indefinite):
            return "Awake"
        case .agents(let count):
            return count > 1 ? "\(count) agents" : count == 1 ? "1 agent" : "Agents"
        case .lease(.agentsFinish):
            return "Agents"
        case .lease(.until(let end)):
            let left = end.timeIntervalSince(now)
            return left > 0 ? Self.compact(left) : "Awake"
        }
    }

    /// The chip's tooltip: the truth, and what a click does to it.
    public func chipHelp(now: Date) -> String {
        var text: String
        switch state {
        case .off:
            return display
                ? "Keep the Mac and its display awake — the screen will not lock while held."
                : "Keep the Mac awake (the display may still sleep and lock)."
        case .agents(let count):
            text = count > 0
                ? "Held awake while \(Self.agents(count)) work — their own switch, under Settings › Notifications › Power. It lets go a few minutes after they stop. Click to keep it awake after that too."
                : "Held awake for a few minutes after the agents stopped. Click to keep it awake."
        case .lease(.until(let end)):
            let left = end.timeIntervalSince(now)
            text = left > 0
                ? "Keeping the Mac awake for \(Self.long(left)) more — click to allow sleep."
                : "Keeping the Mac awake — click to allow sleep."
        case .lease(.agentsFinish):
            text = "Keeping the Mac awake until the agents finish — click to allow sleep."
        case .lease(.indefinite):
            text = "Keeping the Mac awake until you turn it off — click to allow sleep."
        }
        if let why = suspendedWords {
            text = "Paused: \(why). The hold comes back on its own. " + text
        } else if display {
            text += " The display stays on too."
        }
        return text
    }

    // MARK: The footer

    /// The panel footer's quiet line, and the shorter one for a crowded
    /// footer; nil while nothing holds the Mac or waits to.
    public func footerLine(now: Date) -> (full: String, short: String)? {
        if let why = suspendedWords { return ("Awake paused · \(why)", "Paused") }
        switch state {
        case .off:
            return nil
        case .agents(let count):
            return count > 0
                ? ("Awake · \(Self.agents(count)) working", count == 1 ? "1 agent" : "\(count) agents")
                : ("Awake · a few minutes more", "Awake")
        case .lease(.until(let end)):
            let left = end.timeIntervalSince(now)
            guard left > 0 else { return ("Awake", "Awake") }
            return ("Awake · \(Self.long(left)) left", Self.compact(left))
        case .lease(.agentsFinish):
            return ("Awake until the agents finish", "Awake")
        case .lease(.indefinite):
            return ("Awake until you turn it off", "Awake")
        }
    }

    // MARK: Words

    /// Why the hold stepped aside, in the reader's words.
    var suspendedWords: String? {
        switch suspended {
        case nil: return nil
        case "thermal": return "too warm"
        case "battery": return "battery low"
        case let other?: return other
        }
    }

    static func agents(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    /// Whole minutes, rounded up: a countdown never reads 0 while it runs.
    static func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    /// "42m", "2h", "1h 5m" — a chip's worth.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = minutes(seconds)
        guard total >= 60 else { return "\(total)m" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "42 min", "2 h", "1 h 5 min" — the panel's own spelling.
    static func long(_ seconds: TimeInterval) -> String {
        let total = minutes(seconds)
        guard total >= 60 else { return "\(total) min" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
