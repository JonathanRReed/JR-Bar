import AppKit
@preconcurrency import EventKit

/// Cached calendar reads for the notch and Dock, using the app-wide EventKit store.
/// Call `events` off main. Only value types leave the store.
final class ShelfCalendarReader: @unchecked Sendable {
    static let shared = ShelfCalendarReader()
    /// Consumers enqueue a read after this notification; they do not read inside its callback.
    static let didChange = Notification.Name("JRBarShelfCalendarChanged")
    static let cacheLifetime: TimeInterval = 60
    static let lookahead: TimeInterval = 3 * 24 * 3600
    typealias Event = ShelfCalendarModel.Event

    let notifications: NotificationCenter

    private let storeLock = NSLock()
    private let cacheLock = NSLock()
    private var generation = 0
    let store: any ShelfEventStore
    private var cached: (at: Date, events: [Event])?
    private let fetchOverride: (@Sendable (Date) -> [Event])?
    private let authorization: @Sendable () -> EKAuthorizationStatus
    private var observer: NSObjectProtocol?

    init(fetch: (@Sendable (Date) -> [Event])? = nil,
         authorization: (@Sendable () -> EKAuthorizationStatus)? = nil,
         notifications: NotificationCenter? = nil,
         store: any ShelfEventStore = SystemShelfEventStore.shared) {
        self.store = store
        self.notifications = notifications ?? (fetch == nil ? .default : NotificationCenter())
        fetchOverride = fetch
        self.authorization = authorization ?? {
            fetch == nil ? EKEventStore.authorizationStatus(for: .event) : .fullAccess
        }
        observer = self.notifications.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidate()
            self.notifications.post(name: Self.didChange, object: self)
        }
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    func invalidate() {
        cacheLock.withLock {
            cached = nil
            generation &+= 1
        }
    }

    /// Includes all-day and overlapping events through the next three days.
    /// Consumers filter their own windows. Store changes invalidate the minute cache.
    func events(from now: Date) -> [Event] {
        storeLock.withLock {
            guard authorization() == .fullAccess else {
                invalidate()
                return []
            }
            let snapshot = cacheLock.withLock { (self.cached, self.generation) }
            if let cached = snapshot.0, now >= cached.at,
               now.timeIntervalSince(cached.at) < Self.cacheLifetime {
                return cached.events
            }
            let events: [Event]
            if let fetchOverride {
                events = fetchOverride(now)
            } else {
                events = store.events(from: now)
            }
            guard authorization() == .fullAccess else {
                invalidate()
                return []
            }
            cacheLock.withLock {
                if generation == snapshot.1 { cached = (now, events) }
            }
            return events
        }
    }

    func eventAuthorization() -> EKAuthorizationStatus { authorization() }

    func seasonal(now: Date, birthdays: Bool) -> SeasonalReading {
        guard authorization() == .fullAccess else { return SeasonalReading() }
        return store.seasonal(now: now, birthdays: birthdays)
    }

    /// Only an explicit permission action calls this, using the same store as reads.
    func requestAccess(to entity: EKEntityType = .event) async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(to: entity) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
