import AppKit
import Foundation
import Testing
import JRBarCore
import JRBarUI
@testable import JRBarApp

/// The walkthrough's rules: step order and skip bounds, how each step's
/// outcome is recorded, the launch gate, and the permission/agents row
/// mappings — all against an injected `SetupModel`, so no test touches
/// TCC, EventKit, UserNotifications or a socket.
@MainActor
@Suite struct SetupStoreTests {
    /// Records everything the store sends through the model and the
    /// persist closure.
    final class Recorder {
        var persisted: [SetupState] = []
        var installed: [String] = []
        var acted: [SetupPermission] = []
        var installResult = SetupNote("Hooks installed", isError: false)
        var screenBarSets: [Bool] = []
        var iconStyleSets: [String] = []
        var screenBar = true
        var iconStyle = StatusIconStyle.agents.rawValue
        var agents: [SetupAgent] = []
        var statuses: [SetupPermission: SetupPermissionStatus] = [:]
        var live = true
    }

    func make(initialState: SetupState = SetupState(),
              configure: (SetupStore, Recorder) -> Void = { _, _ in }) -> (SetupStore, Recorder) {
        let recorder = Recorder()
        var model = SetupModel()
        model.monitorLive = { recorder.live }
        model.agents = { recorder.agents }
        model.installHooks = { provider in
            recorder.installed.append(provider)
            return recorder.installResult
        }
        model.refreshPermissions = { recorder.statuses }
        model.act = { recorder.acted.append($0) }
        model.screenBarShown = { recorder.screenBar }
        model.setScreenBar = { recorder.screenBar = $0; recorder.screenBarSets.append($0) }
        model.iconStyle = { recorder.iconStyle }
        model.setIconStyle = { recorder.iconStyle = $0; recorder.iconStyleSets.append($0) }
        let store = SetupStore(model: model,
                               load: { initialState },
                               persist: { recorder.persisted.append($0) })
        configure(store, recorder)
        return (store, recorder)
    }

    // MARK: Navigation

    @Test func stepsAdvanceInOrder() {
        let (store, _) = make()
        #expect(store.step == .welcome)
        #expect(!store.canGoBack)
        #expect(store.nextTitle == "Get Started")
        store.goNext()
        #expect(store.step == .agents)
        store.goNext()
        #expect(store.step == .permissions)
        store.goNext()
        #expect(store.step == .appearance)
        store.goNext()
        #expect(store.step == .done)
        #expect(store.nextTitle == "Finish")
    }

    @Test func backStopsAtWelcome() {
        let (store, _) = make()
        store.goBack()
        #expect(store.step == .welcome, "Back on the first step is a no-op")
        store.goNext()
        store.goNext()
        store.goBack()
        #expect(store.step == .agents)
        store.goBack()
        #expect(store.step == .welcome)
    }

    @Test func skipOnlyOnTheMiddleSteps() {
        let (store, _) = make()
        #expect(!store.canSkip, "Welcome's primary button is Get Started — nothing to skip")
        store.goNext()
        #expect(store.canSkip)
        store.skip()
        #expect(store.step == .permissions)
        #expect(store.skippedSteps == [.agents])
        store.goNext()
        #expect(store.step == .appearance)
        store.goNext()
        #expect(store.step == .done)
        #expect(!store.canSkip, "Done's primary button is Finish")
        store.skip()
        #expect(store.step == .done, "Skip on a non-skippable step is a no-op")
    }

    @Test func nextMarksCompletedSkipMarksSkippedAndLastOutcomeWins() {
        let (store, recorder) = make()
        store.goNext()                                   // welcome completed
        store.goNext()                                   // agents completed
        store.goBack()
        store.skip()                                     // agents re-left by Skip
        #expect(store.completedSteps == [.welcome])
        #expect(store.skippedSteps == [.agents])
        // Persisted on every transition, in step order.
        #expect(recorder.persisted.last?.completedSteps == ["welcome"])
        #expect(recorder.persisted.last?.skippedSteps == ["agents"])
    }

