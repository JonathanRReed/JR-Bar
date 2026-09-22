import Foundation
import JRBarCore
import Observation

/// Per-session model, tokens, cost and context, fetched from
/// `session_usage` for whichever rows a surface is showing. One store is
/// shared by the panel, the Overview and the Usage Center, so a row read
/// for the panel is already there when the Overview opens.
///
/// Reads are cheap daemon-side (each transcript is parsed incrementally),
/// but they are still file I/O on the daemon's socket thread, so every id
/// is asked about at most once per `freshFor` and a request never names
/// more than `batchLimit` of them. A failed request leaves what was known
/// in place: a cost that was right a minute ago is better than a blank.
@MainActor
@Observable
final class SessionUsageStore {
    let core: CoreModel

    private(set) var usage: [String: SessionUsage] = [:]
    private(set) var gaps: [String: String] = [:]
    /// Bumps whenever `usage` changes, so a memo keyed on it (the
    /// Overview's sorted rows) knows to recompute.
    private(set) var generation = 0

    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    nonisolated static let freshFor: TimeInterval = 15
    nonisolated static let batchLimit = 64

    init(core: CoreModel) {
        self.core = core
    }

    func usage(for id: String) -> SessionUsage? { usage[id] }
    func gap(for id: String) -> String? { gaps[id] }

    /// The ids worth asking about now: not remote (the daemon would only
    /// say so), not already on the wire, and not asked within `freshFor`.
    nonisolated static func due(_ ids: [String], fetchedAt: [String: Date], inFlight: Set<String>,
                                now: Date, freshFor: TimeInterval = freshFor, force: Bool = false) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard seen.insert(id).inserted, !CoreSession.isRemoteID(id), !inFlight.contains(id) else { return false }
            if force { return true }
            guard let at = fetchedAt[id] else { return true }
            return now.timeIntervalSince(at) >= freshFor
        }
    }

    /// Ask for the ids that are due; the answers land in `usage`/`gaps`.
    func refresh(ids: [String], force: Bool = false) {
        guard core.isLive else { return }
        let now = Date()
        let due = Self.due(ids, fetchedAt: fetchedAt, inFlight: inFlight, now: now, force: force)
        guard !due.isEmpty else { return }
        for start in stride(from: 0, to: due.count, by: Self.batchLimit) {
            let batch = Array(due[start..<min(due.count, start + Self.batchLimit)])
            for id in batch {
                fetchedAt[id] = now
                inFlight.insert(id)
            }
            Task { [weak self] in
                guard let self else { return }
                defer { for id in batch { self.inFlight.remove(id) } }
                do {
                    let document = try await self.core.sessionUsage(ids: batch)
                    self.apply(document, asked: batch)
                } catch {
                    // Try again next time rather than trusting the silence.
                    for id in batch { self.fetchedAt[id] = nil }
                }
            }
        }
    }

    func apply(_ document: SessionUsageDocument, asked: [String]) {
        var changed = false
        for id in asked {
            if let row = document.sessions[id] {
                if usage[id] != row { usage[id] = row; changed = true }
                gaps[id] = nil
            } else if let gap = document.gaps[id] {
                gaps[id] = gap
                // A transcript that vanished (cleaned up, moved) keeps the
                // last reading rather than blanking a row that had one.
            }
        }
        if changed {
            generation &+= 1
            SessionUsageIndex.shared.update(usage)
        }
    }
}

/// The Overview table sorts through key paths on `CoreRosterEntry`, which
/// cannot reach a main-actor store; this is the lock-guarded copy of the
/// two facts its Model and Cost columns sort by.
final class SessionUsageIndex: @unchecked Sendable {
    static let shared = SessionUsageIndex()

    private let lock = NSLock()
    private var costs: [String: Double] = [:]
    private var models: [String: String] = [:]

    func update(_ usage: [String: SessionUsage]) {
        lock.lock()
        defer { lock.unlock() }
        costs = usage.compactMapValues(\.estimatedCostUSD)
        models = usage.compactMapValues(\.modelName)
    }

    func cost(for id: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return costs[id]
    }

    func model(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return models[id]
    }
}
