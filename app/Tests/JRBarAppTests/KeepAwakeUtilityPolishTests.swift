import Foundation
import IOKit.pwr_mgt
import JRBarCore
import Testing
@testable import JRBarApp

/// Keep Awake's 0.10.1 manners, with every system hand a fake: the app's
/// own assertion is the computer's unless the display was asked for, an
/// old "Keep the display on" is reset once, the five-minute heads-up is one
/// scheduled event that a change drops, "+30 min" and Try again re-ask the
/// one hold, and the Utilities chips say who has the surface. No real
/// assertion is taken and no time passes: the heads-up's event is fired
/// by hand.
@MainActor
@Suite("Keep Awake polish", .serialized)
struct KeepAwakeUtilityPolishTests {
    final class Ticket: KeepAwakeHeadsUpTicket {
        var cancelled = false
        /// Fired by hand; a fired event is spent, like a real one.
        var fired = false
        func cancel() { cancelled = true }
    }

    @MainActor
    final class Clock {
        var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void, ticket: Ticket)] = []
        /// Events still waiting: neither cancelled nor fired.
        var live: [(delay: TimeInterval, fire: @MainActor () -> Void, ticket: Ticket)] {
            scheduled.filter { !$0.ticket.cancelled && !$0.ticket.fired }
        }

        /// Fire the first waiting event, as its deadline would.
        func fireNext() {
            guard let next = live.first else { Issue.record("nothing scheduled"); return }
            next.ticket.fired = true
            next.fire()
        }
    }

    private func defaults() throws -> (UserDefaults, String) {
        let suite = ScratchDefaults.suiteName("KeepAwakeUtilityPolishTests")
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func localState(_ defaults: UserDefaults, kinds: Box<[String]>) -> SystemTogglesStore.State {
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { kind in kinds.value.append(kind as String); return 7 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        return state
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func wire(_ scheduler: KeepAwakeHeadsUpScheduler, clock: Clock,
                      delivered: Box<[KeepAwakeHeadsUp]>, withdrawn: Box<Int>) {
        scheduler.schedule = { delay, fire in
            let ticket = Ticket()
            clock.scheduled.append((delay, fire, ticket))
            return ticket
        }
        scheduler.deliver = { delivered.value.append($0) }
        scheduler.withdraw = { withdrawn.value += 1 }
    }

    // MARK: The app's own assertion

    @Test("the app's own hold takes the computer's assertion, the display's only when asked")
    func localAssertionKind() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let kinds = Box<[String]>([])
        let state = localState(defaults, kinds: kinds)
        state.holdAwake(seconds: 900)
        #expect(kinds.value == [kIOPMAssertionTypeNoIdleSleep as String])
        state.holdAwake(seconds: 0)
        state.setAwakeKeepsDisplay(true)
        state.holdAwake(seconds: nil)
        #expect(kinds.value.last == kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
        state.holdAwake(seconds: 0)
        state.setAwakeKeepsDisplay(false)
        state.holdAwake(seconds: nil)
        #expect(kinds.value.last == kIOPMAssertionTypeNoIdleSleep as String)
        state.holdAwake(seconds: 0)
    }

    @Test("a lease the app asks of the monitor holds the computer only by default")
    func leaseDisplayDefault() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        let sent = Box<[CoreAwakeRequest?]>([])
        state.sendLease = { sent.value.append($0); return .taken }
        state.takeAssertion = { _ in Issue.record("no assertion while the monitor holds"); return nil }
        state.noteDaemonHold(nil, live: true)
        state.holdAwake(seconds: 3600)
        await state.leaseTask?.value
        state.holdAwakeUntilAgentsFinish()
        await state.leaseTask?.value
        state.holdAwake(seconds: nil)
        await state.leaseTask?.value
        #expect(sent.value.count == 3)
        #expect(sent.value.allSatisfy { $0?.display == false })
    }

    @Test("an old Keep the display on is reset once, and a later choice stands")
    func displayResetOnce() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
        let first = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        #expect(!first.awakeKeepsDisplay, "the old choice is reset")
        #expect(defaults.integer(forKey: SystemTogglesStore.awakeDisplayMigrationKey) == 1)
        first.setAwakeKeepsDisplay(true)
        for _ in 0..<3 {
            let again = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
            #expect(again.awakeKeepsDisplay, "the migration never runs again")
        }
    }

    // MARK: The heads-up

    @Test("a timed session arms one heads-up five minutes before it ends, and fires it once")
    func headsUpFires() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = KeepAwakeHeadsUpScheduler(defaults: defaults)
        let clock = Clock()
        let delivered = Box<[KeepAwakeHeadsUp]>([])
        let withdrawn = Box(0)
        wire(scheduler, clock: clock, delivered: delivered, withdrawn: withdrawn)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(3600))))
        scheduler.sync(reading: reading, now: now)
        scheduler.sync(reading: reading, now: now.addingTimeInterval(20))
        #expect(clock.live.count == 1, "one event, not one per sync")
        #expect(clock.live[0].delay == 55 * 60)
        clock.fireNext()
        #expect(delivered.value.count == 1)
        #expect(!scheduler.isArmed)
        // The countdown's own redraws re-sync; nothing arms again.
        scheduler.sync(reading: reading, now: now.addingTimeInterval(56 * 60))
        #expect(clock.scheduled.count == 1 && delivered.value.count == 1)
        #expect(withdrawn.value == 0, "the notice stands while its session holds")
    }

    @Test("a change to the hold drops the armed heads-up and takes a shown one back")
    func headsUpFollowsTheHold() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = KeepAwakeHeadsUpScheduler(defaults: defaults)
        let clock = Clock()
        let delivered = Box<[KeepAwakeHeadsUp]>([])
        let withdrawn = Box(0)
        wire(scheduler, clock: clock, delivered: delivered, withdrawn: withdrawn)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let end = now.addingTimeInterval(1800)
        scheduler.sync(reading: KeepAwakeReading(state: .lease(.until(end))), now: now)
        let first = clock.scheduled[0].ticket
        // Extended before it fired: the old event goes, a new one comes.
        let later = end.addingTimeInterval(1800)
        scheduler.sync(reading: KeepAwakeReading(state: .lease(.until(later))), now: now)
        #expect(first.cancelled)
        #expect(clock.live.count == 1 && clock.live[0].delay == 55 * 60)
        clock.fireNext()
        #expect(delivered.value.map(\.end) == [later])
        // "+30 min" from the notice: it is taken back and the next armed.
        let extended = later.addingTimeInterval(1800)
        scheduler.sync(reading: KeepAwakeReading(state: .lease(.until(extended))), now: now.addingTimeInterval(55 * 60))
        #expect(withdrawn.value == 1)
        #expect(clock.live.count == 1)
        // Turned off: nothing armed, nothing shown.
        scheduler.sync(reading: KeepAwakeReading(state: .off), now: now.addingTimeInterval(56 * 60))
        #expect(clock.live.isEmpty)
        #expect(!scheduler.isArmed)
    }

    @Test("quiet holds the heads-up, and the switch keeps it off")
    func headsUpHeld() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = KeepAwakeHeadsUpScheduler(defaults: defaults)
        let clock = Clock()
        let delivered = Box<[KeepAwakeHeadsUp]>([])
        let withdrawn = Box(0)
        wire(scheduler, clock: clock, delivered: delivered, withdrawn: withdrawn)
        let muted = try JSONDecoder().decode(CoreFocus.self, from: Data(#"{"mode":"mute","banner_allowed":false}"#.utf8))
        scheduler.focus = { muted }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(3600))))
        scheduler.sync(reading: reading, now: now)
        clock.fireNext()
        #expect(delivered.value.isEmpty, "quiet that holds banners holds this one")

        scheduler.enabled = false
        scheduler.sync(reading: KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(7200)))), now: now)
        #expect(clock.live.isEmpty, "off arms nothing")
        #expect(KeepAwakeHeadsUpScheduler.allowed(focus: nil))
    }

    @Test("without notifications wired nothing is ever armed")
    func headsUpUnwired() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = KeepAwakeHeadsUpScheduler(defaults: defaults)
        let scheduled = Box(0)
        scheduler.schedule = { _, _ in scheduled.value += 1; return Ticket() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        scheduler.sync(reading: KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(3600)))), now: now)
        #expect(scheduled.value == 0)
    }

    // MARK: +30 min and Try again

    @Test("+30 min carries the app's own countdown on, half an hour later")
    func extendLocal() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let kinds = Box<[String]>([])
        let state = localState(defaults, kinds: kinds)
        state.holdAwake(seconds: 600)
        let end = try #require(state.awakeUntil)
        state.extendAwake(now: end.addingTimeInterval(-300))
        let extended = try #require(state.awakeUntil)
        #expect(abs(extended.timeIntervalSince(end) - 1800) < 2)
        #expect(state.awakeReading.holding)
        state.holdAwake(seconds: 0)
    }

    @Test("+30 min re-asks the monitor's countdown with its later end")
    func extendLease() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        let sent = Box<[CoreAwakeRequest?]>([])
        state.sendLease = { sent.value.append($0); return .taken }
        state.takeAssertion = { _ in nil }
        let json = #"{"state":"manual","active":true,"lease":{"kind":"duration","until":1800003600,"started_at":1800000000}}"#
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8)), live: true)
        state.extendAwake(now: Date(timeIntervalSince1970: 1_800_003_300))
        await state.leaseTask?.value
        let request = try #require(sent.value.last ?? nil)
        #expect(request.shape == .until(1_800_005_400))
        #expect(request.display == false)
    }

    @Test("Try again re-asks a lease the monitor could not hold, in the same shape")
    func retryLease() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        let sent = Box<[CoreAwakeRequest?]>([])
        state.sendLease = { sent.value.append($0); return .taken }
        let json = #"{"state":"manual","active":false,"lease":{"kind":"process","pid":4242,"label":"swift"}}"#
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8)), live: true)
        #expect(state.canRetryAwake)
        state.retryAwake()
        await state.leaseTask?.value
        let request = try #require(sent.value.last ?? nil)
        #expect(request.shape == .whileRunning(pid: 4242, label: "swift"))
    }

    @Test("Try again re-takes a refused assertion for the same length")
    func retryLocal() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        let refuse = Box(true)
        state.takeAssertion = { _ in refuse.value ? nil : 9 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        state.holdAwake(seconds: 1200)
        #expect(state.canRetryAwake)
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        #expect(utility.status == .failed("Couldn't hold the Mac awake"))
        refuse.value = false
        state.retryAwake()
        #expect(state.awakeReading.holding)
        #expect(state.awakeUntil != nil, "the same 20 minutes")
        #expect(!state.canRetryAwake)
        state.holdAwake(seconds: 0)
    }

    // MARK: Chips and cost lines

    @Test("the Menu Bar chip names who draws the bar, never Parked")
    func menuBarChip() {
        let make = { (name: String, installed: Bool, running: Bool) in
            UtilityProviderStatus.make(name: name, surface: "the menu bar", installed: installed, running: running)
        }
        #expect(make("Ice", true, true) == .external("Ice draws the menu bar"))
        #expect(make("Bartender", true, false) == .unavailable("Bartender isn't running"))
        #expect(make("Hidden Bar", false, false) == .unavailable("Hidden Bar isn't installed"))
    }

    @Test("the Dock chip says both halves are off, or that they are starting")
    func dockChip() {
        #expect(DockUtility.idleChip(previewsOn: false, switcherOn: false) == .note("Previews and switcher are off"))
        #expect(DockUtility.idleChip(previewsOn: true, switcherOn: false) == .paused("Starting"))
    }

    @Test("no utility chip says Parked")
    func noParked() {
        let chips: [ToyStatus] = [
            UtilityProviderStatus.make(name: "Ice", surface: "the menu bar", installed: true, running: true),
            UtilityProviderStatus.make(name: "DockDoor", surface: "the previews", installed: true, running: false),
            DockUtility.idleChip(previewsOn: true, switcherOn: true),
            DockUtility.idleChip(previewsOn: false, switcherOn: false),
        ]
        for chip in chips { #expect(!chip.text.localizedCaseInsensitiveContains("parked")) }
        #expect(!MenuBarEngineHealth.parked.line().localizedCaseInsensitiveContains("parked"))
    }

    @Test("every utility card says what it costs, and off says nothing runs")
    func costLines() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let held = KeepAwakeReading(state: .lease(.until(Date(timeIntervalSince1970: 1_800_003_600))))
        #expect(KeepAwakeUtility.costLine(reading: held, appHolds: false, clockRunning: true,
                                          headsUpAt: Date(timeIntervalSince1970: 1_800_003_300),
                                          locale: Locale(identifier: "en_GB"), timeZone: zone)
                == "One power assertion, the computer only, the display may sleep · held by the monitor · the countdown redraws every 20 s · one heads-up at 08:55")
        let process = KeepAwakeReading(state: .lease(.whileRunning("swift")))
        #expect(KeepAwakeUtility.costLine(reading: process, appHolds: false, clockRunning: false, headsUpAt: nil)
                .contains("hears the command exit; nothing polls"))
        #expect(KeepAwakeUtility.costLine(reading: KeepAwakeReading(state: .off), appHolds: false,
                                          clockRunning: false, headsUpAt: nil) == UtilityCost.off)
        #expect(DockUtility.costLine(watching: true, switcher: true, previews: 3, captures: 0)
                == "Watching the Dock through Accessibility · 3 previews, no captures in the last minute · one key tap for the switcher chords")
        #expect(MenuBarUtility.costLine(rechecking: true, conditionRules: true)
                == "Rechecks the bar once a second · listens for display, Space and sleep changes · condition rules checked every 15 s")
        #expect(AgentUtility.costLine(updates: 1) == "Reads the monitor's feed, no timers of its own · 1 card update in the last minute")
    }

    @Test("the event log counts the last minute only")
    func eventLog() {
        let log = UtilityEventLog(capacity: 8)
        for second in [0.0, 10, 30, 59] { log.tick(at: 1000 + second) }
        #expect(log.count(at: 1059) == 4)
        #expect(log.count(at: 1065) == 3)
        #expect(log.count(at: 1200) == 0)
    }
}