    @Test func finishStampsFinishedAtAndRunsOnFinished() {
        let (store, recorder) = make()
        var finished = false
        store.onFinished = { finished = true }
        store.goNext()
        store.goNext()
        store.goNext()
        store.goNext()                                   // lands on done
        store.goNext()                                   // done's primary = Finish
        #expect(finished)
        #expect(store.state.finishedAt != nil)
        #expect(store.completedSteps.contains(.done))
        #expect(recorder.persisted.last?.finishedAt != nil)
        #expect(!store.shouldPresentOnLaunch)
    }

    @Test func finishToToysFinishesAndOpensToys() {
        let (store, _) = make()
        var toys = false
        var finished = false
        store.onOpenToys = { toys = true }
        store.onFinished = { finished = true }
        store.finishToToys()
        #expect(finished)
        #expect(toys)
    }

    // MARK: Launch gate

    @Test func shouldPresentOnLaunchUntilFinishedOrPresentedTwice() {
        let (store, _) = make()
        #expect(store.shouldPresentOnLaunch)
        store.present()
        #expect(store.shouldPresentOnLaunch, "one mid-way dismissal is offered once more")
        store.present()
        #expect(!store.shouldPresentOnLaunch, "then it stops asking; Settings can still run it")
    }

    @Test func aFinishedRunNeverReArmsTheGate() {
        let (store, _) = make(initialState: SetupState(finishedAt: 100, presentedCount: 1))
        #expect(!store.shouldPresentOnLaunch)
        // A re-run of a finished setup starts over but keeps the stamp.
        store.present()
        #expect(store.step == .welcome)
        #expect(store.completedSteps.isEmpty)
        #expect(!store.shouldPresentOnLaunch)
    }

    // MARK: Permissions

    @Test func permissionActionMapping() {
        // A promptable row grants via the prompt until denied, then only
        // the pane can undo it.
        let notifications = SetupPermission.notifications
        #expect(notifications.action(for: .granted) == nil)
        #expect(notifications.action(for: .needed)?.title == "Grant…")
        #expect(notifications.action(for: .needed)?.opensSettings == false)
        #expect(notifications.action(for: .denied)?.title == "Open Settings…")
        #expect(notifications.action(for: .denied)?.opensSettings == true)
        #expect(notifications.action(for: .unavailable) == nil)
        // Grant-by-pane rows never promise a prompt.
        let accessibility = SetupPermission.accessibility
        #expect(accessibility.action(for: .needed)?.title == "Open Settings…")
        #expect(accessibility.action(for: .needed)?.opensSettings == true)
        #expect(accessibility.action(for: .granted) == nil)
        // Words beside the dots.
        #expect(SetupPermissionStatus.granted.word == "Granted")
        #expect(SetupPermissionStatus.needed.word == "Needed")
        #expect(SetupPermissionStatus.denied.word == "Denied")
        #expect(SetupPermissionStatus.unavailable.word == "Not available")
        #expect(SetupPermissionStatus.unknown.word == "Unknown")
    }

    @Test func theConsolidatedRowsSayWhatTheyAre() {
        // Automation and Location prompt; the closed-lid helper is no TCC
        // grant — its only action is copying the Terminal command.
        #expect(SetupPermission.automation.action(for: .unknown)?.title == "Grant…")
        #expect(SetupPermission.location.action(for: .needed)?.title == "Grant…")
        #expect(SetupPermission.location.action(for: .denied)?.opensSettings == true)
        #expect(SetupPermission.lidHelper.action(for: .needed)?.title == "Copy Command")
        #expect(SetupPermission.lidHelper.action(for: .unknown) == nil)
        #expect(SetupPermission.lidHelper.action(for: .granted) == nil)
    }

