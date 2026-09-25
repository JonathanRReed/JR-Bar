import AppKit
import EventKit

/// W12's event glance: the next few calendar events, read-only, with
/// explicit Open/Join actions. Privacy is the default (T52): no
/// permission → the row is hidden entirely, never a fake "free all
/// day". The ask is never the card's: it lives on the Notch settings'
/// Calendar switch and Setup's permission row, and the card only reads
/// once access exists and the switch is on.
@MainActor
@Observable
final class ShelfCalendarModel {
    /// What the card renders. `hidden` covers the switch off and
    /// denied/restricted — the system said no and we show nothing
    /// rather than a state that pretends to know the calendar is empty.
    /// `needsPermission` draws nothing either: asking is Setup's job.
    enum State: Equatable {
        case hidden
        case needsPermission
        case idle              // authorized, nothing upcoming
        case events([Event])   // the next events, soonest first
    }

    /// Events the glance shows — the first carries Join.
    nonisolated static let eventLimit = 3
    /// How far ahead the glance looks.
    nonisolated static let lookahead: TimeInterval = 24 * 3600

    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        /// A joinable meeting URL — only http(s) ever reaches the
        /// browser (T52's unsafe-URL rule). `url` is nil when the event
        /// carries none or an unsafe scheme.
        let url: URL?
    }

    private(set) var state: State = .needsPermission
    private var refreshTimer: Timer?
    /// The permission as it stands; the tests hand in their own.
    @ObservationIgnored var authorization: () -> EKAuthorizationStatus = {
        EKEventStore.authorizationStatus(for: .event)
    }
    /// The EventKit read — synchronous, so it runs on `readQueue`, never
    /// on the frame the card grows on. The tests hand in their own.
    @ObservationIgnored var fetchEvents: @Sendable (Date) -> [Event] = { ShelfCalendarModel.fetchUpcoming(from: $0) }
    nonisolated let readQueue = DispatchQueue(label: "jrbar.shelf-calendar", qos: .userInitiated)
    /// Bumps on `stop` — the async permission answer can land after the
    /// card unpinned, and a grant must not restart the refresh timer
    /// the stop just killed.
    private var epoch = 0

    func stop() {
        epoch += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Pin-side entry: the switch off hides the row; on, the glance
    /// reads — but only where access was already granted. It never
    /// asks: a card that pops a permission prompt (or a "Show calendar"
    /// button on every open) is the clutter this replaces. The refresh
    /// cadence `stop` killed on unpin restarts here.
    func sync(enabled: Bool) {
        guard enabled else {
            stop()
            state = .hidden
            return
        }
        switch authorization() {
        case .fullAccess:
            loadNext()
        case .denied, .restricted:
            state = .hidden
        default:
            state = .needsPermission
        }
    }

    /// The next few timed events in the lookahead window, read off the
    /// main thread; the row keeps the last reading until it lands. An
    /// empty list is an honest "nothing upcoming" — the row says so
    /// rather than hiding a stale event. A reading that lands after the
    /// card folded (`stop` bumped the epoch) is dropped.
    private func loadNext() {
        let epoch = self.epoch
        let fetch = fetchEvents
        readQueue.async { [weak self] in
            let now = Date()
            let next = ShelfCalendarModel.upcoming(fetch(now), now: now, limit: ShelfCalendarModel.eventLimit)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.epoch == epoch else { return }
                    self.state = next.isEmpty ? .idle : .events(next)
                }
            }
        }
        scheduleRefresh()
    }

    /// One store for the glance's reads, made and used on a model's
    /// `readQueue` only (`fetchUpcoming` runs nowhere else). Two cards
    /// fetch on two queues, so the lock serializes them against the
    /// shared store.
    nonisolated(unsafe) private static var readStore: EKEventStore?
    nonisolated private static let readStoreLock = NSLock()

    /// The timed events in the lookahead window from `now`, projected.
    nonisolated static func fetchUpcoming(from now: Date) -> [Event] {
        readStoreLock.lock()
        defer { readStoreLock.unlock() }
        let store = readStore ?? EKEventStore()
        readStore = store
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(lookahead),
                                                 calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(project)
    }

    /// Soonest first, ended ones out (a meeting still running stays —
    /// it is the one you would Join), capped. Pure for the tests.
    nonisolated static func upcoming(_ events: [Event], now: Date, limit: Int) -> [Event] {
        Array(events.filter { $0.end > now }.sorted { $0.start < $1.start }.prefix(limit))
    }

    /// Re-read on a slow cadence while the card is pinned — events move.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadNext() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// EventKit → card model: title, times, and a joinable URL only
    /// when the event carries an http(s) one — `url` first, then the
    /// first safe link in the notes. Anything else is unjoinable.
    /// Pure, so a detached reader (the Dock tile's preview) projects
    /// without hopping to main.
    nonisolated static func project(_ event: EKEvent) -> Event {
        Event(title: event.title?.isEmpty == false ? event.title! : "Untitled",
              start: event.startDate, end: event.endDate,
              url: joinableURL(for: event))
    }

    /// The event's joinable link: `event.url` when http(s), else the
    /// first http(s) URL in the notes. Everything else returns nil.
    nonisolated static func joinableURL(for event: EKEvent) -> URL? {
        joinableURL(event.url, notes: event.notes)
    }

    /// The pure half so tests don't need an `EKEvent` (which can't be
    /// constructed): explicit url first, then the first safe link in
    /// the notes — both gated to http(s).
    nonisolated static func joinableURL(_ url: URL?, notes: String?) -> URL? {
        if let url, let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return url
        }
        guard let notes else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(notes.startIndex..., in: notes)
        let links = detector?.matches(in: notes, range: range).compactMap(\.url) ?? []
        return links.first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// Join opens the meeting link in the browser — the only action,
    /// and only ever with a URL that passed the scheme check.
    func join(_ event: Event) {
        guard let url = event.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open shows the event in Calendar.app — no details are copied
    /// into a JR-Bar surface, the system app is the truthful view.
    func openInCalendar(_ event: Event) {
        var components = DateComponents()
        components.hour = Calendar.current.component(.hour, from: event.start)
        components.minute = Calendar.current.component(.minute, from: event.start)
        let day = Calendar.current.startOfDay(for: event.start)
        if let when = Calendar.current.date(byAdding: components, to: day),
           let url = URL(string: "ical://\(Int(when.timeIntervalSince1970))") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The calendar's background half, and the only part that reads while
/// the card is shut: two minutes before a timed event with a join link
/// it hands the island a heads-up, and while such a meeting runs it is
/// a quiet stretch the island's hold follows. Opt-in (`meetingAlerts`),
/// and only ever where Calendar access was already granted — it never
/// asks. No polling: one read, then a single timer armed for the next
/// edge (a heads-up, a start, an end), re-read when the store changes
/// and at least every few minutes.
@MainActor
final class ShelfMeetingWatch {
    typealias Event = ShelfCalendarModel.Event

    /// How far ahead of the start the heads-up lands.
    nonisolated static let lead: TimeInterval = 120
    /// A meeting that started this long ago without a heads-up (the Mac
    /// was asleep) is no longer "starting" — nothing is said late.
    nonisolated static let lateGrace: TimeInterval = 60
    /// The longest the watch goes without a read — events move.
    nonisolated static let safetyRead: TimeInterval = 300

    /// A meeting is about to start.
    var onSoon: (Event) -> Void = { _ in }
    /// The meeting running now changed (one began, or it ended).
    var onLiveChange: (Event?) -> Void = { _ in }

    /// The meeting with a join link running now, if any.
    private(set) var live: Event?
    private(set) var running = false
    /// Heads-ups already given, so a re-read never repeats one.
    private var announced: Set<String> = []
    private var store: EKEventStore?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?

    /// On while the switch is on and access exists; off otherwise.
    func sync(enabled: Bool) {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            stop()
            return
        }
        guard !running else { return }
        running = true
        let store = self.store ?? EKEventStore()
        self.store = store
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        if live != nil {
            live = nil
            onLiveChange(nil)
        }
    }

    private func read() {
        guard running, let store else { return }
        let now = Date()
        // Back far enough to catch a long meeting already running.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(ShelfCalendarModel.lookahead),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(ShelfCalendarModel.project)
        note(events, now: now)
    }

    /// One reading: say what is due, move the live meeting, arm the next
    /// edge. Internal for the tests, which hand it events directly (a
    /// watch that is not running arms nothing).
    func note(_ events: [Event], now: Date) {
        if let soon = Self.dueSoon(events, now: now, announced: announced) {
            announced.insert(Self.key(soon))
            onSoon(soon)
        }
        // Only keys for events still in the window are worth keeping.
        let current = Set(events.map(Self.key))
        announced.formIntersection(current)
        let nowLive = Self.live(events, now: now)
        if nowLive != live {
            live = nowLive
            onLiveChange(nowLive)
        }
        arm(Self.nextWake(events, now: now), now: now)
    }

    private func arm(_ wake: Date?, now: Date) {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let at = min(wake ?? .distantFuture, now.addingTimeInterval(Self.safetyRead))
        let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Pure

    /// One event's identity across re-reads.
    nonisolated static func key(_ event: Event) -> String {
        "\(event.title)|\(Int(event.start.timeIntervalSince1970))"
    }

    /// The meeting to give a heads-up for now: joinable, starting within
    /// `lead` (or only just started), not yet announced — the soonest.
    nonisolated static func dueSoon(_ events: [Event], now: Date, announced: Set<String>) -> Event? {
        events
            .filter { event in
                event.url != nil && event.end > now
                    && event.start.addingTimeInterval(-lead) <= now
                    && now < event.start.addingTimeInterval(lateGrace)
                    && !announced.contains(key(event))
            }
            .min { $0.start < $1.start }
    }

    /// The joinable meeting running now — the latest to start when two
    /// overlap, since that is the one the person moved into.
    nonisolated static func live(_ events: [Event], now: Date) -> Event? {
        events
            .filter { $0.url != nil && $0.start <= now && now < $0.end }
            .max { $0.start < $1.start }
    }

    /// The next moment something changes — a heads-up, a start, an end
    /// — a hair past it, so the read lands on the far side.
    nonisolated static func nextWake(_ events: [Event], now: Date) -> Date? {
        let edges = events
            .filter { $0.url != nil }
            .flatMap { [$0.start.addingTimeInterval(-lead), $0.start, $0.end] }
            .filter { $0 > now }
        return edges.min()?.addingTimeInterval(0.5)
    }

    /// "in 2 min", "in 1 min", "now".
    nonisolated static func countdown(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 30 else { return "now" }
        return "in \(Int((seconds / 60).rounded(.up))) min"
    }

    /// The heads-up's second line: "10:00–10:30 · zoom.us".
    nonisolated static func detail(_ event: Event, calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        var line = "\(event.start.formatted(style))–\(event.end.formatted(style))"
        if var host = event.url?.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            line += " · \(host)"
        }
        return line
    }
}
