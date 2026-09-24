import Foundation
import IOKit.pwr_mgt
import JRBarCore
import Testing
@testable import JRBarApp

/// The keep-awake duration menu the Awake chip, the footer cup and the
/// Screen Bar's ear share: each preset asks the one hold for its
/// seconds, "Until 08:00" means the panel's own next-morning rule at any
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
        let suite = "KeepAwakeMenuTests.\(UUID().uuidString)"
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

    private func settle(_ state: SystemTogglesStore.State) async {
        let deadline = Date().addingTimeInterval(5)
        while state.applying.contains(.keepAwake), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
        #expect(late.first { $0.choice == .untilMorning }?.title == "Until 08:00 tomorrow")
        let early = KeepAwakeMenu.items(durations: [], reading: KeepAwakeReading(state: .off),
                                        displayOn: false, monitorLive: true, now: try today(6, 45))
        #expect(early.first { $0.choice == .untilMorning }?.title == "Until 08:00")
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
        state.releaseAssertion = { _ in }
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
        #expect(KeepAwakeMenu.shortTitle(seconds: 900) == "15 m")
        #expect(KeepAwakeMenu.shortTitle(seconds: 7200) == "2 h")
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
}
