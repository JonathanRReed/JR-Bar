import Foundation
import Testing
@testable import JRBarCore

@Suite("Deck reply budgets")
struct CoreDeckReplyBudgetTests {
    @Test func setupRepliesOutliveTheirDaemonPhases() throws {
        let singlePhase: [String] = ["deck_plan_keymap", "deck_restore_keymap"]
        for command in singlePhase {
            let budget = try #require(CoreModel.deckReplyTimeout(for: command))
            #expect(budget > 60 && budget <= 70)
        }
        let apply = try #require(CoreModel.deckReplyTimeout(for: "deck_apply_keymap"))
        #expect(apply > 120 && apply <= 130)
    }

    @Test func approvalIncludesTheProbeAndSettingsSave() throws {
        let approval = try #require(CoreModel.deckReplyTimeout(for: "deck_approve_device"))
        #expect(approval > 2 + 15 && approval <= 25)
        let disable = try #require(CoreModel.deckReplyTimeout(for: "deck_disable"))
        #expect(disable > 15 && disable <= 25)
    }

    @Test func interactionCommandsKeepTheirOrdinaryBudget() {
        for command in ["ping", "answer_ask", "deck_answer", "deck_press", "deck_bank", "deck_set_settings"] {
            #expect(CoreModel.deckReplyTimeout(for: command) == nil)
        }
    }
}
