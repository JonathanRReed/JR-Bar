import Foundation
import Testing
@testable import JRBarCore

/// `list_roster` decoding: the scoped document, the roster-only fields
/// (axes, visibility, pinned), the counts block including `listed`, and
/// tolerance for rows a newer daemon adds fields to.
@Suite struct RosterCodecTests {

    private static var document: [String: Any] { [
        "t": "roster",
        "schema": 1,
        "now": 1_800_000_100.0,
        "scope": "all",
        "filters": ["scope": "all"],
        "generation": 7,
        "coverage": [
            "note": "The roster covers retained sessions; deeper history is list_history.",
            "retention": "collector",
        ],
        "counts": [
            "total": 3, "workers": 1, "attention": 1, "live": 2,
            "finished": 1, "hidden_from_panel": 1, "listed": 3,
        ],
        "sessions": [
            [
                "id": "codex:main:1", "provider": "codex", "kind": "main",
                "label": "Fix the flap", "cwd": "/Users/x/Code/JR-Bar",
                "mode": "working", "lifecycle": "active",
                "since": 1_800_000_000.0, "updated_at": 1_800_000_090.0,
                "tool": "Bash", "event": "tool_start",
                "schema": 1, "pinned": false, "visibility": "live",
                "axes": ["outcome": "none", "review": "pending", "freshness": "live"],
            ],
            [
                "id": "codex:main:2", "provider": "codex", "kind": "main",
                "label": "Unacknowledged run", "mode": "completed",
                "lifecycle": "completed", "stale": true,
                "schema": 1, "pinned": true, "visibility": "hidden",
                "axes": ["outcome": "succeeded", "review": "unreviewed", "freshness": "delayed"],
                "ask": ["kind": "question", "summary": "Ship it?", "opened_at": 1_800_000_080.0],
            ],
            [
                "id": "claude:sub:9", "provider": "claude", "kind": "worker",
                "parent": "claude:main:0", "label": "worker",
                "mode": "working", "lifecycle": "active", "remote": true,
                "schema": 1, "pinned": false, "visibility": "live",
                // A field a newer daemon adds that this build does not
                // know: the row must still decode.
                "future_field": ["anything": true],
            ],
        ],
    ] }

    private func decode() throws -> CoreRoster {
        let data = try JSONSerialization.data(withJSONObject: Self.document)
        return try JSONDecoder().decode(CoreRoster.self, from: data)
    }

    @Test func documentDecodesRowsCountsAndCoverage() throws {
        let roster = try decode()
        #expect(roster.sessions.count == 3)
        #expect(roster.counts.total == 3)
        #expect(roster.counts.workers == 1)
        #expect(roster.counts.attention == 1)
        #expect(roster.counts.live == 2)
        #expect(roster.counts.finished == 1)
        #expect(roster.counts.hiddenFromPanel == 1)
        #expect(roster.counts.listed == 3)
        #expect(roster.coverage?["note"]?.stringValue == "The roster covers retained sessions; deeper history is list_history.")
    }

    @Test func rosterOnlyFieldsLandOnTheEntry() throws {
        let roster = try decode()
        let completed = roster.sessions[1]
        #expect(completed.id == "codex:main:2")
        #expect(completed.pinned)
        #expect(completed.visibility == "hidden")
        #expect(completed.axes?.outcome == "succeeded")
        #expect(completed.axes?.review == "unreviewed")
        #expect(completed.axes?.freshness == "delayed")
        #expect(completed.session.ask?.summary == "Ship it?")
    }

    @Test func workerAndRemoteFactsSurvive() throws {
        let roster = try decode()
        let worker = roster.sessions[2]
        #expect(worker.session.kind == "worker")
        #expect(worker.session.parent == "claude:main:0")
        #expect(worker.session.remote)
    }

    @Test func missingOptionalFieldsStayAbsent() throws {
        var doc = Self.document
        var sessions = doc["sessions"] as! [[String: Any]]
        sessions[0].removeValue(forKey: "axes")
        sessions[0].removeValue(forKey: "visibility")
        sessions[0].removeValue(forKey: "pinned")
        doc["sessions"] = sessions
        doc.removeValue(forKey: "coverage")
        let data = try JSONSerialization.data(withJSONObject: doc)
        let roster = try JSONDecoder().decode(CoreRoster.self, from: data)
        #expect(roster.sessions[0].axes == nil)
        #expect(roster.sessions[0].visibility == nil)
        #expect(roster.sessions[0].pinned == false)
        #expect(roster.coverage == nil)
    }

    @Test func aMissingCountsBlockYieldsZeroes() throws {
        var doc = Self.document
        doc.removeValue(forKey: "counts")
        let data = try JSONSerialization.data(withJSONObject: doc)
        let roster = try JSONDecoder().decode(CoreRoster.self, from: data)
        #expect(roster.counts.total == 0)
        #expect(roster.counts.listed == 0)
        #expect(roster.sessions.count == 3)
    }

    /// The parity check's other half lives in `test_upgrade_roster.py`:
    /// this decodes the document the daemon actually generated.
    @Test func generatedDaemonFixtureDecodes() throws {
        let data = try CoreFixtures.data("python-roster.json")
        let roster = try JSONDecoder().decode(CoreRoster.self, from: data)
        #expect(roster.sessions.count == 3)
        #expect(roster.counts.total == 3)
        #expect(roster.counts.attention == 1)
        #expect(roster.counts.hiddenFromPanel == 1)
        #expect(roster.counts.listed == 3)
        let byID = Dictionary(uniqueKeysWithValues: roster.sessions.map { ($0.id, $0) })
        // Every row carries the roster-only fields the Overview reads.
        for entry in roster.sessions {
            #expect(entry.axes != nil, "\(entry.id) has no axes")
            #expect(entry.visibility != nil, "\(entry.id) has no visibility")
        }
        #expect(byID["codex:session:asking"]?.pinned == true)
        #expect(byID["codex:session:asking"]?.session.ask != nil)
        #expect(byID["claude:agent:w1"]?.session.kind == "worker")
        #expect(byID["gemini:session:old"]?.visibility == "hidden")
        #expect(roster.coverage?["history"]?.stringValue == "list_history")
    }

    @Test func aMalformedRowIsSkippedNotFatal() throws {
        var doc = Self.document
        var sessions = doc["sessions"] as! [[String: Any]]
        // A row with no id at all cannot be a session record; tolerance
        // drops it rather than failing the whole document.
        sessions.append(["garbage": true])
        doc["sessions"] = sessions
        let data = try JSONSerialization.data(withJSONObject: doc)
        let roster = try JSONDecoder().decode(CoreRoster.self, from: data)
        #expect(roster.sessions.count == 3)
    }
}
