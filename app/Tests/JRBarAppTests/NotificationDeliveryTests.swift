import Testing
@testable import JRBarApp

@Suite struct NotificationDeliveryTests {
    @MainActor @Test func withdrawalCancelsDelayedAuthorization() {
        var pending = NotificationBridge.PendingDeliveries()
        let token = pending.begin("ask-1")
        pending.withdraw("ask-1")
        let finished = pending.finish("ask-1", token: token)
        #expect(!finished)
    }

    @MainActor @Test func replacementRejectsOlderCallback() {
        var pending = NotificationBridge.PendingDeliveries()
        let old = pending.begin("ask-1")
        let current = pending.begin("ask-1")
        let oldFinished = pending.finish("ask-1", token: old)
        #expect(!oldFinished)
        let currentFinished = pending.finish("ask-1", token: current)
        #expect(currentFinished)
        let duplicateFinished = pending.finish("ask-1", token: current)
        #expect(!duplicateFinished)
    }

    @MainActor @Test func withdrawingOneAskKeepsOthersPending() {
        var pending = NotificationBridge.PendingDeliveries()
        let first = pending.begin("ask-1")
        let second = pending.begin("ask-2")
        pending.withdraw("ask-1")
        let firstFinished = pending.finish("ask-1", token: first)
        #expect(!firstFinished)
        let secondFinished = pending.finish("ask-2", token: second)
        #expect(secondFinished)
    }
}
