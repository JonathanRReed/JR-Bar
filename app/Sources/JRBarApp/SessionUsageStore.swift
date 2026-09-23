import Foundation
import JRBarCore
import Observation

/// Per-session model, tokens, cost and context, fetched from
/// `session_usage` for whichever rows a surface is showing. One store is
/// shared by the panel and the Overview, so a row read for the panel is
/// already there when the Overview opens.
///
/// Reads are cheap daemon-side (each transcript is parsed incrementally,
/// inside a reply budget), but they are still file I/O on the connection
/// every other command waits behind, so every id is asked about at most
/// once per `freshFor` and a request never names more than `batchLimit`
/// of them. An answer decides when the id is asked again (`stamp`): a
/// `reading` gap soon, a gap that will not change soon only after a
/// backoff. A failed request leaves what was known in place, and waits
/// its `freshFor` like an answer: a cost that was right a minute ago is
/// better than a blank, and a resend while the daemon is still busy with
/// the first only queues behind it.
@MainActor
@Observable
final class SessionUsageStore {
    let core: CoreModel

    private(set) var usage: [String: SessionUsage] = [:]
    private(set) var gaps: [String: String] = [:]
    /// Bumps whenever `usage` changes, so a memo keyed on it (the
    /// Overview's sorted rows) knows to recompute.
    private(set) var generation = 0

    @ObservationIgnored private(set) var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Consecutive gaps that will not change soon, per id, for the backoff.
    @ObservationIgnored private var settledGaps: [String: Int] = [:]

    nonisolated static let freshFor: TimeInterval = 15
    nonisolated static let batchLimit = 64
    /// A `reading` gap: the daemon's reply budget ran out part way through
    /// the file, and its saved offset carries on at the next ask.
    nonisolated static let readingRetry: TimeInterval = 3
    /// A missing transcript or an unknown id backs off from this, doubling
    /// per repeat up to `settledBackoffCap`; a provider with no reader, or
    /// a peer's row, goes straight to the cap.
    nonisolated static let settledBackoff: TimeInterval = 60
    nonisolated static let settledBackoffCap: TimeInterval = 600
    nonisolated static let settledGapKinds: Set<String> = ["transcript_not_found", "not_found", "unsupported_provider", "remote"]

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
                    // The send's stamp stands: asked again after `freshFor`,
                    // not on the next clock tick while the daemon may still
                    // be working on this one.
                }
            }
        }
    }

    /// The `fetchedAt` stamp an answer leaves — `due` asks again once
    /// `freshFor` has passed since it, so a stamp in the past asks sooner
    /// and one in the future later. A session's usage keeps the send's
    /// time; `reading` comes back in `readingRetry`; `transcript_not_found`
    /// and `not_found` back off (the `repeats`th in a row waits
    /// `settledBackoff` · 2^(repeats−1), capped); `unsupported_provider`
    /// and `remote` cannot change for this id and wait the cap. Anything
    /// else (`transcript_unreadable`, a gap this build does not know) keeps
    /// the normal cadence.
    nonisolated static func stamp(gap: String?, repeats: Int, now: Date) -> Date {
        let wait: TimeInterval
        switch gap {
        case "reading": wait = readingRetry
        case "transcript_not_found", "not_found":
            wait = min(settledBackoffCap, settledBackoff * pow(2, Double(max(0, repeats - 1))))
        case "unsupported_provider", "remote": wait = settledBackoffCap
        default: return now
        }
        return now.addingTimeInterval(wait - freshFor)
    }

    func apply(_ document: SessionUsageDocument, asked: [String], now: Date = Date()) {
        var changed = false
        for id in asked {
            if let row = document.sessions[id] {
                if usage[id] != row { usage[id] = row; changed = true }
                gaps[id] = nil
                settledGaps[id] = nil
            } else if let gap = document.gaps[id] {
                gaps[id] = gap
                // A transcript that vanished (cleaned up, moved) keeps the
                // last reading rather than blanking a row that had one.
                var repeats = settledGaps[id] ?? 0
                if Self.settledGapKinds.contains(gap) {
                    repeats += 1
                    settledGaps[id] = repeats
                }
                fetchedAt[id] = Self.stamp(gap: gap, repeats: repeats, now: now)
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

    /// Merges readings in: two stores (a window opened before the app
    /// shared one) must add to the index, never erase each other's rows.
    func update(_ usage: [String: SessionUsage]) {
        lock.lock()
        defer { lock.unlock() }
        for (id, row) in usage {
            costs[id] = row.estimatedCostUSD
            models[id] = row.modelName
        }
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
