import Foundation
import JRBarCore
import Observation

/// The "Try it" ask, held in memory and nowhere else (`DemoAsk`). The
/// panel and the notch card draw it in the real ask card, tinted and
/// labelled as a demo. It is not in the daemon's state, so nothing that
/// reads the daemon (History, usage, the lights, the menu bar count, a
/// banner, a sound) ever sees it, and answering it only puts it away.
@MainActor
@Observable
final class DemoAskStore {
    static let shared = DemoAskStore()

    /// The demo while it is up; nil when there is none.
    private(set) var ask: CoreAsk?
    /// The clock `show` stamps the demo with; tests hand in their own.
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }

    /// The demo as of `now`: nil once it has been put away or has waited
    /// its `DemoAsk.lifetime` out, so it never lingers unseen.
    func current(at now: Date) -> CoreAsk? {
        guard let ask, let opened = ask.openedAt,
              now.timeIntervalSince1970 - opened < DemoAsk.lifetime else { return nil }
        return ask
    }

    /// Brings up the surface the person's asks arrive on; the app delegate
    /// wires it. Opens only, never answers.
    @ObservationIgnored var presenter: @MainActor () -> Void = {}

    /// Puts a fresh demo up, replacing any earlier one.
    func show() {
        if let old = ask { AskExpansion.shared.collapse(old) }
        ask = DemoAsk.make(now: clock())
    }

    /// The "Try it" button: the demo goes up and the surface it appears on opens.
    func tryIt() {
        show()
        presenter()
    }

    /// Takes it down without an answer.
    func dismiss() {
        if let old = ask { AskExpansion.shared.collapse(old) }
        ask = nil
    }

    /// An answer to the demo: it goes away, and the line says that nothing
    /// was sent. No verdict leaves the app from here.
    func finish(_ verdict: AskVerdict) -> AskAnswerDesk.Outcome {
        dismiss()
        return AskAnswerDesk.Outcome(ok: true, line: DemoAsk.answeredLine)
    }
}