    @Test func theNewRowsReadTheirFactsHonestly() {
        #expect(SetupModel.automationStatus(.granted) == .granted)
        #expect(SetupModel.automationStatus(.needsConsent) == .needed)
        #expect(SetupModel.automationStatus(.denied) == .denied)
        // System Events not running: macOS cannot say yet.
        #expect(SetupModel.automationStatus(.unavailable) == .unknown)
        #expect(SetupModel.locationStatus(.authorizedAlways, servicesEnabled: true) == .granted)
        #expect(SetupModel.locationStatus(.notDetermined, servicesEnabled: true) == .needed)
        // Location Services off for the whole Mac: only the pane helps.
        #expect(SetupModel.locationStatus(.notDetermined, servicesEnabled: false) == .denied)
        #expect(SetupModel.lidHelperStatus(helperInstalled: true) == .granted)
        #expect(SetupModel.lidHelperStatus(helperInstalled: false) == .needed)
        #expect(SetupModel.lidHelperStatus(helperInstalled: nil) == .unknown)
    }

    @Test func theLidHelperCommandQuotesTheBundledCore() {
        #expect(SetupModel.lidHelperCommand(coreExecutable: nil) == "sudo jrbar status-bar install-sleep-helper")
        #expect(SetupModel.lidHelperCommand(
            coreExecutable: "/Users/j/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core")
                == "sudo '/Users/j/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core' status-bar install-sleep-helper")
        #expect(SetupModel.lidHelperCommand(coreExecutable: "/tmp/it's") == "sudo '/tmp/it'\\''s' status-bar install-sleep-helper")
    }

    @Test func permissionStatusesRefreshFromTheModel() async {
        let (store, recorder) = make()
        recorder.statuses = [.screenRecording: .granted, .notifications: .denied]
        await store.refreshPermissions()
        #expect(store.status(of: .screenRecording) == .granted)
        #expect(store.status(of: .notifications) == .denied)
        #expect(store.status(of: .calendar) == .unknown, "unprobed rows stay grey")
    }

    @Test func actRunsTheModelThenReProbes() async {
        let (store, recorder) = make()
        recorder.statuses = [.calendar: .needed]
        await store.refreshPermissions()
        // Granting flips the probe's answer; the row follows the model.
        let task = store.act(on: .calendar)
        recorder.statuses[.calendar] = .granted   // the "system" answered
        await task.value
        #expect(recorder.acted == [.calendar])
        #expect(store.status(of: .calendar) == .granted)
    }

    // MARK: Agents

    @Test func agentRowsFlattenHealthAndGateInstall() {
        let (store, recorder) = make()
        recorder.agents = [
            SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok"),
            SetupAgent(id: "codex", name: "Codex", detected: false, hookStatus: "missing"),
            SetupAgent(id: "gemini", name: "Gemini", detected: nil, hookStatus: nil),
        ]
        #expect(store.agentRows.map(\.id) == ["claude", "codex", "gemini"])
        #expect(store.agentRows[0].statusWord(monitorLive: true) == "Live")
        #expect(store.agentRows[1].statusWord(monitorLive: true) == "Not installed")
        #expect(store.agentRows[2].statusWord(monitorLive: true) == "Unknown")
        #expect(store.agentRows[2].statusWord(monitorLive: false) == "Monitor offline")
        #expect(store.canInstall(store.agentRows[0]), "live monitor + detected CLI")
        #expect(!store.canInstall(store.agentRows[1]), "no CLI found disables Install")
        recorder.live = false
        #expect(!store.canInstall(store.agentRows[0]), "an offline monitor disables Install")
    }

    @Test func installHooksShowsBusyThenTheReplyNote() async {
        let (store, recorder) = make()
        recorder.installResult = SetupNote("no CLI found on PATH", isError: true)
        let task = store.installHooks(for: "codex")
        #expect(task != nil)
        #expect(store.hookBusy.contains("codex"))
        await task?.value
        #expect(!store.hookBusy.contains("codex"))
        #expect(store.hookNotes["codex"] == SetupNote("no CLI found on PATH", isError: true))
        #expect(recorder.installed == ["codex"])
        #expect(store.installHooks(for: "codex") != nil)
    }

    // MARK: Appearance

    @Test func appearanceFactsMirrorThroughTheModel() {
        let (store, recorder) = make()
        recorder.screenBar = false
        recorder.iconStyle = "orbit"
        store.present()
        #expect(store.screenBarShown == false)
        #expect(store.menuBarIconStyle == "orbit")
        #expect(store.currentIconStyle == .orbit)
        store.screenBarShown = true
        store.menuBarIconStyle = StatusIconStyle.meters.rawValue
        #expect(recorder.screenBarSets == [true])
        #expect(recorder.iconStyleSets == ["meters"])
    }

    // MARK: Done summary

    @Test func summaryNamesWhatIsStillNeeded() async {
        let (store, recorder) = make()
        recorder.agents = [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")]
        recorder.statuses = [
            .notifications: .granted, .calendar: .granted, .screenRecording: .denied,
            .accessibility: .granted, .fullDiskAccess: .needed,
        ]
        await store.refreshPermissions()
        let rows = store.summaryRows
        #expect(rows.count == 3)
        let agents = rows.first { $0.text == "Agents" }
        #expect(agents?.ok == true)
        #expect(agents?.detail.contains("1 provider") == true)
        let permissions = rows.first { $0.text == "Permissions" }
        #expect(permissions?.ok == false)
        #expect(permissions?.detail.contains("Screen Recording") == true)
        #expect(permissions?.detail.contains("Full Disk Access") == true)
        #expect(permissions?.detail.contains("Notifications") == false)
        let appearance = rows.first { $0.text == "Menu bar & Screen Bar" }
        #expect(appearance?.detail.contains("Screen Bar on") == true)
    }
}

