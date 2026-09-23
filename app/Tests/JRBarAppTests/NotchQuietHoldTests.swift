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
        // The Mac named the Focus on its way in; the daemon synced it.
        toy.noteMacFocus(name: "Work", on: true)
        try quiet(core, #"{"mode":"dim","source":"focus"}"#)
        toy.noteQuietChange()
        toy.offer(news(.completed, id: "a"))
        toy.offer(news(.completed, id: "b"))
        #expect(toy.capsuleQueue.held.count == 2)

        try quiet(core, #"{"mode":"off"}"#)
        toy.noteQuietChange()
        #expect(toy.capsuleQueue.held.count == 2, "the Mac's Focus is still on")
        toy.noteMacFocus(name: "Focus", on: false)
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

    @Test("the Mac's own Focus holds on a Mac whose daemon never syncs it")
    func macFocusAlone() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"off"}"#)
        toy.noteMacFocus(name: "Reading", on: true)
        #expect(toy.quietContext == "Reading")
        toy.offer(news(.completed, id: "c"))
        #expect(toy.activeCapsule == nil)
        toy.noteMacFocus(name: "Reading", on: false)
        #expect(toy.capsuleQueue.current?.title == "While you were in Reading")
        #expect(toy.capsuleQueue.current?.session == "claude:c", "one run: a tap opens it")
    }

    @Test("a Focus ending under the grown card keeps its summary for the fold")
    func endUnderCardReplaysOnFold() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"off"}"#)
        toy.noteMacFocus(name: "Work", on: true)
        toy.offer(news(.completed, id: "c"))
        #expect(toy.capsuleQueue.held.count == 1)

        // Control Center ends the Focus while the card is up: the
        // summary would have been offered under the card, then
        // cancelled as an orphan by the fold.
        toy.expandFromBand()
        toy.noteMacFocus(name: "Work", on: false)
        #expect(toy.capsuleQueue.held.count == 1, "the hold waits for a voice")
        #expect(toy.capsuleQueue.current == nil)

        toy.collapseFromBand()
        #expect(toy.capsuleQueue.held.isEmpty)
        #expect(toy.activeCapsule?.title == "While you were in Work")
        #expect(toy.activeCapsule?.subtitle == "1 finished")
    }

    @Test("a Focus ending while the island is hidden replays once it shows")
    func endWhileHiddenWaits() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        try quiet(core, #"{"mode":"off"}"#)
        toy.noteMacFocus(name: "Work", on: true)
        toy.offer(news(.completed, id: "c"))
        toy.islandVisible = false
        toy.noteMacFocus(name: "Work", on: false)
        #expect(toy.capsuleQueue.held.count == 1)
        toy.islandVisible = true
        toy.noteQuietChange()
        #expect(toy.capsuleQueue.current?.title == "While you were in Work")
    }

    @Test("a Focus turning on says good news will wait, only while the hold is on")
    func focusSaysPolicy() {
        let on = NotchAnnouncements.focusNotice(name: "Work", on: true)
        #expect(NotchToy.focusPolicyNotice(on, holding: true).subtitle == "Focus on · news waits")
        #expect(NotchToy.focusPolicyNotice(on, holding: false).subtitle == "Focus on")
        let off = NotchAnnouncements.focusNotice(name: "Work", on: false)
        #expect(NotchToy.focusPolicyNotice(off, holding: true).subtitle == "Focus off")
        let display = NotchAnnouncements.displayNotice(connected: true)
        #expect(NotchToy.focusPolicyNotice(display, holding: true) == display)
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
