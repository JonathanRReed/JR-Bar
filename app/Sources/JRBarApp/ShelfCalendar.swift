import AppKit
import EventKit

/// W12's event glance: the next calendar event, read-only, with an
/// explicit Open/Join action. Privacy is the default (T52): no
/// permission → the row is hidden entirely, never a fake "free all
/// day"; the read happens only after the user asks for it.
@MainActor
@Observable
final class ShelfCalendarModel {
    /// What the card renders. `hidden` covers denied/restricted —
    /// the system said no and we show nothing rather than a state that
    /// pretends to know the calendar is empty.
    enum State: Equatable {
        case hidden
        case needsPermission
        case idle            // authorized, nothing upcoming
        case event(Event)    // the next authorized event
    }

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
    private var store: EKEventStore?
    private var refreshTimer: Timer?

    /// The explicit opt-in — called from the card's calendar button,
    /// never at launch or on a timer.
    func authorizeAndLoad() {
        let store = self.store ?? EKEventStore()
        self.store = store
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            loadNext(from: store)
        case .denied, .restricted:
            state = .hidden
        case .notDetermined, .writeOnly:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    // EKEventStore isn't Sendable — read it back off
                    // self on the actor rather than sending it in.
                    guard let self, let store = self.store else { return }
                    if granted {
                        self.loadNext(from: store)
                    } else {
                        self.state = .hidden
                    }
                }
            }
        @unknown default:
            state = .hidden
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Next event within the lookahead window. `nil` is an honest
    /// "nothing upcoming" — the row says so rather than hiding a
    /// stale event.
    private func loadNext(from store: EKEventStore) {
        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
        state = next.map { .event(Self.project($0)) } ?? .idle
        scheduleRefresh()
    }

    /// Re-read on a slow cadence while the card is pinned — events move.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let store = self.store else { return }
                self.loadNext(from: store)
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// EventKit → card model: title, times, and a joinable URL only
    /// when the event carries an http(s) one — `url` first, then the
    /// first safe link in the notes. Anything else is unjoinable.
    static func project(_ event: EKEvent) -> Event {
        Event(title: event.title?.isEmpty == false ? event.title! : "Untitled",
              start: event.startDate, end: event.endDate,
              url: joinableURL(for: event))
    }

    /// The event's joinable link: `event.url` when http(s), else the
    /// first http(s) URL in the notes. Everything else returns nil.
    static func joinableURL(for event: EKEvent) -> URL? {
        joinableURL(event.url, notes: event.notes)
    }

    /// The pure half so tests don't need an `EKEvent` (which can't be
    /// constructed): explicit url first, then the first safe link in
    /// the notes — both gated to http(s).
    static func joinableURL(_ url: URL?, notes: String?) -> URL? {
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
