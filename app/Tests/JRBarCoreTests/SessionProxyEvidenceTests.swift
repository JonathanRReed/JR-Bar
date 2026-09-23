import Foundation
import Testing
@testable import JRBarCore

@Suite("Proxy evidence in a session timeline")
struct SessionProxyEvidenceTests {
    private func item(_ seq: Int, at: Double?, kind: ReconstructedItem.Kind = .message, error: Bool = false) -> ReconstructedItem {
        ReconstructedItem(seq: seq, at: at, kind: kind, isError: error)
    }

    private func request(at: Double?, status: Int?, model: String? = nil, attempts: Int = 1) -> CLIProxyRequest {
        CLIProxyRequest(timestamp: at.map { Date(timeIntervalSince1970: $0) }, method: "POST",
                        path: "localhost:8317/v1/messages", model: model, status: status,
                        attemptCount: attempts, errorSummary: (status ?? 0) >= 400 ? "HTTP \(status ?? 0)" : nil)
    }

    @Test("a request sits ahead of the first row stamped after it; undated rows keep the end")
    func interleave() {
        let items = [item(0, at: 10), item(1, at: 20), item(2, at: nil)]
        let entries = SessionProxyEvidence.interleave(items, requests: [
            request(at: 25, status: 200), request(at: 15, status: 529), request(at: nil, status: 500),
        ])
        #expect(entries.map(\.id) == ["item:0", "request:0", "item:1", "request:1", "item:2", "request:2"])
        #expect(entries.map(\.isError) == [false, true, false, false, false, true])
        // No requests: the items as they were.
        #expect(SessionProxyEvidence.interleave(items, requests: []).map(\.id) == ["item:0", "item:1", "item:2"])
    }

    @Test("a request stamped with a row goes before it, so the call reads ahead of its reply")
    func tie() {
        let entries = SessionProxyEvidence.interleave([item(0, at: 10)], requests: [request(at: 10, status: 200)])
        #expect(entries.map(\.id) == ["request:0", "item:0"])
    }

    @Test("the summary counts refusals by status and says how it ended")
    func summary() {
        #expect(SessionProxyEvidence.summary([request(at: 1, status: 200)]) == nil)
        #expect(SessionProxyEvidence.summary([]) == nil)
        #expect(SessionProxyEvidence.summary([
            request(at: 1, status: 529), request(at: 2, status: 529), request(at: 3, status: 500), request(at: 4, status: 200),
        ]) == "2 × HTTP 529 · 1 × HTTP 500, then it went through")
        #expect(SessionProxyEvidence.summary([
            request(at: 2, status: 529), request(at: 1, status: 200),
        ]) == "1 × HTTP 529, and the last one failed")
    }

    @Test("a row names the request, its model and its retries")
    func line() {
        #expect(SessionProxyEvidence.line(request(at: 1, status: 529, model: "claude-opus-4-5", attempts: 3))
                == "POST localhost:8317/v1/messages → 529 · claude-opus-4-5 · 3 attempts")
        #expect(SessionProxyEvidence.line(request(at: 1, status: nil)) == "POST localhost:8317/v1/messages → …")
    }

    @Test("the newest requests are kept when a session logged more than the cap")
    func cap() {
        let many = (0..<(SessionProxyEvidence.requestLimit + 5)).map { request(at: Double($0), status: 200) }
        let kept = SessionProxyEvidence.sorted(many.reversed())
        #expect(kept.count == SessionProxyEvidence.requestLimit)
        #expect(kept.first?.timestamp == Date(timeIntervalSince1970: 5))
    }

    @Test("a reconstruction carries its requests into the entries")
    func reconstruction() {
        let base = SessionReconstruction(items: [item(0, at: 10)], story: SessionReconstructor.story(for: []),
                                         gaps: [], totalLines: 1, redactedLines: 0)
        #expect(base.entries.map(\.id) == ["item:0"])
        let joined = base.withProxyRequests([request(at: 12, status: 503), request(at: 5, status: 200)])
        #expect(joined.proxyRequests.map(\.status) == [200, 503])
        #expect(joined.entries.map(\.id) == ["request:0", "item:0", "request:1"])
        #expect(joined.items == base.items && joined.story == base.story)
    }
}
