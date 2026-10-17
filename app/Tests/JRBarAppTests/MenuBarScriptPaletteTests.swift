import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Script palette admission")
struct MenuBarScriptPaletteTests {
    @Test func refusedJobsDoNotClaimTheRuleRan() throws {
        let rule = MenuBarTriggerRule(id: "fixture", trigger: .screenLocked,
                                      action: .runScript(command: "synthetic-command"))
        let command = MenuBarCommands.ruleRow(rule)
        for message in ["Script queued", "Script is already running", "Too many scripts running", "Menu Bar is stopped"] {
            var requests: [MenuBarCommandAction] = []
            let row = command.paletteItem {
                requests.append($0)
                return message
            }
            let run = try #require(row.actions.first { $0.id == "run" })
            #expect(run.run() == message)
            #expect(requests == [.runRule(id: "fixture")])
        }
    }

    @Test func existingActionsKeepTheirConfirmationWhenNoOverrideIsReturned() throws {
        let rule = MenuBarTriggerRule(id: "fixture", trigger: .screenLocked, action: .hideAll)
        let row = MenuBarCommands.ruleRow(rule).paletteItem { _ in nil }
        let run = try #require(row.actions.first { $0.id == "run" })
        #expect(run.run() == "Rule ran")
    }
}
