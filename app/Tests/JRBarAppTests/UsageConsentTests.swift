import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Usage is off until the person turns that provider on, one provider at a
/// time. These cover what the app does with the daemon's words: the
/// `usage_consent` block on a provider row, the "usage off" card state, and
/// the Setup question, which asks nothing of any provider until "Turn on".
@MainActor
@Suite("Usage consent in the app")
struct UsageConsentTests {
    private func row(_ json: String) throws -> ProviderRow {
        try JSONDecoder().decode(ProviderRow.self, from: Data(json.utf8))
    }

    @Test("a row carries the switch and the daemon's words for it")
    func rowDecodesTheSwitch() throws {
        let decoded = try row(#"""
        {"id":"claude","label":"Claude","usage_consent":{"granted":false,"version":0,"source":null,
         "question":"Show Claude usage?",
         "summary":"JR-Bar will ask Anthropic for your usage with the sign-in Claude Code already has. Nothing else is sent.",
         "detail":"Asks api.anthropic.com for your windows. Nothing else is sent.",
         "hosts":["api.anthropic.com"],"credential":"the sign-in Claude Code already has"}}
        """#)
        let consent = try #require(decoded.usageConsent)
        #expect(!consent.granted)
        #expect(consent.question == "Show Claude usage?")
        #expect(consent.hosts == ["api.anthropic.com"])
        #expect(consent.summary.hasSuffix("Nothing else is sent."))
    }

    @Test("a daemon that predates the switch gives a row with none, so the app offers nothing")
    func olderDaemonHasNoSwitch() throws {
        #expect(try row(#"{"id":"claude","label":"Claude"}"#).usageConsent == nil)
    }

    @Test("a malformed switch reads as off, never as on")
    func malformedSwitchIsOff() throws {
        let decoded = try row(#"{"id":"claude","usage_consent":{"granted":"yes","version":"1"}}"#)
        #expect(decoded.usageConsent?.granted == false)
    }

    @Test("a card is 'usage off' only for the daemon's reason word")
    func usageOffCard() {
        let off = CoreProviderUsage(id: "claude", state: "needs_consent",
                                    action: "Turn on Claude usage", reason: "usage_not_turned_on")
        #expect(off.usageIsOff)
        #expect(!off.isSignedOut)
        #expect(!off.offersSignInFix, "there is nothing to sign in to until the person turns it on")
        let consent = CoreProviderUsage(id: "cursor", state: "needs_consent", reason: "browser_consent_required")
        #expect(!consent.usageIsOff)
        #expect(PanelStore.quietWord(off) == "usage off")
        #expect(PanelStore.quietWord(consent) == "needs consent")
    }

    // MARK: Setup

    final class Recorder {
        var offers: [SetupUsageOffer] = []
        var turnedOn: [String] = []
        var turnedOff: [String] = []
        var answer = SetupNote("Usage on", isError: false)
    }

    private func claude(on: Bool = false) -> SetupUsageOffer {
        SetupUsageOffer(
            id: "claude", name: "Claude", question: "Show Claude usage?",
            summary: "JR-Bar will ask Anthropic for your usage with the sign-in Claude Code already has. Nothing else is sent.",
            isOn: on)
    }

    private func cursor() -> SetupUsageOffer {
        SetupUsageOffer(
            id: "cursor", name: "Cursor", question: "Show Cursor usage?",
            summary: "JR-Bar will ask Cursor for your plan usage with the sign-in the Cursor app already has. Nothing else is sent.",
            isOn: false)
    }

    private func store(_ recorder: Recorder) -> SetupStore {
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { recorder.offers }
        model.setUsage = { provider, on in
            if on { recorder.turnedOn.append(provider) } else { recorder.turnedOff.append(provider) }
            return recorder.answer
        }
        return SetupStore(model: model, load: { SetupState() }, persist: { _ in })
    }

    @Test("Setup asks about each detected provider on its own and turns nothing on by itself")
    func setupAsksPerProvider() async {
        let recorder = Recorder()
        recorder.offers = [claude(), cursor()]
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        #expect(setup.usageOffers.map(\.id) == ["claude", "cursor"])
        #expect(setup.usageOffers.allSatisfy { !$0.isOn })
        #expect(recorder.turnedOn.isEmpty && recorder.turnedOff.isEmpty, "opening the question asks nothing")
        #expect(setup.usageOffer(for: "claude")?.question == "Show Claude usage?")
        #expect(setup.usageOffer(for: "gemini") == nil, "a provider that was not found is not asked about")
    }

    @Test("Turn on changes exactly its own provider")
    func turnOnIsPerProvider() async {
        let recorder = Recorder()
        recorder.offers = [claude(), cursor()]
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        await setup.turnOnUsage(for: "claude")?.value
        #expect(recorder.turnedOn == ["claude"])
        #expect(setup.usageOffer(for: "claude")?.isOn == true)
        #expect(setup.usageOffer(for: "cursor")?.isOn == false)
        #expect(setup.usageChoices["claude"] == .on)
        #expect(setup.usageChoices["cursor"] == nil)
    }

    @Test("Not now asks nothing, sends nothing and leaves the provider off")
    func notNowSendsNothing() async {
        let recorder = Recorder()
        recorder.offers = [claude(), cursor()]
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        setup.declineUsage(for: "cursor")
        #expect(setup.usageChoices["cursor"] == .notNow)
        #expect(setup.usageOffer(for: "cursor")?.isOn == false)
        #expect(recorder.turnedOn.isEmpty && recorder.turnedOff.isEmpty)
    }

    @Test("a provider that is already on can be turned off from the same row")
    func turnOffFromSetup() async {
        let recorder = Recorder()
        recorder.offers = [claude(on: true)]
        recorder.answer = SetupNote("Usage off", isError: false)
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        #expect(setup.usageChoices["claude"] == .on, "an earlier yes is remembered")
        setup.declineUsage(for: "claude")
        #expect(setup.usageChoices["claude"] == .on, "Not now never withdraws a yes")
        await setup.turnOffUsage(for: "claude")?.value
        #expect(recorder.turnedOff == ["claude"])
        #expect(setup.usageOffer(for: "claude")?.isOn == false)
    }

    @Test("a refused write shows the daemon's words and leaves the provider off")
    func refusedWriteStaysOff() async {
        let recorder = Recorder()
        recorder.offers = [claude()]
        recorder.answer = SetupNote("settings_changed", isError: true)
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        await setup.turnOnUsage(for: "claude")?.value
        #expect(setup.usageOffer(for: "claude")?.isOn == false)
        #expect(setup.usageChoices["claude"] == nil)
        #expect(setup.usageNotes["claude"]?.text == "settings_changed")
    }

    @Test("a second tap while the write is in flight does not stack")
    func noStackedWrites() async {
        let recorder = Recorder()
        recorder.offers = [claude()]
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        let first = setup.turnOnUsage(for: "claude")
        #expect(setup.turnOnUsage(for: "claude") == nil)
        await first?.value
        #expect(recorder.turnedOn == ["claude"])
    }

    @Test("the Done step says which providers show usage, and that the rest stay off")
    func doneStepNamesUsage() async throws {
        let recorder = Recorder()
        recorder.offers = [claude(on: true), cursor()]
        let setup = store(recorder)
        await setup.refreshUsageOffers()
        let line = try #require(setup.summaryRows.first { $0.text == "Usage" })
        #expect(line.detail.hasPrefix("On for Claude."))
        #expect(line.ok)

        recorder.offers = [claude(), cursor()]
        let none = store(recorder)
        await none.refreshUsageOffers()
        let off = try #require(none.summaryRows.first { $0.text == "Usage" })
        #expect(off.detail.hasPrefix("Off for every provider"))
        #expect(!off.ok)
    }
}
