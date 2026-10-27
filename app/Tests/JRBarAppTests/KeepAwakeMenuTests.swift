import Foundation
import IOKit.pwr_mgt
import JRBarCore
import Testing
@testable import JRBarApp

/// The keep-awake duration menu the Awake chip, the footer cup and the
/// Screen Bar's ear share: each preset asks the one hold for its
/// seconds, "Until \(UsageTime.clock(minutes: 480))" means the panel's own next-morning rule at any
/// hour, "Until the agents finish" is the daemon's agents lease, and the
/// person's own list of durations is kept clean. No power assertion is
/// ever taken — the lease and the assertions are fakes.
@MainActor
@Suite struct KeepAwakeMenuTests {
    final class FakeLease {
        var sent: [CoreAwakeRequest?] = []
    }

    final class Counter {
        var count = 0
    }

    final class FakeDock: DockAutohideDriver {
        var isAutohideEnabled = false
        func setAutohideEnabled(_ enabled: Bool) { isAutohideEnabled = enabled }
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = ScratchDefaults.suiteName("KeepAwakeMenuTests")
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// A store whose hold is the daemon's lease, answered at once.
    private func leased(_ defaults: UserDefaults) -> (SystemTogglesStore, SystemTogglesStore.State, FakeLease) {
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let fake = FakeLease()
        state.sendLease = { request in
            fake.sent.append(request)
            return .taken
        }
        state.takeAssertion = { _ in Issue.record("no assertion while the daemon holds"); return nil }
        state.noteDaemonHold(nil, live: true)
        return (SystemTogglesStore(state: state), state, fake)
    }

    /// Lets the lease's send task land. The deadline is generous because a
    /// full parallel run can hold the main actor for seconds; a pass
    /// returns as soon as the send lands.
    private func settle(_ state: SystemTogglesStore.State) async {
        await state.leaseTask?.value
    }

    /// Today at `hour:minute` on this Mac's clock.
    private func today(_ hour: Int, _ minute: Int) throws -> Date {
        try #require(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()))
    }

