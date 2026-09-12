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

    @Test("the daemon's real mode vocabulary maps without relying on next_actor")
    func daemonModes() {
        // `waiting_for_input` used to fall through to .idle whenever the
        // row carried no `next_actor`, drawing a live ask as a dead row.
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "waiting_for_input")) == .waiting)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "tool_running")) == .working)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "long_task_progress")) == .working)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "blocked_error")) == .failed)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "ended", mode: "ended_unconfirmed")) == .ended)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "idle_ready")) == .idle)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "stale", mode: "idle_ready")) == .idle)
    }

    @Test("an unknown mode on a live row reads as working, not dead")
    func unknownModes() {
        // Belt and braces for the next mode the daemon invents: a listed,
        // active-lifecycle session is working, whatever the word is.
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "some_future_mode")) == .working)
        #expect(SessionActivity.reduce(Self.session(lifecycle: "active", mode: "unknown")) == .working)
        // A stale row is old news, not live: an unclassified stale row
        // keeps its doubt instead of claiming work.
        #expect(SessionActivity.reduce(Self.session(lifecycle: "stale", mode: "some_future_mode")) == .idle)
        // No lifecycle and no mode at all is the no-information case; it
        // stays quiet rather than inventing work.
        #expect(SessionActivity.reduce(Self.session(lifecycle: nil, mode: nil)) == .idle)
    }

    @Test("the panel's row order: waiting, failed, working, done, ended, idle")
    func sortRank() {
        let order: [SessionActivity] = [.waiting, .failed, .working, .done, .ended, .idle]
        #expect(order.map(\.sortRank) == [1, 2, 3, 4, 5, 6])
        #expect(SessionActivity.waiting.sortRank < SessionActivity.failed.sortRank)
        #expect(SessionActivity.failed.sortRank < SessionActivity.working.sortRank)
    }
}

@Suite("The aggregate's words and tint")
struct AgentAggregateStateTests {
    @Test("state.aggregate.mode lands on the five words, and the counts back it up")
    func fromAggregate() {
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "needs_you", needsYou: 1)) == .needsInput)
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "failed", failed: 1)) == .failed)
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "working", active: 2)) == .working)
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "done", ready: 1)) == .completed)
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "idle")) == .idle)
        // A failure counts even when an older daemon's mode says "active".
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "active", active: 1, failed: 1)) == .failed)
        // An open ask still outranks a failure: it is costing time now.
        #expect(AgentAggregateState.from(aggregate: CoreAggregate(mode: "needs_you", needsYou: 1, failed: 1)) == .needsInput)
    }

    @Test("failed is a true red, never the ask's orange-red")
    func failedTintIsDistinct() {
        #expect(AgentAggregateState.failed.tintHex != AgentAggregateState.needsInput.tintHex)
        #expect(AgentAggregateState.failed.tintHex == "#FF3B30")
        #expect(AgentAggregateState.needsInput.tintHex == "#FF3A00")
        #expect(AgentAggregateState.idle.tintHex == nil)
    }

    @Test("the count line runs in the daemon's precedence order")
    func countParts() {
        #expect(CoreAggregate(mode: "needs_you", needsYou: 1, active: 2, ready: 1, failed: 1).countParts
                == ["1 needs you", "1 failed", "2 working", "1 ready"])
        #expect(CoreAggregate(mode: "needs_you", needsYou: 3).countParts == ["3 need you"])
        #expect(CoreAggregate().countParts.isEmpty)
    }
}

@Suite("The agent-monitor file feed")
struct AgentMonitorFeedTests {
    private static func feed(_ json: String) -> Data { Data(json.utf8) }

    @Test("the published agents summary reduces to the state and detail")
    func agentsSummary() {
        let result = AgentMonitorFeed.reduce(Self.feed(#"{"agents":{"lifecycle_counts":{"active":2,"failed":1},"next_actor_counts":{"user":1}}}"#))
        #expect(result.state == .needsInput)
        #expect(result.detail == "1 waiting on you · 1 failed · 2 working")
    }

    @Test("a failure is failed, and its tint is not the ask's")
    func failedIsNotAnAsk() {
        let result = AgentMonitorFeed.reduce(Self.feed(#"{"agents":{"lifecycle_counts":{"failed":2},"next_actor_counts":{}}}"#))
        #expect(result.state == .failed)
        #expect(result.detail == "2 failed")
        #expect(result.state.tintHex != AgentAggregateState.needsInput.tintHex)
    }

    @Test("the raw works list honours the recent-completion window")
    func worksList() {
        let now = Date()
        let fresh = now.timeIntervalSince1970 - 10
        let stale = now.timeIntervalSince1970 - 600
        let json = """
        {"works":[
          {"lifecycle":"active","next_actor":"provider"},
          {"lifecycle":"completed","next_actor":"provider","watermark":{"occurred_at_epoch":\(fresh)}},
          {"lifecycle":"completed","next_actor":"provider","watermark":{"occurred_at_epoch":\(stale)}}
        ]}
        """
        let result = AgentMonitorFeed.reduce(Self.feed(json), now: now)
        #expect(result.state == .working)
        #expect(result.detail == "1 working · 1 just finished")
    }

    @Test("a missing or unrecognised file reads as idle")
    func empty() {
        #expect(AgentMonitorFeed.reduce(nil).state == .idle)
        #expect(AgentMonitorFeed.reduce(Self.feed("{}")).detail == "Unrecognised latest.json")
    }
}

@Suite("Asks with no session left")
struct OrphanAskTests {
    private func state(sessions: [String], asks: [String?]) -> CoreState {
        var state = CoreState()
        state.sessions = sessions.map { id in
            CoreSession(id: id, provider: String(id.split(separator: ":").first ?? ""), kind: "main")
        }
        state.asks = asks.map { CoreAsk(session: $0, kind: "permission", openedAt: 1789067042) }
        return state
    }

    @Test("an ask whose session is still listed is not an orphan")
    func matched() {
        let live = state(sessions: ["claude:session:a"], asks: ["claude:session:a"])
        #expect(live.orphanAsks.isEmpty)
    }

    @Test("an ask the daemon kept after clearing its session still needs a row")
    func orphaned() {
        // The shape the real daemon served on 2026-09-10: aggregate
        // needs_you 1, one ask, and no session with that id.
        let cleared = state(sessions: ["devin:session:b"], asks: ["claude:session:5facd783-99c0-4263-80ec-c33f31712bd2"])
        #expect(cleared.orphanAsks.count == 1)
        #expect(cleared.orphanAsks.first?.session == "claude:session:5facd783-99c0-4263-80ec-c33f31712bd2")
    }

    @Test("an ask with no session at all is still an ask")
    func sessionless() {
        #expect(state(sessions: ["claude:session:a"], asks: [nil]).orphanAsks.count == 1)
        #expect(state(sessions: ["claude:session:a"], asks: [""]).orphanAsks.count == 1)
    }

    @Test("no asks, no work")
    func none() {
        #expect(state(sessions: ["claude:session:a"], asks: []).orphanAsks.isEmpty)
    }
}
