import Foundation
import Testing
@testable import JRBarCore

@Suite("Session activity")
struct SessionActivityTests {
    static func session(lifecycle: String?, mode: String? = nil, nextActor: String? = nil) -> CoreSession {
        CoreSession(id: "s-1", provider: "claude", mode: mode, lifecycle: lifecycle, nextActor: nextActor)
    }

    @Test("lifecycle wins over mode, and every daemon word maps to one activity")
    func lifecycleWords() {
        #expect(SessionActivity.reduce(Self.session(lifecycle: "completed", mode: "working")) == .done)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "failed", mode: "working")) == .failed)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "ended", mode: "working")) == .ended)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "working")) == .working)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "idle")) == .idle)
        // `stale` is a lifecycle the daemon uses too; it is not a finished
        // run, so the mode still decides what the row says.
        #expect(SessionActivity.reduce(Self.session(lifecycle: "stale", mode: "idle_ready")) == .idle)
    }

    @Test("ended is its own word, distinct from done, and neither is a failure")
    func endedIsNotDone() {
        #expect(SessionActivity.ended.word == "Ended")
        #expect(SessionActivity.done.word == "Done")
        #expect(SessionActivity.ended != SessionActivity.done)
        #expect(SessionActivity.failed.word == "Failed")
    }

    @Test("Clear done acknowledges finished and ended rows, nothing that is still live")
    func clearable() {
        #expect(SessionActivity.done.isClearable)
        #expect(SessionActivity.ended.isClearable)
        #expect(!SessionActivity.working.isClearable)
        #expect(!SessionActivity.waiting.isClearable)
        #expect(!SessionActivity.failed.isClearable)
        #expect(!SessionActivity.idle.isClearable)
    }

    @Test("older and looser spellings still land somewhere sensible")
    func spellings() {
        #expect(SessionActivity.reduce(lifecycle: "done", mode: nil, hasAsk: false, nextActor: nil) == .done)
        #expect(SessionActivity.reduce(lifecycle: "closed", mode: nil, hasAsk: false, nextActor: nil) == .ended)
        #expect(SessionActivity.reduce(lifecycle: "exited", mode: nil, hasAsk: false, nextActor: nil) == .ended)
        #expect(SessionActivity.reduce(lifecycle: "ACTIVE", mode: "TOOL_RUNNING", hasAsk: false, nextActor: nil) == .working)
        #expect(SessionActivity.reduce(lifecycle: nil, mode: nil, hasAsk: true, nextActor: nil) == .waiting)
        #expect(SessionActivity.reduce(lifecycle: nil, mode: nil, hasAsk: false, nextActor: "user") == .waiting)
        // An ask outranks nothing but the three terminal words: a session
        // that already failed is not "waiting on you".
        #expect(SessionActivity.reduce(lifecycle: "failed", mode: nil, hasAsk: true, nextActor: "user") == .failed)
    }
}
