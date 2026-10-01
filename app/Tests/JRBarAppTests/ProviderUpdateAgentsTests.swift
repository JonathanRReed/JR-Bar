import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings › Agents' Update button and "Check for agent updates" switch, and the Usage
/// Center's Fix sign-in: the words they show, the key the switch writes (off until
/// turned on), and that nothing here runs by itself.
@Suite struct ProviderUpdateAgentsTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appending(path: name), encoding: .utf8)
    }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: the update line

    @Test func theLineNamesTheInstalledVersionAndANewerOneWhenKnown() {
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: nil) == "v2.1.285")
        #expect(ProviderUpdateWords.versionLine(installed: nil, status: nil) == nil)
        let available = ProviderUpdateStatus(phase: .idle, latestVersion: "2.1.290")
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: available) == "v2.1.285 · 2.1.290 available")
        // No check, no claim: a status without a newer version says nothing about one.
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: ProviderUpdateStatus()) == "v2.1.285")
        // While it runs, and once it has finished, the row does not still say "available".
        let running = ProviderUpdateStatus(phase: .running, latestVersion: "2.1.290")
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: running) == "v2.1.285")
        let done = ProviderUpdateStatus(phase: .updated, fromVersion: "2.1.285", toVersion: "2.1.290", latestVersion: "2.1.290")
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: done) == "v2.1.290",
                "a run that just finished names what it installed, before the doctor is read again")
    }

    @Test func theVersionIsNotSaidTwiceWhenTheHookLineAboveHasIt() {
        let available = ProviderUpdateStatus(phase: .idle, latestVersion: "2.1.290")
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: available, includeInstalled: false)
                == "2.1.290 available")
        #expect(ProviderUpdateWords.versionLine(installed: "2.1.285", status: nil, includeInstalled: false) == nil)

        var hooked = HooksDoctorEntry(provider: "claude", installed: true, hookEvents: 12)
        #expect(!HooksDoctor.lineShowsVersion(hooked), "no version read: nothing above says it")
        hooked.version = "2.1.285"
        #expect(HooksDoctor.lineShowsVersion(hooked))
        var unhooked = HooksDoctorEntry(provider: "claude", installed: false)
        unhooked.version = "2.1.285"
        #expect(!HooksDoctor.lineShowsVersion(unhooked), "no hook line is drawn, so the update line says the version")
    }

    @Test func theResultIsTheDaemonsSentenceWhileItIsWorthShowing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func status(_ phase: ProviderUpdatePhase, _ message: String, finished: Double? = nil) -> ProviderUpdateStatus {
            ProviderUpdateStatus(phase: phase, message: message, finishedAt: finished)
        }
        #expect(ProviderUpdateWords.resultLine(nil, now: now) == nil)
        #expect(ProviderUpdateWords.resultLine(status(.idle, "x"), now: now) == nil)
        #expect(ProviderUpdateWords.resultLine(status(.running, "Updating Claude Code…"), now: now) == "Updating Claude Code…")
        // Success fades after ten minutes; a failure, or a terminal waiting for you, stays.
        let recent = now.timeIntervalSince1970 - 60
        let old = now.timeIntervalSince1970 - 3600
        #expect(ProviderUpdateWords.resultLine(status(.updated, "Updated 2.1.285 to 2.1.290", finished: recent), now: now)
                == "Updated 2.1.285 to 2.1.290")
        #expect(ProviderUpdateWords.resultLine(status(.updated, "Updated 2.1.285 to 2.1.290", finished: old), now: now) == nil)
        #expect(ProviderUpdateWords.resultLine(status(.unchanged, "Already up to date (2.1.285)", finished: old), now: now) == nil)
        #expect(ProviderUpdateWords.resultLine(status(.failed, "Codex's updater failed (exit 1)", finished: old), now: now)
                == "Codex's updater failed (exit 1)")
        #expect(ProviderUpdateWords.resultLine(status(.needsTerminal, "Devin's updater needs a terminal", finished: old), now: now)
                == "Devin's updater needs a terminal")
        #expect(ProviderUpdateWords.resultLine(status(.failed, ""), now: now) == nil)
    }

    @Test func updateIsOfferedOnlyWhereTheDaemonHasAnUpdater() {
        for provider in ["claude", "codex", "grok", "devin", "opencode"] {
            #expect(ProviderUpdateWords.hasUpdater(provider), "\(provider) has an updater")
            #expect(ProviderUpdateWords.isRelevant(provider))
        }
        // Gemini CLI has none: its row carries the advice and no button.
        #expect(!ProviderUpdateWords.hasUpdater("gemini"))
        #expect(ProviderUpdateWords.isRelevant("gemini"))
        #expect(ProviderUpdateWords.geminiAdvice.contains("brew upgrade gemini-cli"))
        #expect(ProviderUpdateWords.geminiAdvice.contains("npm install -g @google/gemini-cli"))
        for provider in ["cursor", "antigravity", "pi", "hermes", "kiro", "openclaw", "claude; rm -rf ~"] {
            #expect(!ProviderUpdateWords.hasUpdater(provider))
            #expect(!ProviderUpdateWords.isRelevant(provider))
        }
    }

    @Test func theButtonIsPressableOnlyWhenLiveAndNothingIsRunning() {
        let running = ProviderUpdateStatus(phase: .running)
        #expect(ProviderUpdateWords.canUpdate(provider: "claude", status: nil, live: true, busy: false))
        #expect(ProviderUpdateWords.canUpdate(provider: "claude", status: ProviderUpdateStatus(phase: .failed), live: true, busy: false))
        #expect(!ProviderUpdateWords.canUpdate(provider: "claude", status: nil, live: false, busy: false))
        #expect(!ProviderUpdateWords.canUpdate(provider: "claude", status: nil, live: true, busy: true))
        #expect(!ProviderUpdateWords.canUpdate(provider: "claude", status: running, live: true, busy: false))
        #expect(!ProviderUpdateWords.canUpdate(provider: "gemini", status: nil, live: true, busy: false))
    }

    // MARK: the switch

    @Test func theKeyIsAnAgentsSwitchTheDaemonServes() {
        let key = SettingsKey.all.first { $0.path == "provider_update_checks_enabled" }
        #expect(key?.page == .agents)
        #expect(key?.kind == .bool)
        // A page reset writes the daemon's default back, which is off.
        let document = SettingsDocument(.object(["provider_update_checks_enabled": .bool(true)]))
        #expect(SettingsKey.resetPaths(on: .agents, in: document).contains("provider_update_checks_enabled"))
    }

    @Test func thePageBindsThatKeyAndDoesNotDefaultItOn() throws {
        let page = try source("SettingsPagesA.swift")
        #expect(page.contains("path: \"provider_update_checks_enabled\""))
        #expect(!page.contains("path: \"provider_update_checks_enabled\", default: true"))
        #expect(page.contains("subtitle: ProviderUpdateChecksCopy.subtitle"))
    }

    @Test func theWordsNameTheHostAndSayItIsOffUntilTurnedOn() {
        let words = ProviderUpdateChecksCopy.subtitle
        #expect(words.contains("registry.npmjs.org"))
        #expect(words.contains("every 6 hours"))
        #expect(words.contains("Off by default"))
        #expect(words.contains("nothing is contacted until you turn it on"))
        let row = SettingsSearch.rows.first { $0.title == "Check for agent updates" }
        #expect(row?.subtitle == words, "the search index shares the page's words")
        #expect(row?.page == .agents)
    }

    // MARK: nothing runs by itself

    @Test func anUpdateRunsOnlyFromTheRowsButton() throws {
        let store = try source("SettingsStore.swift")
        let doctor = try source("AgentsHooksDoctor.swift")
        let page = try source("SettingsPagesA.swift")
        // The definition and the one button: nothing starts an updater on appear, on a timer or from a setting.
        #expect(count(of: "updateProvider(", in: store) == 2, "the store's method and its call to the core")
        #expect(count(of: "store.updateProvider(", in: doctor) == 1)
        #expect(count(of: "updateProvider(", in: page) == 0)
        // The only thing the page sends on its own is the check, which the daemon gates on the setting.
        #expect(count(of: "checkProviderUpdates()", in: page) == 3)
        #expect(!page.contains("signInProvider("))
    }

    // MARK: Fix sign-in

    @Test func aFixSignInReplyIsShownAsTheDaemonSaidIt() {
        let opened = ProviderSignInResult(
            provider: "grok", outcome: .openedTerminal,
            message: "Opened Ghostty on `grok login`: finish signing in there, JR-Bar notices on its own.",
            command: "grok login")
        let note = UsageCenterStore.signInNote(for: opened)
        #expect(note.text == opened.message)
        #expect(note.needsPerson)

        let renewed = ProviderSignInResult(provider: "claude", outcome: .renewed,
                                           message: "Claude Code renewed its sign-in, so Claude usage is refreshing now.")
        #expect(!UsageCenterStore.signInNote(for: renewed).needsPerson)
        #expect(UsageCenterStore.signInNote(for: ProviderSignInResult(provider: "codex", outcome: .alreadyOK, message: "  ")).text
                == "Checked codex's sign-in.")
    }

    @Test func fixSignInReplacesTheDeadLookingButtonsAndNeverRunsOnOpen() throws {
        let view = try source("UsageCenterView.swift")
        let store = try source("UsageCenterStore.swift")
        // The card with a sign-in problem leads with the one button: in the manage row's controls, in the
        // signed-out card, and on the combined card's signed-out row.
        #expect(count(of: "FixSignInButton(provider: provider, store: store)", in: view) == 3)
        #expect(count(of: "ProviderFixControls(provider: provider, store: store)", in: view) == 1)
        #expect(view.contains("if provider.offersSignInFix"))
        // The daemon's own fix-it is words beside it, not the action.
        #expect(view.contains("Text(action)"))
        // The sign-in command is sent from the click's method and nowhere else.
        #expect(count(of: "core.signInProvider(", in: store) == 1)
        #expect(count(of: "store.fixSignIn(provider)", in: view) == 1)
        #expect(!view.contains(".task { store.fixSignIn"))
        #expect(!view.contains(".onAppear { store.fixSignIn"))
        // It says words, and it can be heard.
        #expect(view.contains("accessibilityLabel(store.isFixingSignIn(provider)"))
    }

    @Test func theHelpNamesOnlyWhatTheDaemonDoesForEachProvider() {
        #expect(FixSignInButton.help(for: "claude").contains("renew its own sign-in"))
        #expect(FixSignInButton.help(for: "grok").contains("grok login"))
        #expect(FixSignInButton.help(for: "codex").contains("codex login"))
        #expect(FixSignInButton.help(for: "opencode").contains("opencode providers login"))
        #expect(FixSignInButton.help(for: "devin").contains("app.devin.ai"))
        #expect(!FixSignInButton.help(for: "cursor").isEmpty)
    }
}
