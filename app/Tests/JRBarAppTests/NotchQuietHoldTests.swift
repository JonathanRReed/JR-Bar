import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The quiet hold against the toy: while `state.focus` says quiet,
/// finished runs wait instead of morphing the island; asks still show;
/// the stretch ending replays one summary. `islandVisible` stands in
/// for a notched screen and `noteQuietChange` for `reconcile`.
@Suite("Notch quiet hold")
@MainActor
struct NotchQuietHoldTests {
    private func focus(_ json: String) throws -> CoreFocus {
        try JSONDecoder().decode(CoreFocus.self, from: Data(json.utf8))
    }

    private func makeToy(hold: Bool = true) -> (NotchToy, ToysStore, CoreModel) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        toys.notch.holdNewsWhileQuiet = hold
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store, core)
    }

    private func news(_ kind: AlcoveNoticeKind, id: String) -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)", subtitle: kind.verb,
                     session: "claude:\(id)", key: "\(kind.rawValue):\(id)")
    }

    private func quiet(_ core: CoreModel, _ json: String) throws {
        core.apply(.state(CoreState(generation: 1, focus: try focus(json))))
    }

    @Test("a Focus holds a finished run; an ask and a failure still show")
    func holdsDuringFocus() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"dim","source":"focus"}"#)
        toy.noteQuietChange()
        toy.offer(news(.completed, id: "c"))
        #expect(toy.activeCapsule == nil, "good news waits for the stretch to end")
        #expect(toy.capsuleQueue.held.map(\.id) == ["c"])
        toy.offer(news(.failed, id: "f"))
        #expect(toy.activeCapsule?.id == "f", "a failure is not news a Focus holds")
    }

    @Test("the stretch ending replays one summary named after the Focus")
    func replaysOnEnd() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        // The Mac's own announcement named the Focus on its way in.
        toy.offer(NotchAnnouncements.focusNotice(name: "Work", on: true))
        toy.finishCapsule()
        try quiet(core, #"{"mode":"dim","source":"focus"}"#)
        toy.noteQuietChange()
        toy.offer(news(.completed, id: "a"))
        toy.offer(news(.completed, id: "b"))
        #expect(toy.capsuleQueue.held.count == 2)

        try quiet(core, #"{"mode":"off"}"#)
        toy.noteQuietChange()
        #expect(toy.capsuleQueue.held.isEmpty)
        let shown = toy.capsuleQueue.current
        #expect(shown?.title == "While you were in Work")
        #expect(shown?.subtitle == "2 finished")
    }

    @Test("a quiet mode picked by hand holds too, and says so on the way out")
    func overrideHolds() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"mute","source":"override"}"#)
        toy.noteQuietChange()
        toy.offer(news(.quotaReset, id: "q"))
        #expect(toy.activeCapsule == nil)
        try quiet(core, #"{"mode":"off"}"#)
        toy.noteQuietChange()
        #expect(toy.capsuleQueue.current?.title == "While you were in quiet mode")
        #expect(toy.capsuleQueue.current?.subtitle == "1 quota reset")
    }

    @Test("with the switch off, a Focus holds nothing")
    func switchOff() throws {
        let (toy, store, core) = makeToy(hold: false)
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"dim","source":"focus"}"#)
        toy.noteQuietChange()
        toy.offer(news(.completed, id: "c"))
        #expect(toy.activeCapsule?.id == "c")
        #expect(toy.capsuleQueue.held.isEmpty)
    }

    @Test("an old settings file without the key holds by default")
    func decodesDefault() throws {
        let settings = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(settings.holdNewsWhileQuiet)
    }
}
