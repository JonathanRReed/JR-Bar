import Contacts
@preconcurrency import EventKit
import Foundation
import JRBarCore
import Observation

/// What a seasonal read found: the holiday and birthday events, and the
/// person's own birthday from their card.
struct SeasonalReading: Equatable, Sendable {
    /// nil while calendar access is off: the rules alone decide then.
    var entries: [SeasonalCalendarEntry]?
    /// How many holiday calendars the person keeps.
    var holidayCalendars: Int = 0
    /// Month and day from the person's own contact card.
    var ownBirthday: DateComponents?
}

/// Where seasonal touches read from. The app's reader goes through the
/// shared EventKit store under the notch's existing Calendar grant and the
/// Me card under a Contacts grant; neither ever asks. Tests hand in their
/// own, so nothing here touches a real calendar or contact.
struct SeasonalSource: Sendable {
    enum Access: Equatable, Sendable { case granted, notAsked, refused }

    var calendarAccess: @Sendable () -> Access
    var contactsAccess: @Sendable () -> Access
    /// Read the holiday calendars around `now`, and, when `birthdays`,
    /// the Birthdays calendar for the year ahead and the Me card.
    var read: @Sendable (_ now: Date, _ birthdays: Bool) -> SeasonalReading
    /// Ask for Contacts — only from the person's own click.
    var askContacts: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    /// Nothing to read: every test store and any build without the native
    /// sources. The rules still date the holidays.
    static let inert = SeasonalSource(calendarAccess: { .notAsked }, contactsAccess: { .notAsked },
                                      read: { _, _ in SeasonalReading() }, askContacts: { $0(false) })

    /// The Mac's own calendars and card.
    static let system = SeasonalSource(
        calendarAccess: {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notAsked
            default: return .refused
            }
        },
        contactsAccess: {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .refused
            }
        },
        read: { now, birthdays in SeasonalSource.readSystem(now: now, birthdays: birthdays) },
        askContacts: { done in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in done(granted) }
        })

    /// How far back the holiday read looks: far enough to find the start
    /// of a Ramadan or a Hanukkah already under way.
    static let lookBack: TimeInterval = 35 * 86_400

    private static func readSystem(now: Date, birthdays: Bool) -> SeasonalReading {
        var reading = SeasonalReading()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let today = Calendar.current.startOfDay(for: now)
            reading.entries = SharedEventStore.shared.read { store in
                let calendars = store.calendars(for: .event)
                let holidays = calendars.filter {
                    $0.type != .birthday && $0.title.localizedCaseInsensitiveContains("holiday")
                }
                let birthdayCalendars = calendars.filter { $0.type == .birthday }
                reading.holidayCalendars = holidays.count
                var entries: [SeasonalCalendarEntry] = []
                if !holidays.isEmpty {
                    let predicate = store.predicateForEvents(withStart: today.addingTimeInterval(-lookBack),
                                                             end: today.addingTimeInterval(2 * 86_400),
                                                             calendars: holidays)
                    entries += store.events(matching: predicate).map {
                        SeasonalCalendarEntry(title: $0.title ?? "", start: $0.startDate, end: $0.endDate)
                    }
                }
                if birthdays, !birthdayCalendars.isEmpty {
                    let predicate = store.predicateForEvents(withStart: today, end: today.addingTimeInterval(366 * 86_400),
                                                             calendars: birthdayCalendars)
                    entries += store.events(matching: predicate).map {
                        SeasonalCalendarEntry(title: $0.title ?? "", start: $0.startDate, end: $0.endDate,
                                              isBirthday: true, contactID: $0.birthdayContactIdentifier)
                    }
                }
                return entries
            }
        }
        if birthdays, CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            let keys = [CNContactBirthdayKey as CNKeyDescriptor]
            if let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys), let birthday = me.birthday {
                reading.ownBirthday = DateComponents(month: birthday.month, day: birthday.day)
            }
        }
        return reading
    }
}

