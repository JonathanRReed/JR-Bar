@preconcurrency import EventKit
import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Seasonal touches' live half: off costs nothing, on reads once, and
/// reads again only when the day turns or the calendar database changes.
/// Every source here is synthetic: no real calendar or contact is read.
@Suite("Seasonal store")
@MainActor
struct SeasonalStoreTests {
    private final class Settings { var value = SeasonalSettings() }
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        private var count = 0
        private var lastBirthdays = false
        func hit(_ birthdays: Bool) { lock.withLock { count += 1; lastBirthdays = birthdays } }
        var reads: Int { lock.withLock { count } }
        var askedForBirthdays: Bool { lock.withLock { lastBirthdays } }
    }

    private static var halloween: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
    }

    private func make(_ reading: SeasonalReading = SeasonalReading(), access: SeasonalSource.Access = .granted)
        -> (SeasonalStore, Settings, Counter, NotificationCenter) {
        let settings = Settings()
        let counter = Counter()
        let center = NotificationCenter()
        let source = SeasonalSource(calendarAccess: { access }, contactsAccess: { .notAsked },
                                    read: { _, birthdays in counter.hit(birthdays); return reading },
                                    askContacts: { $0(false) })
        let store = SeasonalStore(settings: { settings.value }, source: source, center: center)
        store.clock = { Self.halloween }
        store.region = "US"
        return (store, settings, counter, center)
    }

    /// Let a read in flight land: its queue, then the main queue — a few
    /// rounds, so a notification's hop to main and the read after it
    /// both finish. Event-driven; nothing sleeps.
    private func settle(_ store: SeasonalStore) async {
        for _ in 0..<3 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    store.queue.async { DispatchQueue.main.async { done.resume() } }
                }
            }
        }
    }

    @Test("off: no observers, no reads, nothing in season")
    func offCostsNothing() async {
        let (store, _, counter, center) = make()
        store.settingsChanged()
        center.post(name: .NSCalendarDayChanged, object: nil)
        center.post(name: .EKEventStoreChanged, object: nil)
        await settle(store)
        #expect(!store.isRunning)
        #expect(counter.reads == 0)
        #expect(store.occasion == nil)
    }

    @Test("on: one read, then again only when the day turns or the calendars change")
    func readsOnlyOnEvents() async {
        let (store, settings, counter, center) = make()
        settings.value.enabled = true
        store.settingsChanged()
        await settle(store)
        #expect(store.isRunning)
        #expect(counter.reads == 1)
        #expect(store.occasion?.holiday == .halloween)
        center.post(name: .NSCalendarDayChanged, object: nil)
        await settle(store)
        #expect(counter.reads == 2)
        center.post(name: .EKEventStoreChanged, object: nil)
        await settle(store)
        #expect(counter.reads == 3)
        // Switching a holiday off recomputes from what was read.
        settings.value.set(.halloween, on: false)
        store.settingsChanged()
        await settle(store)
        #expect(counter.reads == 3)
        #expect(store.occasion == nil)
        settings.value.enabled = false
        store.settingsChanged()
        #expect(!store.isRunning)
        center.post(name: .NSCalendarDayChanged, object: nil)
        await settle(store)
        #expect(counter.reads == 3, "off stops listening")
    }

    @Test("a calendar's own day and a tagged birthday reach the occasion")
    func calendarsAndBirthdays() async {
        let day = Calendar.current.startOfDay(for: Self.halloween)
        let reading = SeasonalReading(entries: [
            SeasonalCalendarEntry(title: "Alex Rivera’s Birthday", start: day, end: day.addingTimeInterval(86_400),
                                  isBirthday: true, contactID: "contact-alex"),
        ], holidayCalendars: 1)
        let (store, settings, counter, _) = make(reading)
        settings.value.enabled = true
        store.settingsChanged()
        await settle(store)
        #expect(counter.askedForBirthdays)
        #expect(store.people.map(\.name) == ["Alex Rivera"])
        #expect(store.occasion?.holiday == .halloween, "nobody tagged yet")
        settings.value.celebrated = [SeasonalPerson(id: "contact-alex", name: "Alex Rivera")]
        store.settingsChanged()
        #expect(store.occasion?.holiday == .birthday)
        #expect(store.occasion?.caption == "Alex's birthday")
        #expect(store.sourceLine.contains("holiday calendars"))
    }

    @Test("with Birthdays off it never reads the year of birthdays, and turning it on reads once")
    func birthdaysOnDemand() async {
        let (store, settings, counter, _) = make()
        settings.value.enabled = true
        settings.value.set(.birthday, on: false)
        store.settingsChanged()
        await settle(store)
        #expect(!counter.askedForBirthdays)
        settings.value.set(.birthday, on: true)
        store.settingsChanged()
        await settle(store)
        #expect(counter.reads == 2)
        #expect(counter.askedForBirthdays)
    }

    @Test("without calendar access the rules date the holidays, and Settings says so")
    func rulesWithoutAccess() async {
        let (store, settings, _, _) = make(SeasonalReading(), access: .notAsked)
        settings.value.enabled = true
        store.settingsChanged()
        await settle(store)
        #expect(store.occasion?.holiday == .halloween)
        #expect(store.sourceLine.hasPrefix("Calendar access is off"))
    }

    @Test("a test store reads nothing real")
    func inertByDefaultInTests() {
        let core = CoreModel()
        var state = ToysState()
        state.seasonal.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        #expect(store.seasonal.calendarAccess == .notAsked)
        #expect(store.seasonal.isRunning)
        store.state.seasonal.enabled = false
        #expect(!store.seasonal.isRunning)
    }

    @Test("the garland hangs under the strip, its width, and stands down while the island is open")
    func bandFrame() {
        let strip = NSRect(x: 662.7, y: 860, width: 194.6, height: 4)
        let island = NSRect(x: 660, y: 864, width: 200, height: 36)
        let frame = SeasonalBandOverlay.frame(strip: strip, island: island, notchDepth: 32)
        #expect(frame?.minX == strip.minX && frame?.width == strip.width)
        #expect(frame?.maxY == strip.minY)
        #expect(frame?.height == SeasonalGarland.hang)
        let open = NSRect(x: 560, y: 600, width: 400, height: 300)
        #expect(SeasonalBandOverlay.frame(strip: strip, island: open, notchDepth: 32) == nil)
        #expect(SeasonalBandOverlay.frame(strip: nil, island: island, notchDepth: 32) == nil)
    }

    @Test("the card's strip is an overlay: the card is the same size with a set on")
    func cardKeepsItsSize() {
        let plain = SeasonalCardStripProbe(occasion: nil)
        let dressed = SeasonalCardStripProbe(occasion: SeasonalOccasion(holiday: .christmas))
        let a = NSHostingView(rootView: plain).fittingSize
        let b = NSHostingView(rootView: dressed).fittingSize
        #expect(a == b)
    }
}

/// A card-shaped stand-in with the strip laid over it as the card lays it.
private struct SeasonalCardStripProbe: View {
    let occasion: SeasonalOccasion?

    var body: some View {
        VStack(spacing: 12) {
            Text("Sample task")
            Text("Now · Shelf")
        }
        .padding(16)
        .padding(.bottom, 20)
        .frame(width: 320)
        .overlay(alignment: .bottom) {
            if let occasion {
                SeasonalCardStrip(occasion: occasion).frame(height: 36)
            }
        }
    }
}
