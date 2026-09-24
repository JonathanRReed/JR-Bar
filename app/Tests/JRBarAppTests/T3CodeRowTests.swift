import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Settings › Agents' T3 Code row reads `t3code_integration`'s document
/// (docs/CORE-PROTOCOL.md) and says what the reader saw in plain words.
@Suite struct T3CodeRowTests {
    private static func reply(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test("an off row parses with no observation and says what turning it on does")
    func offRow() throws {
        let status = try #require(T3CodeStatus.parse(Self.reply(
            #"{"present": true, "database": "/x/state.sqlite", "enabled": false, "activity_statistics": false, "read_only": false, "observation": null}"#)))
        #expect(status == T3CodeStatus(present: true, enabled: false, readOnly: false, observation: nil))
        #expect(status.line.hasPrefix("Shows T3 Code's threads"))
        #expect(status.line.contains("nothing leaves this Mac"))

        var locked = status
        locked.readOnly = true
        #expect(locked.line.contains("locked"))
        #expect(try T3CodeStatus.parse(Self.reply(#"{"enabled": true}"#)) == nil, "no presence, no row")
        #expect(T3CodeStatus.parse(nil) == nil)
    }

    @Test("an on row counts threads, drops zero parts, and names a refusal")
    func onRow() throws {
        let watching = try #require(T3CodeStatus.parse(Self.reply(
            #"{"present": true, "enabled": true, "read_only": false, "observation": {"available": true, "threads": 12, "active": 2, "needs_user": 1, "reason": null, "in_flight": false}}"#)))
        #expect(watching.observation?.threads == 12)
        #expect(watching.line == "Watching 12 threads · 2 working · 1 needs you")

        let quiet = T3CodeStatus(present: true, enabled: true, readOnly: false, observation: .init(
            available: true, threads: 1, active: 0, needsUser: 0, reason: nil, inFlight: false))
        #expect(quiet.line == "Watching 1 thread")

        let stale = T3CodeStatus(present: true, enabled: true, readOnly: false, observation: .init(
            available: true, threads: 3, active: 0, needsUser: 2, reason: "t3_database_busy", inFlight: false))
        #expect(stale.line == "Watching 3 threads · 2 need you · database busy, retrying")

        let starting = T3CodeStatus(present: true, enabled: true, readOnly: false, observation: .init(
            available: false, threads: 0, active: 0, needsUser: 0, reason: nil, inFlight: true))
        #expect(starting.line == "Reading T3 Code…")
        let refused = T3CodeStatus(present: true, enabled: true, readOnly: false, observation: .init(
            available: false, threads: 0, active: 0, needsUser: 0, reason: "t3_schema_unsupported", inFlight: false))
        #expect(refused.line == "This T3 Code version isn't one JR-Bar can read yet.")
        #expect(T3CodeStatus.words(for: "anything-else") == "JR-Bar couldn't read T3 Code's database.")
    }

    @Test("a row switched on reads again until the reader's look lands")
    func settling() {
        func row(enabled: Bool = true, _ observation: T3CodeStatus.Observation?) -> T3CodeStatus {
            T3CodeStatus(present: true, enabled: enabled, readOnly: false, observation: observation)
        }
        func look(available: Bool, reason: String? = nil, inFlight: Bool) -> T3CodeStatus.Observation {
            .init(available: available, threads: available ? 4 : 0, active: 0, needsUser: 0,
                  reason: reason, inFlight: inFlight)
        }
        // The switch's own reply: the reader reconciled, its first look
        // still on its way.
        #expect(row(nil).isSettling)
        #expect(row(look(available: false, inFlight: true)).isSettling)
        #expect(row(look(available: false, inFlight: false)).isSettling)
        #expect(row(look(available: false, reason: "t3_database_busy", inFlight: false)).isSettling)
        // Settled: a look to show, or a refusal that will not change alone.
        #expect(!row(look(available: true, inFlight: false)).isSettling)
        #expect(!row(look(available: true, inFlight: true)).isSettling)
        #expect(!row(look(available: false, reason: "t3_schema_unsupported", inFlight: false)).isSettling)
        #expect(!row(look(available: false, reason: "t3_database_missing", inFlight: false)).isSettling)
        // Off never reads.
        #expect(!row(enabled: false, nil).isSettling)
    }
}
