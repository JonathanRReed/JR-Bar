import Foundation
import Testing
@testable import JRBarCore

/// `Fixtures/python-state.json` is not hand-written: it is the exact `state`
/// frame `jrbar.core_projection.build_state_document` produced, written by
/// `tests/test_core_projection.py` (`JRBAR_UPDATE_FIXTURES=1`). Everything
/// else in this suite is a document a person typed to describe the protocol;
/// this one is the protocol as the daemon actually speaks it, so a shape the
/// two sides disagree about fails here rather than on the owner's Mac.
@Suite("Python projection fixture")
struct PythonProjectionFixtureTests {
    static func state() throws -> CoreState {
        guard case .state(let state) = try CoreFixtures.message("python-state.json") else {
            struct NotAState: Error {}
            throw NotAState()
        }
        return state
    }

    @Test("the daemon's own state frame decodes")
    func decodes() throws {
        let state = try Self.state()
        #expect(state.generation > 0)
        #expect(!state.sessions.isEmpty)
        #expect(state.aggregate.mode == "needs_you")
        #expect(state.aggregate.needsYou == 1)
    }

    @Test("a window the daemon left unread arrives as unknown, not as zero")
    func unreadWindowSurvivesTheRoundTrip() throws {
        let usage = try #require(try Self.state().usage)
        let codex = try #require(usage.providers.first { $0.id == "codex" })
        // Written by the projection from a lane with no `remaining_percent`.
        let weekly = try #require(codex.windows.first { $0.name == "7d" })
        #expect(weekly.usedPct == nil, "used_pct: null must never decode as a number")
        #expect(weekly.isUnknown)
        #expect(weekly.percentText == "—")
        #expect(weekly.spokenPercent == "no reading")
        // Unread is not absent: the reset the provider did state survives.
        #expect(weekly.resetsAt != nil)
        // And the sibling window with a real number is untouched by it.
        let fiveHour = try #require(codex.windows.first { $0.name == "5h" })
        #expect(fiveHour.usedPct == 12.0)
    }

    @Test("no session both carries a live pid and reads as over")
    func aLivePidIsNeverAnEndedRow() throws {
        for session in try Self.state().sessions where session.pid != nil {
            let activity = SessionActivity.reduce(session)
            #expect(activity != .ended, "\(session.id) has a pid and reads Ended")
            #expect(session.lifecycle != "ended", "\(session.id) has a pid and reads ended")
        }
    }

    @Test("focus carries the quiet words and sessions carry their snooze")
    func focusAndSnoozeDecode() throws {
        let state = try Self.state()
        let focus = try #require(state.focus)
        // The fixture's schedule contribution: source is the app's word
        // "schedule", never the daemon's internal name.
        #expect(focus.mode == "dim")
        #expect(focus.source == "schedule")
        #expect(focus.until != nil)
        // `snoozed_until` is on every row, null until the family mailbox
        // snoozes it.
        #expect(state.sessions.allSatisfy { $0.snoozedUntil == nil })
    }
}
