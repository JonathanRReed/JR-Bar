import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Settings › Usage › Hooks reads the rules straight from the settings
/// document and says, in words, which ones can never run.
@Suite("Usage hooks section")
struct UsageHooksSectionTests {
    static let document = SettingsDocument(.object([
        "usage_hooks": .object([
            "enabled": .bool(true),
            "rules": .array([
                .object([
                    "id": .string("chime"), "enabled": .bool(true), "event": .string("quota_low"),
                    "provider": .string("claude"), "threshold_remaining": .number(20),
                    "executable": .string("/usr/local/bin/chime"), "arguments": .array([.string("--soft")]),
                    "argv": .string("json"),
                ]),
                .object([
                    "id": .string("log"), "enabled": .bool(false), "event": .string("*"),
                    "executable": .string("log-usage.py"), "argv": .string("legacy"),
                ]),
                .string("not a rule"),
            ]),
        ]),
    ]))

    @Test func rulesComeFromTheDocumentInOrder() {
        let rows = UsageHookRuleRow.rows(in: Self.document)
        #expect(rows.map(\.id) == ["chime", "log"])
        #expect(rows.map(\.index) == [0, 1])
        #expect(rows[0].scopeText == "Quota low · Claude · at or below 20% left")
        #expect(rows[0].commandText == "Runs /usr/local/bin/chime --soft")
        #expect(rows[1].scopeText == "Every event")
        #expect(rows[1].commandText.hasSuffix("with the first version's arguments"))
    }

    @Test func aRuleThatCanNeverRunSaysWhy() {
        let rows = UsageHookRuleRow.rows(in: Self.document)
        #expect(rows[0].localProblem == nil)
        #expect(rows[1].localProblem == "the executable must be an absolute path")
        #expect(rows[0].testEvent == "quota_low")
        #expect(rows[1].testEvent == "quota_low")
    }

    @Test @MainActor func theMonitorsStatusFillsProblemsAndLastResults() {
        let model = UsageHooksModel()
        model.apply(status: .object([
            "problem": .null,
            "rules": .array([
                .object(["id": .string("chime"), "problem": .null,
                         "last_result": .object(["sentence": .string("Quota low: exit 0 in 0.1 s"),
                                                 "event": .string("quota_low"),
                                                 "outcome": .string("ok"), "at": .number(1_790_000_000)])]),
                .object(["id": .string("log"), "problem": .string("the executable must be an absolute path")]),
            ]),
        ]))
        #expect(model.lastResults["chime"]?.ok == true)
        #expect(model.problems["log"] == "the executable must be an absolute path")
        let later = Date(timeIntervalSince1970: 1_790_000_180)
        #expect(model.lastResults["chime"]?.line(now: later).hasPrefix("Last run: Quota low: exit 0") == true)
        // Under its own Quota low rule the event isn't said twice.
        #expect(model.lastResults["chime"]?.line(now: later, ruleEvent: "quota_low").hasPrefix("Last run: exit 0 in 0.1 s") == true)
        #expect(model.lastResults["chime"]?.line(now: later, ruleEvent: "*").hasPrefix("Last run: Quota low: exit 0") == true)
    }
}
