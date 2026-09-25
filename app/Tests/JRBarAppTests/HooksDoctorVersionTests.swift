import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Settings › Agents names each CLI's version beside its hooks line, and a
/// version newer than JR-Bar verified reads as a note, not a problem.
@Suite("Hooks doctor versions")
struct HooksDoctorVersionTests {
    @Test func theVersionAndItsNoteJoinTheLine() throws {
        let report: JSONValue = .object(["providers": .array([
            .object(["provider": .string("claude"), "installed": .bool(true), "hook_events": .number(12),
                     "version": .string("2.1.280"),
                     "compatibility": .object(["status": .string("unknown"),
                                               "note": .string("newer than verified (2.1.263)")])]),
            .object(["provider": .string("codex"), "installed": .bool(true), "hook_events": .number(3),
                     "version": .string("0.153.4"),
                     "compatibility": .object(["status": .string("supported"), "note": .string("verified")])]),
        ])])
        let entries = HooksDoctor.entries(from: report)
        let claude = try #require(entries["claude"])
        let codex = try #require(entries["codex"])
        #expect(HooksDoctor.versionWords(claude) == "v2.1.280, newer than verified (2.1.263)")
        #expect(HooksDoctor.versionWords(codex) == "v0.153.4")
        #expect(HooksDoctor.line(claude)?.hasSuffix("v2.1.280, newer than verified (2.1.263)") == true)
        #expect(HooksDoctor.repairReason(claude) == nil, "a newer CLI is never a reason to repair")
    }

    @Test func aReportWithoutVersionsReadsAsBefore() {
        let entry = HooksDoctorEntry(provider: "grok", installed: true, hookEvents: 2)
        #expect(HooksDoctor.versionWords(entry) == nil)
    }
}
