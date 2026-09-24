import Foundation

/// The one keep-awake hold as every surface draws it — the notch card's
/// Awake chip and its tooltip, the panel footer's line — read from the
/// daemon's `state.power.hold` (docs/CORE-PROTOCOL.md). Three states, in
/// the daemon's own words: off; the agents holding the Mac (their own
/// switch, not the person's); or the person's lease — a countdown, until
/// the agents finish, or until turned off. A yield to heat or the battery
/// floor is said too: the demand stands, the hold does not. So are the
/// power facts around it — when the agents' grace lets go, a battery that
/// will not outlast the run, a charger that cannot carry it, and the last
/// time a hold let go and why. Pure, so the words are pinned without a
/// daemon.
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
    /// When the agents' post-work grace ends (`hold.grace_until`).
    public var graceUntil: Date?
    /// Will the run outlast the battery (`battery.runway`).
    public var runway: CoreBatteryRunway?
    /// The newest release worth reading (`power.last_release`).
    public var lastRelease: CorePowerRelease?
    /// The closed-lid hold is up (`power.closed_lid.holding`): something
    /// holds the Mac even while the hold itself is off.
    public var lidHolding = false
    /// Clock times follow the Mac's locale and zone; tests pin both.
    public var locale: Locale = .current
    public var timeZone: TimeZone = .current

    /// A release this recent is still news on the footer line when
    /// nothing holds the Mac; older, it stays in the tooltip.
    public static let releaseNewsFor: TimeInterval = 30 * 60

    public init(state: State, suspended: String? = nil, display: Bool = false, graceUntil: Date? = nil,
                runway: CoreBatteryRunway? = nil, lastRelease: CorePowerRelease? = nil) {
        self.state = state
        self.suspended = suspended
        self.display = display
        self.graceUntil = graceUntil
        self.runway = runway
        self.lastRelease = lastRelease
    }

    /// The whole of `state.power`: the hold and the facts around it.
    public init(power: CorePower?) {
        self.init(hold: power?.hold)
        runway = power?.battery?.runway
        lastRelease = power?.lastRelease
        lidHolding = power?.closedLid?.holding == true
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
                  display: hold.display == true,
                  graceUntil: hold.graceUntil.map { Date(timeIntervalSince1970: $0) })
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

    /// The chip's tooltip: the truth, and what a click does to it, then
    /// the power facts one per line.
    public func chipHelp(now: Date) -> String {
        ([holdHelp(now: now)] + facts()).joined(separator: "\n")
    }

    private func holdHelp(now: Date) -> String {
        var text: String
        switch state {
        case .off:
            return display
                ? "Keep the Mac and its display awake — the screen will not lock while held."
                : "Keep the Mac awake (the display may still sleep and lock)."
        case .agents(let count):
            if count > 0 {
                text = "Held awake while \(Self.agents(count)) work — their own switch, under Settings › Notifications › Power. It lets go a few minutes after they stop. Click to keep it awake after that too."
            } else if let end = graceEnd(now: now) {
                text = "Held awake until \(clock(end)), a few minutes after the agents stopped. Click to keep it awake."
            } else {
                text = "Held awake for a few minutes after the agents stopped. Click to keep it awake."
            }
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
        // A run the battery or the charger will not carry outranks the
        // hold's own words: it is the one thing to act on. Only while
        // something holds the Mac, though — the daemon's charger verdict
        // does not ask whether a hold is up, and "Awake" would be false.
        if state != .off || lidHolding {
            if runway?.short == true {
                if let minutes = runway?.minutesLeft { return ("Awake · battery ~\(minutes) min left", "~\(minutes) min") }
                return ("Awake · battery running short", "Battery low")
            }
            if runway?.adapterShort == true { return ("Awake · the charger can't keep up", "Charger short") }
        }
        switch state {
        case .off:
            return releaseNews(now: now)
        case .agents(let count):
            if count > 0 { return ("Awake · \(Self.agents(count)) working", count == 1 ? "1 agent" : "\(count) agents") }
            if let end = graceEnd(now: now) { return ("Awake · lets go at \(clock(end))", clock(end)) }
            return ("Awake · a few minutes more", "Awake")
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

    // MARK: The facts

    /// The power facts past the hold's own words, one line each, for the
    /// tooltips: the battery runway, the charger shortfall and the last
    /// release. (The grace's end is the hold's own sentence.) Empty when
    /// there is nothing more to say.
    public func facts() -> [String] {
        var lines: [String] = []
        if let runway, runway.short == true {
            let who = runway.agents.map { " with \(Self.agents($0)) working" } ?? ""
            lines.append(runway.minutesLeft.map { "On battery\(who): about \($0) min left" }
                ?? "On battery\(who), and the battery is running short")
        }
        if let runway, runway.adapterShort == true {
            var line = "The charger can't keep up — the battery still falls under the agents' load"
            if let watts = runway.fullSpeedWatts, watts > 0 { line += "; this Mac charges at full speed on \(Int(watts.rounded())) W" }
            lines.append(line)
        }
        if let release = releaseLine() { lines.append(release) }
        return lines
    }

    /// The grace's end, while it is ahead.
    func graceEnd(now: Date) -> Date? {
        guard let graceUntil, graceUntil > now else { return nil }
        return graceUntil
    }

    /// "Last let go at 02:14 — time up"; a closed-lid stretch as one
    /// story: "Ran 2 h 40 min with the lid closed, 3 finished, slept at
    /// 02:14".
    func releaseLine() -> String? {
        guard let release = lastRelease, let at = release.at else { return nil }
        let when = clock(Date(timeIntervalSince1970: at))
        switch release.kind {
        case "lid_hold_ended", "slept":
            var parts: [String] = []
            if let duration = release.duration, duration > 0 { parts.append("Ran \(Self.long(duration)) with the lid closed") }
            if let finished = release.finished, finished > 0 { parts.append("\(finished) finished") }
            let slept = release.kind == "slept"
            let end = slept ? "slept at \(release.sleptAt.map { clock(Date(timeIntervalSince1970: $0)) } ?? when)" : "let go at \(when)"
            parts.append(parts.isEmpty ? (slept ? "Slept at \(when)" : "Let go at \(when)") : end)
            return parts.joined(separator: ", ")
        default:
            guard let why = Self.releaseWords(release.reason) else { return "Last let go at \(when)" }
            return "Last let go at \(when) — \(why)"
        }
    }

    /// A recent release while nothing holds the Mac: "Let go at 02:14 ·
    /// time up", the short form the clock alone.
    func releaseNews(now: Date) -> (full: String, short: String)? {
        guard let release = lastRelease, let at = release.at else { return nil }
        let age = now.timeIntervalSince1970 - at
        guard age >= 0, age <= Self.releaseNewsFor else { return nil }
        let when = clock(Date(timeIntervalSince1970: at))
        if release.kind == "slept" { return ("Slept at \(when)", when) }
        let why = Self.releaseWords(release.reason).map { " · \($0)" } ?? ""
        return ("Let go at \(when)\(why)", when)
    }

    /// The daemon's release reasons in the reader's words.
    static func releaseWords(_ reason: String?) -> String? {
        switch reason {
        case nil, "": return nil
        case "expired": return "time up"
        case "finished", "agents_idle": return "the agents finished"
        case "thermal": return "too warm"
        case "battery": return "battery low"
        case "policy": return "the setting changed"
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "14:32" or "2:32 PM", as the Mac tells time.
    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
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
