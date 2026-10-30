import AppKit
import EventKit

/// The Dock shares the shelf's single fetch coordinator and native store.
@MainActor
final class DockRemindersPreview {
    enum State: Equatable {
        case loading, noAccess, denied
        case items([ShelfRemindersModel.Entry])
        case stale([ShelfRemindersModel.Entry])
    }

    let reader: ShelfReminderReader
    let notifications: NotificationCenter
    var authorization: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .reminder) }
    var clock: () -> Date = { Date() }
    var calendar = Calendar.current
    var onChange: (State) -> Void = { _ in }
    private(set) var state: State = .loading
    private(set) var running = false
    private let owner = UUID()
    private var epoch = 0
    private var observers: [NSObjectProtocol] = []
    var scheduleDeadline: (@escaping @MainActor () -> Void) -> (() -> Void) = { action in
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        return { work.cancel() }
    }
    private var cancelDeadline: (() -> Void)?
    private var lastGood: [ShelfRemindersModel.Entry] = []
    private(set) var writeNotice: String?

    init(reader: ShelfReminderReader = .shared, notifications: NotificationCenter = .default) {
        self.reader = reader
        self.notifications = notifications
    }

    func start() {
        guard !running else { return }
        running = true
        for name in [Notification.Name.EKEventStoreChanged, PermissionRequest.didChange,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        running = false
        epoch += 1
        reader.forget(owner)
        cancelDeadline?()
        cancelDeadline = nil
        for observer in observers { notifications.removeObserver(observer) }
        observers.removeAll()
        lastGood = []
        writeNotice = nil
        state = .loading
    }

    func refresh() {
        guard running else { return }
        epoch += 1
        cancelDeadline?()
        cancelDeadline = nil
        let epoch = self.epoch
        switch authorization() {
        case .fullAccess: break
        case .denied, .restricted:
            reader.forget(owner)
            lastGood = []
            publish(.denied)
            return
        default:
            reader.forget(owner)
            lastGood = []
            publish(.noAccess)
            return
        }
        if lastGood.isEmpty { publish(.loading) }
        cancelDeadline = scheduleDeadline { [weak self] in
            guard let self, self.running, self.epoch == epoch else { return }
            guard self.authorization() == .fullAccess else { self.refresh(); return }
            self.publish(.stale(self.lastGood))
        }
        reader.request(for: owner) { [weak self] entries in
            guard let self, self.running, self.epoch == epoch else { return }
            self.cancelDeadline?()
            self.cancelDeadline = nil
            guard self.authorization() == .fullAccess else { self.refresh(); return }
            guard let entries else { self.publish(.stale(self.lastGood)); return }
            let tomorrow = self.calendar.date(byAdding: .day, value: 1,
                                              to: self.calendar.startOfDay(for: self.clock())) ?? self.clock()
            self.lastGood = entries.filter { $0.due.map { $0 < tomorrow } ?? false }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            self.publish(.items(self.lastGood))
        }
    }

    func complete(_ entry: ShelfRemindersModel.Entry) {
        guard running, authorization() == .fullAccess, lastGood.contains(entry) else { return }
        do {
            guard try reader.store.completeReminder(id: entry.id) else {
                writeNotice = "That reminder is no longer available."
                publish(state)
                return
            }
            writeNotice = nil
            refresh()
        } catch {
            writeNotice = "Couldn't mark that reminder done. Open Reminders to try again."
            publish(state)
        }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        guard running, authorization() == .fullAccess,
              let draft = ShelfRemindersModel.quickAdd(text, calendar: calendar) else { return false }
        do {
            guard try reader.store.addReminder(ShelfReminderDraft(title: draft.title, due: draft.due)) else {
                writeNotice = "Reminders has no default list."
                publish(state)
                return false
            }
            writeNotice = nil
            refresh()
            return true
        } catch {
            writeNotice = "Couldn't add the reminder. Open Reminders to try again."
            publish(state)
            return false
        }
    }

    private func publish(_ state: State) {
        self.state = state
        onChange(state)
    }
}
