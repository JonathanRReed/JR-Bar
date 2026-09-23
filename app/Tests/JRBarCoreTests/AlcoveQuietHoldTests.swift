import Foundation
import Testing
@testable import JRBarCore

/// The capsule queue's quiet hold: what a Focus or quiet mode keeps
/// back, how it names the stretch, and the one summary it replays as.
/// Pure — no notch required.
@Suite("Alcove quiet hold")
struct AlcoveQuietHoldTests {
    private func notice(_ kind: AlcoveNoticeKind, id: String, session: String? = nil,
                        provider: String? = "claude") -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)", subtitle: kind.verb,
                     provider: provider, session: session, key: "\(kind.rawValue):\(id)")
    }

    @Test("only news about work that went fine is held; asks, failures and the Mac's own speak")
    func holdsOnlyGoodNews() {
        var queue = AlcoveCapsuleQueue()
        let completed = queue.hold(notice(.completed, id: "c"))
        let reset = queue.hold(notice(.quotaReset, id: "q"))
        #expect(completed && reset)
        for kind in [AlcoveNoticeKind.ask, .failed, .charging, .focus, .device, .timer] {
            let held = queue.hold(notice(kind, id: kind.rawValue))
            #expect(!held, "\(kind) still speaks")
        }
        #expect(queue.held.map(\.id) == ["c", "q"])
    }

    @Test("the hold is bounded and keeps the newest")
    func holdBounded() {
        var queue = AlcoveCapsuleQueue()
        for n in 0..<(AlcoveCapsuleQueue.heldLimit + 5) {
            queue.hold(notice(.completed, id: "\(n)"))
        }
        #expect(queue.held.count == AlcoveCapsuleQueue.heldLimit)
        #expect(queue.held.first?.id == "5")
    }

    @Test("the release is one summary titled with where the person was, and empties the hold")
    func releaseSummarises() {
        var queue = AlcoveCapsuleQueue()
        queue.hold(notice(.completed, id: "a", session: "s1"))
        queue.hold(notice(.completed, id: "b", session: "s2"))
        queue.hold(notice(.completed, id: "c", session: "s3"))
        queue.hold(notice(.quotaReset, id: "q"))
        let summary = queue.releaseHeld(id: "sum", during: "Work")
        #expect(summary?.title == "While you were in Work")
        #expect(summary?.subtitle == "3 finished · 1 quota reset")
        #expect(summary?.kind == .completed)
        #expect(summary?.session == nil, "many runs point at none of them")
        #expect(summary?.key == "held:sum", "a summary never shares a run's cooldown key")
        #expect(queue.held.isEmpty)
        #expect(queue.releaseHeld(id: "again", during: "Work") == nil, "nothing held, nothing said")
    }

    @Test("one held run keeps its session so a tap opens it")
    func singleKeepsSession() {
        var queue = AlcoveCapsuleQueue()
        queue.hold(notice(.completed, id: "a", session: "claude:s1"))
        let summary = queue.releaseHeld(id: "sum", during: nil)
        #expect(summary?.session == "claude:s1")
        #expect(summary?.provider == "claude")
        #expect(summary?.title == "While you were away")
        #expect(summary?.subtitle == "1 finished")
    }

    @Test("resets alone read as resets")
    func resetsOnly() {
        var queue = AlcoveCapsuleQueue()
        queue.hold(notice(.quotaReset, id: "a"))
        queue.hold(notice(.quotaReset, id: "b"))
        let summary = queue.releaseHeld(id: "sum", during: "quiet mode")
        #expect(summary?.kind == .quotaReset)
        #expect(summary?.subtitle == "2 quota resets")
    }

    @Test("state.focus names the quiet stretch; off is not one")
    func quietContextFromFocus() {
        // The daemon writes "off", never null or "normal" — but a
        // reader tolerates all three as not quiet.
        #expect(AlcoveCapsuleQueue.quietContext(mode: "off", source: nil) == nil)
        #expect(AlcoveCapsuleQueue.quietContext(mode: nil, source: nil) == nil)
        #expect(AlcoveCapsuleQueue.quietContext(mode: "normal", source: "focus") == nil)
        #expect(AlcoveCapsuleQueue.quietContext(mode: " ", source: "focus") == nil)
        #expect(AlcoveCapsuleQueue.quietContext(mode: "dim", source: "focus") == "Focus")
        #expect(AlcoveCapsuleQueue.quietContext(mode: "dim", source: "focus", focusName: "Work") == "Work")
        #expect(AlcoveCapsuleQueue.quietContext(mode: "mute", source: "override") == "quiet mode")
        #expect(AlcoveCapsuleQueue.quietContext(mode: "dark", source: "schedule") == "quiet hours")
        #expect(AlcoveCapsuleQueue.quietContext(mode: "pause", source: nil) == "quiet mode")
        // A Focus name only names a Focus.
        #expect(AlcoveCapsuleQueue.quietContext(mode: "dim", source: "override",
                                                focusName: "Work") == "quiet mode")
    }
}
