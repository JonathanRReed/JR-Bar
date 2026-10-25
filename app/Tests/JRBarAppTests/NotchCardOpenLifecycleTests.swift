import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Notch glass card open lifecycle")
struct NotchCardOpenLifecycleTests {
    private func presenter() -> NotchCardPresenter {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        presenter.model.openNoteTimer = { _, _ in }
        presenter.keySource = CardEscapeWatch.Source(addLocal: { _ in nil }, addGlobal: { _ in nil },
                                                     remove: { _ in })
        presenter.surface = { .glass }
        presenter.focus = { ScreenBarFocus(style: nil, label: "Session", word: "Working",
                                           clickSession: "claude:session") }
        presenter.anchor = { CGRect(x: 100, y: 100, width: 200, height: 20) }
        return presenter
    }

    @Test("an old open cannot hide a reopened glass card or leave its refusal",
          arguments: [false, true])
    func reopenedCardRejectsOldResult(_ refused: Bool) async {
        let presenter = presenter()
        defer { presenter.hide() }
        var completion: CheckedContinuation<String?, Never>?
        presenter.openSession = { _ in await withCheckedContinuation { completion = $0 } }
        presenter.pin()
        let task = presenter.open("claude:session")
        while completion == nil { await Task.yield() }
        presenter.hide()
        presenter.pin()
        completion?.resume(returning: refused ? "Old refusal" : nil)
        await task.value
        #expect(presenter.isShown && presenter.isPinned)
        #expect(presenter.model.openRefusals["claude:session"] == nil)
    }

    @Test("a newer open owns the glass card's refusal")
    func newerOpenOwnsFeedback() async {
        let presenter = presenter()
        defer { presenter.hide() }
        var completions: [CheckedContinuation<String?, Never>] = []
        presenter.openSession = { _ in await withCheckedContinuation { completions.append($0) } }
        presenter.pin()
        let old = presenter.open("claude:session")
        while completions.count < 1 { await Task.yield() }
        let current = presenter.open("claude:session")
        while completions.count < 2 { await Task.yield() }
        completions[1].resume(returning: "Current refusal")
        await current.value
        completions[0].resume(returning: "Old refusal")
        await old.value
        #expect(presenter.isShown)
        #expect(presenter.model.openRefusals["claude:session"] == "Current refusal")
    }
}
