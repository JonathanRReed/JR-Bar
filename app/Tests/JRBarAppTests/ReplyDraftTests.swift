import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// W15: reply drafts are interruption-safe — a half-typed answer is
/// keyed by the ask's request id, persists across a "relaunch" (a second
/// store on the same defaults), and only clears on a confirmed send.
/// Mini is the same toy wearing a pill: the setting round-trips through
/// `presentation` and unknown words read as the character.
@Suite("Reply drafts + Mini")
@MainActor
struct ReplyDraftTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "jrbar.tests.drafts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func ask(request: String? = "req-1", summary: String = "allow?") -> CoreAsk {
        CoreAsk(session: "s1", kind: "permission", openedAt: 100, summary: summary,
                answerable: true, replyable: true, request: request)
    }

    @Test("a draft survives a fresh store — the relaunch case")
    func draftsSurviveRelaunch() {
        let defaults = freshDefaults()
        let a = ask()
        let first = PanelStore(core: CoreModel(), draftsDefaults: defaults)
        first.setReplyDraft("yes, but only for this repo", for: a)

        let second = PanelStore(core: CoreModel(), draftsDefaults: defaults)
        #expect(second.replyDraft(for: a) == "yes, but only for this repo")
    }

    @Test("drafts key by request id; distinct asks don't share text")
    func draftsKeyByRequest() {
        let store = PanelStore(core: CoreModel(), draftsDefaults: freshDefaults())
        let a = ask(request: "req-1")
        let b = ask(request: "req-2", summary: "other?")
        store.setReplyDraft("first", for: a)
        store.setReplyDraft("second", for: b)
        #expect(store.replyDraft(for: a) == "first")
        #expect(store.replyDraft(for: b) == "second")
        // An ask with no request id keys on its own id instead.
        let c = ask(request: nil, summary: "third?")
        store.setReplyDraft("third", for: c)
        #expect(store.replyDraft(for: c) == "third")
    }

    @Test("an empty write clears the draft — send confirmation uses it")
    func emptyClearsDraft() {
        let store = PanelStore(core: CoreModel(), draftsDefaults: freshDefaults())
        let a = ask()
        store.setReplyDraft("half typed", for: a)
        store.setReplyDraft("", for: a)
        #expect(store.replyDraft(for: a) == "")
    }

    @Test("the store stays bounded — the oldest draft drops first")
    func draftsBounded() {
        let defaults = freshDefaults()
        let store = PanelStore(core: CoreModel(), draftsDefaults: defaults)
        for i in 0...55 {
            store.setReplyDraft("draft \(i)", for: ask(request: "req-\(i)"))
        }
        // 56 writes into a 50-cap store: the earliest six are gone.
        #expect(store.replyDraft(for: ask(request: "req-0")) == "")
        #expect(store.replyDraft(for: ask(request: "req-5")) == "")
        #expect(store.replyDraft(for: ask(request: "req-55")) == "draft 55")
    }

    @Test("mini mode writes `presentation`; the toggle reads it back")
    func miniModeRoundTrips() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState())
        let toy = store.notchBuddy
        #expect(toy.miniMode == false)
        toy.presentationBinding.wrappedValue = true
        #expect(store.state.notchBuddy.presentation == "mini")
        #expect(toy.miniMode == true)
        toy.presentationBinding.wrappedValue = false
        #expect(store.state.notchBuddy.presentation == "character")
    }

    @Test("an unknown presentation word reads as the character, not mini")
    func unknownPresentationIsCharacter() throws {
        let json = #"{"enabled":true,"presentation":"hologram"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(NotchBuddySettings.self, from: json)
        #expect(settings.presentation == "hologram")  // kept raw for a newer build
        #expect(settings.miniMode == false)
        #expect(settings.resolvedCharacter == .dot)   // absent character falls back
    }
}
