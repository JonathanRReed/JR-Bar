import Testing
@testable import JRBarCore

@Suite("Swimming is not work evidence")
struct AquariumActivityPresentationRepairTests {
    @Test func idleAndResidentFishAreDistinctFromWork() {
        #expect(AquariumActivityPresentation.summary(states: [.idling, .idling], residents: 0,
                                                     connected: true) == "0 working · 2 idle")
        #expect(AquariumActivityPresentation.summary(states: [], residents: 2,
                                                     connected: true) == "0 working · 2 residents")
        #expect(AquariumActivityPresentation.summary(states: [], residents: 0,
                                                     connected: true) == "0 working · 0 idle")
    }

    @Test func parentsAndSubagentsUseTheSameActivityTruth() {
        let text = AquariumActivityPresentation.summary(
            states: [.swimming, .swimming, .surfacing, .sinking, .leaving], residents: 1,
            connected: true)
        #expect(text == "2 working · 1 needs you · 1 settled · 1 leaving · 1 resident")
    }

    @Test func disconnectedSwimmingIsOnlyLastKnown() {
        let text = AquariumActivityPresentation.summary(states: [.swimming], residents: 2,
                                                        connected: false)
        #expect(text == "Disconnected · 0 confirmed working · 1 last-known session · 2 residents")
        #expect(AquariumActivityPresentation.rewardHelp.contains("Idle fish earn no work-time pearls"))
        #expect(AquariumActivityPresentation.rewardHelp.contains("Feeding and grown-fish rewards"))
    }
}
