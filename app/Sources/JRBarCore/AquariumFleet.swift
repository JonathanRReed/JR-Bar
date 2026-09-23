import Foundation

/// What the daemon's document says about the fleet that a tank milestone
/// can be earned from (docs/TOYS.md): the widest school of sub-agents,
/// the runs that failed, each weekly window's reading and Codex's banked
/// credits. Read-only facts — "toys never touch usage" holds; the tank
/// only notices.
public struct AquariumFleetFacts: Equatable, Sendable {
    /// The most live sub-agents swimming with one session right now.
    public var largestSchool: Int
    /// Listed sessions that read failed, by id — one failure counts once
    /// however long it lingers in the list.
    public var failedIDs: [String]
    /// Each usage row's weekly window, keyed `identity|window`.
    public var weekly: [String: AquariumWeeklyReading]
    /// Codex's banked credits per usage row (`identity`).
    public var codexCredits: [String: Double]

    public init(largestSchool: Int = 0, failedIDs: [String] = [],
                weekly: [String: AquariumWeeklyReading] = [:],
                codexCredits: [String: Double] = [:]) {
        self.largestSchool = largestSchool
        self.failedIDs = failedIDs
        self.weekly = weekly
        self.codexCredits = codexCredits
    }

    /// The facts in one applied document, stamped `now` — the moment the
    /// tank saw each weekly reading.
    public static func read(_ state: CoreState, now: Date) -> AquariumFleetFacts {
        var schools: [String: Int] = [:]
        var failed: [String] = []
        for session in state.sessions {
            let activity = SessionActivity.reduce(session)
            if activity == .failed { failed.append(session.id) }
            guard let parent = session.parent, session.kind != "main" else { continue }
            if activity == .working || activity == .waiting || activity == .idle {
                schools[parent, default: 0] += 1
            }
        }
        var weekly: [String: AquariumWeeklyReading] = [:]
        var credits: [String: Double] = [:]
        let seen = now.timeIntervalSince1970
        for provider in state.usage?.providers ?? [] {
            for window in provider.windows where window.shortName == "7d" {
                guard let used = window.usedPct, let resets = window.resetsAt,
                      used.isFinite, resets.isFinite else { continue }
                weekly["\(provider.identity)|\(window.id)"] =
                    AquariumWeeklyReading(usedPct: used, resetsAt: resets, observedAt: seen)
            }
            if provider.id == "codex", let balance = provider.creditsRemaining, balance.isFinite {
                credits[provider.identity] = balance
            }
        }
        return AquariumFleetFacts(largestSchool: schools.values.max() ?? 0,
                                  failedIDs: failed.sorted(), weekly: weekly,
                                  codexCredits: credits)
    }
}

/// One weekly window as the tank last saw it.
public struct AquariumWeeklyReading: Codable, Equatable, Sendable {
    public var usedPct: Double
    public var resetsAt: Double
    /// When the tank read it — a reset only counts as "under budget" if
    /// the tank watched the window's last hours.
    public var observedAt: Double