    @Test func eachPresetAsksForItsSeconds() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = leased(defaults)
        for seconds in KeepAwakeMenu.defaultDurations {
            KeepAwakeMenu.perform(.seconds(seconds), on: store)
            await settle(state)
        }
        #expect(fake.sent == KeepAwakeMenu.defaultDurations.map {
            CoreAwakeRequest(.seconds(Double($0)), display: false)
        })
        #expect(KeepAwakeMenu.seconds(for: .seconds(900), now: Date()) == .some(900))
        #expect(KeepAwakeMenu.seconds(for: .indefinitely, now: Date()) == .some(nil))
        #expect(KeepAwakeMenu.seconds(for: .turnOff, now: Date()) == .some(0))
        #expect(KeepAwakeMenu.seconds(for: .untilAgentsFinish, now: Date()) == .none)
    }

    @Test func untilMorningFitsTheDaemonsDayLongLeaseBetweenSevenAndEight() throws {
        // The panel's rule skips an 08:00 less than an hour away, which
        // is a 24 to 25 hour wait here: more than a lease may last, so
        // the daemon refused the hold. The menu waits for the 08:00 in
        // front of it instead.
        for (hour, minute) in [(7, 0), (7, 30), (7, 59)] {
            let now = try today(hour, minute)
            let asked = try #require(KeepAwakeMenu.seconds(for: .untilMorning, now: now) ?? nil)
            #expect(asked <= 86_400)
            #expect(asked == (8 - hour) * 3600 - minute * 60)
            let end = KeepAwakeMenu.morning(from: now)
            #expect(Calendar.current.component(.hour, from: end) == 8)
        }
    }

    @Test func untilMorningIsThePanelsNextMorningAtAnyHour() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for now in [try today(23, 10), try today(6, 45)] {
            let expected = PanelStore.secondsUntilMorning(from: now)
            #expect(KeepAwakeMenu.seconds(for: .untilMorning, now: now) == .some(expected))
            let (store, state, fake) = leased(defaults)
            KeepAwakeMenu.perform(.untilMorning, on: store, now: now)
            await settle(state)
            #expect(fake.sent == [CoreAwakeRequest(.seconds(Double(expected)), display: false)])
        }
        // 23:10 waits for tomorrow's 08:00; 06:45 for this morning's.
        let late = KeepAwakeMenu.items(durations: [], reading: KeepAwakeReading(state: .off),
                                       displayOn: false, monitorLive: true, now: try today(23, 10))
        #expect(late.first { $0.choice == .untilMorning }?.title == "Until \(UsageTime.clock(minutes: 480)) tomorrow")
        let early = KeepAwakeMenu.items(durations: [], reading: KeepAwakeReading(state: .off),
                                        displayOn: false, monitorLive: true, now: try today(6, 45))
        #expect(early.first { $0.choice == .untilMorning }?.title == "Until \(UsageTime.clock(minutes: 480))")
        // A moment with a fraction of a second still names 08:00, not 07:59.
        let fractional = try today(23, 10).addingTimeInterval(0.6)
        let named = KeepAwakeMenu.items(durations: [], reading: KeepAwakeReading(state: .off),
                                        displayOn: false, monitorLive: true, now: fractional)
        #expect(named.first { $0.choice == .untilMorning }?.title == "Until \(UsageTime.clock(minutes: 480)) tomorrow")
    }

    @Test func theAgentsItemSendsTheAgentsLease() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = leased(defaults)
        KeepAwakeMenu.perform(.untilAgentsFinish, on: store)
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.untilAgentsFinish(sessions: nil), display: false)])
    }

    @Test func withoutTheMonitorTheAgentsItemIsOffAndSaysWhy() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let taken = Counter()
        state.takeAssertion = { _ in taken.count += 1; return 42 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        let store = SystemTogglesStore(state: state)
        let items = KeepAwakeMenu.items(for: store)
        #expect(items.first { $0.choice == .untilAgentsFinish }?.enabled == false)
        KeepAwakeMenu.perform(.untilAgentsFinish, on: store)
        #expect(taken.count == 0, "no deadline is guessed")
        #expect(store.caption?.contains("only the monitor") == true)
    }

    @Test func theListReadsTheHold() {
        let off = KeepAwakeMenu.items(durations: [900, 3600], reading: KeepAwakeReading(state: .off),
                                      displayOn: true, monitorLive: true, now: Date())
        #expect(off.map(\.title).prefix(2) == ["For 15 minutes", "For 1 hour"])
        #expect(off.first { $0.choice == .turnOff }?.enabled == false, "nothing to turn off")
        #expect(off.first { $0.choice == .keepDisplayOn }?.checked == true)
        let indefinite = KeepAwakeMenu.items(durations: [900], reading: KeepAwakeReading(state: .lease(.indefinite)),
                                             displayOn: false, monitorLive: true, now: Date())
        #expect(indefinite.first { $0.choice == .indefinitely }?.checked == true)
        #expect(indefinite.first { $0.choice == .turnOff }?.enabled == true)
        #expect(Set(off.map(\.choice)).count == off.count, "each choice once")
    }

    @Test func pendingLeaseDisablesChoicesAndRejectsAnotherCommand() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = leased(defaults)
        state.applying.insert(.keepAwake)

        #expect(KeepAwakeMenu.items(for: store).allSatisfy { !$0.enabled })
        KeepAwakeMenu.perform(.seconds(900), on: store)
        #expect(fake.sent.isEmpty)
    }

    @Test func theDurationListStaysClean() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(KeepAwakeMenu.durations(defaults) == KeepAwakeMenu.defaultDurations)
        KeepAwakeMenu.setDurations([3600, 600, 3600, 5, 999_999], defaults)
        #expect(KeepAwakeMenu.durations(defaults) == [600, 3600])
        defaults.set(["soon", 1200.0], forKey: KeepAwakeMenu.durationsDefaultsKey)
        #expect(KeepAwakeMenu.durations(defaults) == [1200])
        KeepAwakeMenu.setDurations([], defaults)
        #expect(KeepAwakeMenu.durations(defaults) == KeepAwakeMenu.defaultDurations)
        #expect(defaults.object(forKey: KeepAwakeMenu.durationsDefaultsKey) == nil)
        #expect(KeepAwakeMenu.normalized(Array(stride(from: 600, through: 12_000, by: 600))).count
                == KeepAwakeMenu.maxDurations)
        #expect(KeepAwakeMenu.title(seconds: 5400) == "1 hour 30 minutes")
        #expect(KeepAwakeMenu.shortTitle(seconds: 900) == "15m")
        #expect(KeepAwakeMenu.shortTitle(seconds: 7200) == "2h")
    }

    @Test func theCardSwitchIsThePersonsHold() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = leased(defaults)
        let utility = KeepAwakeUtility(toggles: store)
        #expect(!utility.isOn)
        #expect(utility.status == .off)
        utility.isOn = true
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.indefinite, display: false)])
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","lease":{"kind":"indefinite"}}"#.utf8)), live: true)
        #expect(utility.isOn)
        utility.isOn = false
        await settle(state)
        #expect(fake.sent.last == .some(nil), "off is release_awake")
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","lease":{"kind":"indefinite"},"suspended":"low_power"}"#.utf8)), live: true)
        #expect(utility.status == .paused("Paused · Low Power Mode is on"))
    }

    @Test func oversizedSavedDurationsAreIgnored() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 1200.0],
                     forKey: KeepAwakeMenu.durationsDefaultsKey)
        #expect(KeepAwakeMenu.durations(defaults) == [1200])
        defaults.set([Double.greatestFiniteMagnitude], forKey: KeepAwakeMenu.durationsDefaultsKey)
        #expect(KeepAwakeMenu.durations(defaults) == KeepAwakeMenu.defaultDurations)
    }

    @Test func customDurationStartsWithoutChangingFullPresets() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let presets = Array(stride(from: 600, through: 4800, by: 600))
        KeepAwakeMenu.setDurations(presets, defaults)
        let (store, state, fake) = leased(defaults)
        state.setAwakeKeepsDisplay(true)
        KeepAwakeMenu.startCustomDuration(minutes: 47, on: store)
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.seconds(2820), display: true)])
        #expect(KeepAwakeMenu.durations(defaults) == presets)
    }

    @Test func customDurationRejectsInvalidMinutesAndPendingRequests() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = leased(defaults)
        for minutes in [Int.min, -1, 0, 1441, Int.max] {
            #expect(KeepAwakeMenu.customSeconds(minutes: minutes) == nil)
            KeepAwakeMenu.startCustomDuration(minutes: minutes, on: store)
        }
        #expect(fake.sent.isEmpty)
        #expect(KeepAwakeMenu.customSeconds(minutes: 1) == 60)
        #expect(KeepAwakeMenu.customSeconds(minutes: 1440) == 86_400)
        for text in ["", "abc", "1.5", "0", "1441", String(Int.max)] {
            #expect(KeepAwakeMenu.customMinutes(text) == nil)
        }
        #expect(KeepAwakeMenu.customMinutes(" 47 ") == 47)
        state.applying.insert(.keepAwake)
        KeepAwakeMenu.startCustomDuration(minutes: 47, on: store)
        #expect(fake.sent.isEmpty)
    }

    @Test func failedHoldBadgeDoesNotClaimTheMacIsAwake() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, _) = leased(defaults)
        let utility = KeepAwakeUtility(toggles: store)
        for lease in [#"{"kind":"indefinite"}"#, #"{"kind":"duration","until":2000000000}"#,
                      #"{"kind":"agents"}"#] {
            let json = "{\"state\":\"manual\",\"active\":false,\"lease\":" + lease + "}"
            state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8)), live: true)
            #expect(utility.isOn, "the manual request is still in force")
            #expect(utility.status == .failed("Not held"))
        }
    }

    @Test func otherHoldersAreAppsHoldingSleepOnly() {
        let assertions: [Int32: [[String: Any]]] = [
            100: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],
            200: [["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255],
                  ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],
            300: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],   // a daemon
            400: [["AssertType": "BackgroundTask", "AssertLevel": 255]],               // not about sleep
            500: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 0]],     // let go
            999: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],   // JR-Bar itself
        ]
        let apps: [Int32: (name: String, bundleID: String?)] = [
            100: ("Amphetamine", "com.if.Amphetamine"),
            200: ("Keynote", "com.apple.iWork.Keynote"),
            400: ("Music", "com.apple.Music"),
            500: ("Lungo", "com.sindresorhus.Lungo"),
            999: ("JR-Bar", "devin.jrbar"),
        ]
        let found = KeepAwakeHolders.holders(from: assertions, app: { apps[$0] }, ownPID: 999)
        #expect(found.map(\.name) == ["Amphetamine", "Keynote"])
        #expect(found.first { $0.name == "Keynote" }?.display == true)
        #expect(found.first?.sentence == "Amphetamine is keeping the Mac awake.")
    }

    @Test func theLidRowSaysWhatTheHelperNeedsNotACharger() throws {
        let decoder = JSONDecoder()
        let missing = try decoder.decode(CoreClosedLid.self, from: Data(#"{"helper_installed":false}"#.utf8))
        let holding = try decoder.decode(CoreClosedLid.self,
                                         from: Data(#"{"helper_installed":true,"holding":true}"#.utf8))
        let unknown = ClosedLidNote.text(nil)
        #expect(unknown == "Needs the privileged sleep helper; the monitor reports whether it is installed.")
        #expect(!unknown.contains("charger") && !unknown.contains("display"),
                "JR-Bar's hold is the sleep helper, not macOS's closed-lid mode")
        let notInstalled = ClosedLidNote.text(missing)
        #expect(notInstalled.contains("not installed"))
        let honoured = ClosedLidNote.text(holding)
        #expect(honoured == "The sleep helper is installed; closed-lid holds are honoured. Holding now.")
    }

    @Test(arguments: [false, true])
    func theLidRowShowsControllerFailures(holding: Bool) throws {
        let payload = """
        {"helper_installed":true,"holding":\(holding),"error":"synthetic release refused"}
        """
        var lid = try JSONDecoder().decode(CoreClosedLid.self, from: Data(payload.utf8))
        let note = ClosedLidNote.text(lid)
        #expect(note.contains("synthetic release refused"))
        #expect(!note.contains("honoured"))
        #expect(note.contains("still held awake") == holding)
        lid.error = nil
        #expect(ClosedLidNote.text(lid).contains("honoured"))
    }
}