/// `setup.json`: the tolerant decode, the XDG-aware default location,
/// and the round-trip the launch gate reads.
@MainActor
@Suite struct SetupStateFileTests {
    @Test func roundTripThroughJSON() throws {
        let state = SetupState(completedSteps: ["welcome", "agents"],
                               skippedSteps: ["permissions"],
                               finishedAt: 1234.5, presentedCount: 2)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SetupState.self, from: data) == state)
    }

    @Test func tolerantDecodeFillsMissingKeys() throws {
        let decoded = try JSONDecoder().decode(SetupState.self, from: Data("{\"version\":1}".utf8))
        #expect(decoded == SetupState())
        // A file that is not JSON at all loads as the defaults.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-setup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SetupStateFile(url: directory.appending(path: "setup.json"))
        try Data("not json".utf8).write(to: file.url)
        #expect(file.load() == SetupState())
    }

    @Test func defaultURLLivesBesideAppStateAndHonoursXDG() {
        let xdg = SetupStateFile.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/jrbar-xdg-test"])
        #expect(xdg.path == "/tmp/jrbar-xdg-test/jrbar/setup.json")
        let plain = SetupStateFile.defaultURL(environment: [:])
        #expect(plain.lastPathComponent == "setup.json")
        #expect(plain.deletingLastPathComponent().lastPathComponent == "jrbar")
    }

    @Test func fileRoundTripFeedsTheLaunchGate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-setup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = SetupStateFile(url: directory.appending(path: "setup.json"))
        try file.save(SetupState(presentedCount: 1))
        #expect(file.exists)
        #expect(file.load().presentedCount == 1)
        try file.save(SetupState(finishedAt: 100, presentedCount: 1))
        let loaded = file.load()
        let store = SetupStore(model: SetupModel(), load: { loaded }, persist: { _ in })
        #expect(!store.shouldPresentOnLaunch, "a finished setup never auto-presents again")
        let fresh = SetupStore(model: SetupModel(), load: { SetupState(presentedCount: 1) }, persist: { _ in })
        #expect(fresh.shouldPresentOnLaunch)
    }
}