/// Seasonal touches' live state: today's occasion, read once a day.
///
/// Off, it holds no observers and reads nothing. On, it reads the person's
/// calendars once, then again only when the day turns
/// (`NSCalendarDayChanged`) or the calendar database changes
/// (`EKEventStoreChanged`): never on a timer. Switching a holiday or a
/// person on or off recomputes from what was already read.
@MainActor
@Observable
final class SeasonalStore {
    /// Today's touch, or nil.
    private(set) var occasion: SeasonalOccasion?
    /// The people the Birthdays calendar names, for the tag list.
    private(set) var people: [SeasonalPerson] = []
    /// What the last read found, kept to recompute without reading.
    private(set) var reading: SeasonalReading?
    /// Calendar reads so far: the cost line and the tests count them.
    private(set) var reads = 0
    private(set) var calendarAccess: SeasonalSource.Access = .notAsked
    private(set) var contactsAccess: SeasonalSource.Access = .notAsked

    @ObservationIgnored var settings: @MainActor () -> SeasonalSettings
    @ObservationIgnored var source: SeasonalSource
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    @ObservationIgnored var calendar: Calendar = .current
    @ObservationIgnored var region: String? = Locale.current.region?.identifier
    @ObservationIgnored let center: NotificationCenter
    @ObservationIgnored let queue = DispatchQueue(label: "jrbar.seasonal", qos: .utility)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readInFlight = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var readWithBirthdays = false

    /// Whether it is on and listening.
    var isRunning: Bool { !observers.isEmpty }

    init(settings: @escaping @MainActor () -> SeasonalSettings, source: SeasonalSource,
         center: NotificationCenter = .default) {
        self.settings = settings
        self.source = source
        self.center = center
    }

    /// Bring it in line with the settings: start on, stop off, and
    /// otherwise recompute today. A Birthdays switch turned on needs the
    /// year of birthdays, so it reads once more.
    func settingsChanged() {
        let current = settings()
        guard current.enabled else {
            stop()
            return
        }
        guard isRunning else {
            start()
            return
        }
        let wantsBirthdays = current.isOn(.birthday)
        if wantsBirthdays, !readWithBirthdays {
            refresh()
        } else {
            resolve()
        }
    }

    func start() {
        guard !isRunning else { return }
        let names: [Notification.Name] = [.NSCalendarDayChanged, .EKEventStoreChanged]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        generation += 1
        readInFlight = false
        readAgain = false
        reading = nil
        people = []
        occasion = nil
    }

    /// Read again, off the main thread; a read already under way is
    /// followed by one more rather than a second in parallel.
    func refresh() {
        guard isRunning else { return }
        calendarAccess = source.calendarAccess()
        contactsAccess = source.contactsAccess()
        guard !readInFlight else {
            readAgain = true
            return
        }
        readInFlight = true
        generation += 1
        let generation = self.generation
        let now = clock()
        let birthdays = settings().isOn(.birthday)
        let read = source.read
        queue.async { [weak self] in
            let reading = read(now, birthdays)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.readInFlight = false
                    self.reads += 1
                    self.readWithBirthdays = birthdays
                    self.apply(reading)
                    if self.readAgain {
                        self.readAgain = false
                        self.refresh()
                    }
                }
            }
        }
    }

    /// Take a reading in: the tests call this directly with synthetic
    /// events.
    func apply(_ reading: SeasonalReading) {
        self.reading = reading
        let found = SeasonalResolver.birthdayPeople(reading.entries ?? [])
        if found != people { people = found }
        resolve()
    }

    /// Today's occasion from the last reading and the rules.
    func resolve() {
        let current = settings()
        let next = current.enabled
            ? SeasonalResolver.occasion(on: clock(), settings: current, entries: reading?.entries,
                                        ownBirthday: reading?.ownBirthday, calendar: calendar, region: region)
            : nil
        if next != occasion { occasion = next }
    }

    /// Ask for Contacts, from the person's click on the Birthdays row.
    func askForContacts() {
        source.askContacts { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// The Settings line saying where the dates come from.
    var sourceLine: String {
        switch calendarAccess {
        case .granted:
            let count = reading?.holidayCalendars ?? 0
            if count == 0 {
                return "Your calendars have no holiday calendar, so JR-Bar dates the holidays itself."
            }
            return "Dates come from your holiday calendars, and JR-Bar's own rules for any they don't list."
        case .notAsked, .refused:
            return "Calendar access is off, so JR-Bar dates the holidays itself. Turn on Calendar in Notch settings to use your calendars."
        }
    }
}
