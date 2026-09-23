import Foundation

/// CLIProxyAPI's request logs placed into a session's timeline: the
/// upstream side of each turn (model, HTTP status, retries) beside the
/// transcript's own rows, joined by the session id the proxy logged and
/// ordered by time. A failed turn then reads "3 × HTTP 529, then it gave
/// up" next to it — evidence the transcript alone never carries.
public enum SessionProxyEvidence {
    /// One row of the interleaved timeline.
    public enum Entry: Sendable, Equatable, Identifiable {
        case item(ReconstructedItem)
        /// A proxied request; `index` is its place in the sorted request
        /// list, so the id stays stable across filters.
        case request(index: Int, CLIProxyRequest)

        public var id: String {
            switch self {
            case .item(let item): "item:\(item.seq)"
            case .request(let index, _): "request:\(index)"
            }
        }

        public var at: Double? {
            switch self {
            case .item(let item): item.at
            case .request(_, let request): request.timestamp?.timeIntervalSince1970
            }
        }

        /// A failed tool call or turn, or an upstream answer of 400 and up.
        public var isError: Bool {
            switch self {
            case .item(let item): item.isError
            case .request(_, let request): SessionProxyEvidence.failed(request)
            }
        }
    }

    /// At most this many requests ride along — a long session behind a
    /// proxy logs one file per request, and the newest carry the story.
    public static let requestLimit = 200

    /// The requests in time order (undated ones last, in the order given),
    /// newest `requestLimit` kept.
    public static func sorted(_ requests: [CLIProxyRequest]) -> [CLIProxyRequest] {
        let ordered = requests.enumerated().sorted { left, right in
            switch (left.element.timestamp, right.element.timestamp) {
            case let (l?, r?): return l == r ? left.offset < right.offset : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
        return Array(ordered.suffix(requestLimit))
    }

    /// Transcript items and requests merged by time. A request lands
    /// before the first item stamped after it, so a request made for a
    /// turn sits just ahead of that turn's reply; undated rows of either
    /// kind keep their own order at the end.
    public static func interleave(_ items: [ReconstructedItem],
                                  requests: [CLIProxyRequest]) -> [Entry] {
        let requests = sorted(requests)
        guard !requests.isEmpty else { return items.map(Entry.item) }
        var out: [Entry] = []
        out.reserveCapacity(items.count + requests.count)
        var next = 0
        for item in items {
            if let at = item.at {
                while next < requests.count,
                      let stamp = requests[next].timestamp?.timeIntervalSince1970, stamp <= at {
                    out.append(.request(index: next, requests[next]))
                    next += 1
                }
            } else {
                // The first undated item: every dated request belongs
                // before the undated tail.
                while next < requests.count, requests[next].timestamp != nil {
                    out.append(.request(index: next, requests[next]))
                    next += 1
                }
            }
            out.append(.item(item))
        }
        while next < requests.count {
            out.append(.request(index: next, requests[next]))
            next += 1
        }
        return out
    }

    public static func failed(_ request: CLIProxyRequest) -> Bool {
        (request.status ?? 0) >= 400
    }

    /// The upstream story in one line, or nil when every request went
    /// through: "3 × HTTP 529 · 1 × HTTP 500, then it went through" /
    /// "…, and the last one failed". Counts only; the words come from the
    /// statuses the logs recorded, never a guess at the cause.
    public static func summary(_ requests: [CLIProxyRequest]) -> String? {
        let ordered = sorted(requests)
        let failures = ordered.filter(failed)
        guard !failures.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for request in failures {
            let status = request.status ?? 0
            if counts[status] == nil { order.append(status) }
            counts[status, default: 0] += 1
        }
        let parts = order.map { "\(counts[$0] ?? 0) × HTTP \($0)" }.joined(separator: " · ")
        let lastFailed = ordered.last.map(failed) ?? false
        return parts + (lastFailed ? ", and the last one failed" : ", then it went through")
    }

    /// One request as a timeline row reads it: "POST /v1/messages → 529 ·
    /// claude-opus-4-5 · 3 attempts".
    public static func line(_ request: CLIProxyRequest) -> String {
        var parts = ["\(request.method ?? "?") \(request.path ?? "?") → \(request.status.map(String.init) ?? "…")"]
        if let model = request.model, !model.isEmpty { parts.append(model) }
        if request.attemptCount > 1 { parts.append("\(request.attemptCount) attempts") }
        return parts.joined(separator: " · ")
    }
}