    public init(usedPct: Double, resetsAt: Double, observedAt: Double) {
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

/// The tank's memory of the fleet between documents — the save's `fleet`
/// field. Every counter here only ever feeds an achievement; nothing in
/// it pays by itself.
public struct AquariumFleetLog: Codable, Equatable, Sendable {
    /// When the tank first read a fleet document; 0 until then. Clean
    /// days only count while the tank is watching for failures.
    public var watchedSince: Double
    /// The widest school the tank has seen.
    public var largestSchool: Int
    /// The newest failed session ids already counted (bounded).
    public var failedIDs: [String]
    /// Calendar days with a completion since the last failure seen.
    public var cleanDays: Int
    /// `startOfDay` epoch of the last clean day counted; 0 for none.
    public var cleanLastDay: Double
    /// The last reading of each weekly window.
    public var weekly: [String: AquariumWeeklyReading]
    /// Weekly windows that reset with under the budget spent.
    public var underBudgetResets: Int
    /// Codex's last banked-credit balance per row.
    public var codexCredits: [String: Double]
    /// Times Codex's banked credits went up.
    public var creditGains: Int

    public init(watchedSince: Double = 0, largestSchool: Int = 0, failedIDs: [String] = [],
                cleanDays: Int = 0, cleanLastDay: Double = 0,
                weekly: [String: AquariumWeeklyReading] = [:], underBudgetResets: Int = 0,
                codexCredits: [String: Double] = [:], creditGains: Int = 0) {
        self.watchedSince = watchedSince
        self.largestSchool = largestSchool
        self.failedIDs = failedIDs
        self.cleanDays = cleanDays
        self.cleanLastDay = cleanLastDay
        self.weekly = weekly
        self.underBudgetResets = underBudgetResets
        self.codexCredits = codexCredits
        self.creditGains = creditGains
    }

    /// The budget line a weekly window must stay under.
    public static let budgetPct: Double = 80
    /// How close to its reset the tank must have read a window for the
    /// reset to count — a reading from days before says nothing about
    /// how the week ended.
    public static let budgetWatchWindow: Double = 6 * 3600
    /// How many counted failures the log keeps.
    public static let failedMemory = 64

    /// Fold one document's facts in. Pure: the same log and facts always
    /// give the same log.
    public mutating func note(_ facts: AquariumFleetFacts, now: Date) {
        let t = now.timeIntervalSince1970
        if watchedSince == 0 { watchedSince = t }
        largestSchool = max(largestSchool, facts.largestSchool)
        let fresh = facts.failedIDs.filter { !failedIDs.contains($0) }
        if !fresh.isEmpty {
            cleanDays = 0
            cleanLastDay = 0
            failedIDs = Array((failedIDs + fresh).suffix(Self.failedMemory))
        }
        for (key, reading) in facts.weekly {
            if let last = weekly[key], Self.endedUnderBudget(last: last, next: reading) {
                underBudgetResets += 1
            }
            weekly[key] = reading
        }
        for (row, balance) in facts.codexCredits {
            if let before = codexCredits[row], balance > before { creditGains += 1 }
            codexCredits[row] = balance
        }
    }

    /// A completion on `day` (`startOfDay` epoch): one clean day per
    /// calendar day, and only while the tank is watching for failures.
    public mutating func noteCompletion(day: Double) {
        guard watchedSince > 0, day != cleanLastDay else { return }
        cleanDays += 1
        cleanLastDay = day
    }

    /// The window rolled over to a new week (its reset moved on by more
    /// than a day), the tank read it within its last hours, and that
    /// last reading was under the line.
    public static func endedUnderBudget(last: AquariumWeeklyReading,
                                        next: AquariumWeeklyReading) -> Bool {
        next.resetsAt - last.resetsAt > 86_400
            && last.resetsAt - last.observedAt <= budgetWatchWindow
            && last.usedPct < budgetPct
    }

    private enum CodingKeys: String, CodingKey {
        case watchedSince, largestSchool, failedIDs, cleanDays, cleanLastDay
        case weekly, underBudgetResets, codexCredits, creditGains
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchedSince = max(0, (try? c.decodeIfPresent(Double.self, forKey: .watchedSince)) ?? 0)
        largestSchool = max(0, (try? c.decodeIfPresent(Int.self, forKey: .largestSchool)) ?? 0)
        failedIDs = (try? c.decodeIfPresent([String].self, forKey: .failedIDs)) ?? []
        cleanDays = max(0, (try? c.decodeIfPresent(Int.self, forKey: .cleanDays)) ?? 0)
        cleanLastDay = max(0, (try? c.decodeIfPresent(Double.self, forKey: .cleanLastDay)) ?? 0)
        weekly = (try? c.decodeIfPresent([String: AquariumWeeklyReading].self, forKey: .weekly)) ?? [:]
        underBudgetResets = max(0, (try? c.decodeIfPresent(Int.self, forKey: .underBudgetResets)) ?? 0)
        codexCredits = (try? c.decodeIfPresent([String: Double].self, forKey: .codexCredits)) ?? [:]
        creditGains = max(0, (try? c.decodeIfPresent(Int.self, forKey: .creditGains)) ?? 0)
    }
}

/// The water reading the fleet, very subtly (docs/TOYS.md): no words and
/// no gauges — the tank becomes a calm ambient meter the way the LED
/// strip is. A quota window running low cools and dims the column, a
/// failed run nobody has reviewed hazes it with a little silt, and a
/// fresh reset lands one bright shaft for a few minutes.
public struct AquariumWaterMood: Equatable, Sendable {
    /// 0…1: how far the tightest headline quota window has run low.
    public var low: Double
    /// 0…1: a failed run is still unreviewed.
    public var cloud: Double
    /// 0…1: a reset just landed — fades out over `shaftLife`.
    public var shaft: Double

    public init(low: Double = 0, cloud: Double = 0, shaft: Double = 0) {
        self.low = low
        self.cloud = cloud
        self.shaft = shaft
    }

    public static let calm = AquariumWaterMood()

    /// The column starts to cool at this much spent, and is fully cool
    /// at `lowFull`.
    public static let lowFrom: Double = 70
    public static let lowFull: Double = 95
    /// How long a reset's shaft lingers.
    public static let shaftLife: TimeInterval = 5 * 60

    /// The slow half of the mood — the quota and the failures — from one
    /// document. Quantized to twentieths, so a window creeping up by a
    /// tenth of a percent doesn't redraw the tank.
    public static func base(_ state: CoreState?) -> AquariumWaterMood {
        guard let state else { return .calm }
        let tightest = (state.usage?.providers ?? [])
            .compactMap { $0.headlineWindow?.usedPct }
            .filter(\.isFinite)
            .max() ?? 0
        let low = min(1, max(0, (tightest - lowFrom) / (lowFull - lowFrom)))
        let unreviewed = state.sessions.contains {
            SessionActivity.reduce($0) == .failed && $0.axes?.review != "reviewed"
        }
        return AquariumWaterMood(low: (low * 20).rounded() / 20, cloud: unreviewed ? 1 : 0)
    }

    /// The base plus the reset's shaft at `now`: full as it lands, eased
    /// out to nothing over `shaftLife`.
    public func with(resetAt: Date?, now: Date) -> AquariumWaterMood {
        var mood = self
        if let resetAt {
            let age = now.timeIntervalSince(resetAt)
            if age >= 0, age < Self.shaftLife {
                let p = 1 - age / Self.shaftLife
                mood.shaft = p * p * (3 - 2 * p)
            }
        }
        return mood
    }
}
