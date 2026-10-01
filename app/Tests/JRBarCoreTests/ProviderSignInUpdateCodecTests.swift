import Foundation
import Testing
@testable import JRBarCore

/// What the app does with `provider_sign_in`, `provider_update` and
/// `state.provider_updates`: tolerant decoding (an absent key is unknown, an
/// unknown phase or outcome is the plain default), and the exact args that
/// go on the wire, which are only ever a provider, its instance and a terminal.
@Suite("Provider sign-in and updates, decoded")
struct ProviderSignInUpdateCodecTests {
    private func state(_ body: String) throws -> CoreState {
        let frame = Data(#"{"t":"state","v":1,"generation":7\#(body)}"#.utf8)
        guard case .state(let state) = try CoreCodec.decode(frame: frame) else {
            Issue.record("not a state"); throw CoreCodecError.malformed("not a state")
        }
        return state
    }

    @Test("the state carries what each updater last did")
    func providerUpdates() throws {
        let decoded = try state(#"""
        ,"provider_updates":{
          "grok":{"phase":"updated","from_version":"1.0.44","to_version":"1.0.46","latest_version":null,
                  "message":"Updated 1.0.44 to 1.0.46","finished_at":1788982800.5},
          "claude":{"phase":"idle","from_version":null,"to_version":null,"latest_version":"2.1.290",
                    "message":"","finished_at":null},
          "devin":{"phase":"needs_terminal","message":"Devin's updater needs a terminal."}
        }
        """#)

        let grok = try #require(decoded.providerUpdates["grok"])
        #expect(grok.phase == .updated)
        #expect(grok.fromVersion == "1.0.44")
        #expect(grok.toVersion == "1.0.46")
        #expect(grok.latestVersion == nil)
        #expect(grok.message == "Updated 1.0.44 to 1.0.46")
        #expect(grok.finishedAt == 1788982800.5)
        let claude = try #require(decoded.providerUpdates["claude"])
        #expect(claude.phase == .idle)
        #expect(claude.latestVersion == "2.1.290")
        #expect(claude.updateAvailable)
        #expect(decoded.providerUpdates["devin"]?.phase == .needsTerminal)
        #expect(decoded.providerUpdates["devin"]?.fromVersion == nil)
    }

    @Test("an absent key is unknown, not an error")
    func absent() throws {
        #expect(try state("").providerUpdates.isEmpty)
        #expect(try state(#","provider_updates":{}"#).providerUpdates.isEmpty)
        // The wrong shape costs the key, never the state.
        let broken = try state(#","provider_updates":[1,2]"#)
        #expect(broken.providerUpdates.isEmpty)
        #expect(broken.generation == 7)
    }

    @Test("one bad entry is one provider with nothing to say")
    func tolerant() throws {
        let decoded = try state(#"""
        ,"provider_updates":{
          "codex":"surprise",
          "grok":{"phase":"someday","message":7},
          "opencode":{"phase":"running","message":"Updating OpenCode…"}
        }
        """#)

        #expect(decoded.providerUpdates["codex"] == nil)
        // An unknown phase reads as idle, a message of the wrong type as none.
        let grok = try #require(decoded.providerUpdates["grok"])
        #expect(grok.phase == .idle)
        #expect(grok.message == "")
        let opencode = try #require(decoded.providerUpdates["opencode"])
        #expect(opencode.isRunning)
        #expect(!opencode.updateAvailable)
        #expect(decoded.generation == 7)
    }

    @Test("a state with updates survives an encode and decode")
    func roundTrip() throws {
        let original = CoreState(generation: 3, providerUpdates: [
            "claude": ProviderUpdateStatus(phase: .updated, fromVersion: "2.1.285", toVersion: "2.1.290",
                                           message: "Updated 2.1.285 to 2.1.290", finishedAt: 5),
        ])

        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(CoreState.self, from: data)

        #expect(again.providerUpdates == original.providerUpdates)
    }

    @Test("a sign-in reply keeps what it says and reads an unknown outcome as unavailable")
    func signInReply() {
        let renewed = ProviderSignInResult(
            .object([
                "provider": .string("claude"), "instance": .string("default"), "outcome": .string("renewed"),
                "message": .string("Claude Code renewed its sign-in, so Claude usage is refreshing now."),
                "command": .null, "sign_in_url": .null,
            ]), provider: "claude")
        #expect(renewed.outcome == .renewed)
        #expect(!renewed.outcome.needsPerson)
        #expect(renewed.command == nil)

        let opened = ProviderSignInResult(
            .object([
                "outcome": .string("opened_terminal"), "command": .string("grok login"),
                "message": .string("Opened Ghostty on `grok login`: finish signing in there, JR-Bar notices on its own."),
            ]), provider: "grok")
        #expect(opened.outcome == .openedTerminal)
        #expect(opened.outcome.needsPerson)
        #expect(opened.command == "grok login")
        #expect(opened.provider == "grok", "a reply that forgets the provider keeps the one asked about")
        #expect(opened.instance == "default")

        let strange = ProviderSignInResult(.object(["outcome": .string("teleported"), "message": .string("x")]),
                                           provider: "codex")
        #expect(strange.outcome == .unavailable)
        #expect(ProviderSignInResult(nil, provider: "codex").message == "")
        #expect(ProviderSignInResult(.object(["outcome": .string("already_ok")]), provider: "x").outcome == .alreadyOK)
        // A staged action's sentence is information, and the token page it names rides along to be opened.
        let staged = ProviderSignInResult(
            .object(["outcome": .string("staged"), "message": .string("The stored Devin session was rejected and has been cleared."),
                     "sign_in_url": .string("https://app.devin.ai/settings/api-keys")]),
            provider: "devin")
        #expect(staged.outcome == .staged)
        #expect(!staged.outcome.needsPerson)
        #expect(staged.signInURL == "https://app.devin.ai/settings/api-keys")
        #expect(!ProviderSignInOutcome.alreadyOK.needsPerson)
        #expect(ProviderSignInOutcome.failed.needsPerson)
    }

    @Test("an update start is a plain refusal to show, not an error")
    func updateStart() {
        let started = ProviderUpdateStart(
            .object(["provider": .string("claude"), "started": .bool(true), "message": .string("Updating Claude Code…")]),
            provider: "claude")
        #expect(started.started)
        #expect(started.reason == nil)

        let refused = ProviderUpdateStart(
            .object(["started": .bool(false), "reason": .string("no_updater"), "message": .string("Gemini CLI has no updater of its own")]),
            provider: "gemini")
        #expect(!refused.started)
        #expect(refused.reason == "no_updater")
        #expect(refused.provider == "gemini")
        #expect(!ProviderUpdateStart(nil, provider: "x").started, "no answer is not a start")
    }

    @Test("sign-in puts only a provider, an instance and a terminal on the wire")
    func signInArgs() {
        #expect(CoreModel.signInArgs(provider: "grok") == ["provider": .string("grok")])
        #expect(CoreModel.signInArgs(provider: "claude", instance: "default") == ["provider": .string("claude")])
        #expect(CoreModel.signInArgs(provider: "claude", instance: "work", terminal: "com.mitchellh.ghostty") == [
            "provider": .string("claude"), "instance": .string("work"), "terminal": .string("com.mitchellh.ghostty"),
        ])
        #expect(CoreModel.signInArgs(provider: "grok", instance: "", terminal: "") == ["provider": .string("grok")])
        let keys = Set(CoreModel.signInArgs(provider: "x", instance: "y", terminal: "z").keys)
        #expect(keys.isDisjoint(with: ["command", "argv", "args", "executable", "shell"]))
        // A person waits on a Claude renewal the daemon allows 90 seconds.
        #expect(CoreModel.signInReplyTimeout > 90)
    }

    @Test("a card whose problem is a sign-in offers Fix sign-in, and no other does")
    func offersSignInFix() {
        #expect(CoreProviderUsage(id: "grok", state: "needs_sign_in", action: "Run grok login").offersSignInFix)
        #expect(CoreProviderUsage(id: "cursor", state: "not_signed_in").offersSignInFix)
        // The owner's Claude: stale, because the copy of the sign-in expired.
        #expect(CoreProviderUsage(id: "claude", state: "stale", action: "Reconnect Claude",
                                  reason: "authentication_required").offersSignInFix)
        #expect(!CoreProviderUsage(id: "claude", state: "ready").offersSignInFix)
        #expect(!CoreProviderUsage(id: "codex", state: "stale", action: "Retry", reason: "local_reading_stale").offersSignInFix)
        #expect(!CoreProviderUsage(id: "devin", state: "needs_consent", action: "Enable Devin browser access",
                                   reason: "browser_access_required").offersSignInFix)
        #expect(!CoreProviderUsage(id: "gemini", state: "rate_limited", action: "Retry later").offersSignInFix)
    }
}
