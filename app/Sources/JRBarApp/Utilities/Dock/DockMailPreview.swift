import AppKit
import JRBarCore
import os

@MainActor
final class DockMailPreview {
    enum State: Equatable {
        case loading, notRunning, noAccess, denied, timeout
        case messages(DockMailReading)
        case stale(DockMailReading)
        case unread(Int?)

        var reading: DockMailReading? {
            switch self {
            case .messages(let reading), .stale(let reading): return reading
            default: return nil
            }
        }

        func subtitle(now: Date) -> String {
            switch self {
            case .loading: return "Reading Mail…"
            case .notRunning: return "Not running"
            case .noAccess: return "Preview is off until you allow it"
            case .denied: return "Automation is turned off"
            case .timeout: return "Mail is slow to answer"
            case .unread(let count):
                return count.map { "\($0) unread" } ?? "Mail preview unavailable"
            case .messages(let reading):
                return reading.unread == 0 ? "All read" : "\(reading.unread) unread in Inbox"
            case .stale(let reading):
                let age = UsageTime.ago(now.timeIntervalSince(reading.date))
                return "\(reading.unread) unread in Inbox · reading from \(age)"
            }
        }
    }

    var logIssue: (String) -> Void = { issue in
        Logger(subsystem: "devin.jrbar", category: "dock-mail").notice("Mail preview: \(issue, privacy: .public)")
    }
    let reader: DockMailReader
    var clock: () -> Date = { Date() }
    var onChange: (State) -> Void = { _ in }
    let queue = DispatchQueue(label: "jrbar.dock-mail", qos: .userInitiated)
    private(set) var visible = false
    private(set) var cached: DockMailReading?
    private(set) var cacheIsStale = false
    private var work: DockMailCancellation?
    private var generation = 0
    private var dirty = false
    private var replying = false
    private var badge: String?
    private var observers: [NSObjectProtocol] = []

    init(reader: DockMailReader = DockMailReader()) { self.reader = reader }

    func restore(_ reading: DockMailReading?, badge: String?, stale: Bool) {
        cached = reading
        cacheIsStale = stale
        self.badge = badge
    }

    func show(badge: String?) {
        let changed = self.badge != badge
        self.badge = badge
        visible = true
        for name in [NSApplication.didBecomeActiveNotification, PermissionRequest.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        }
        refresh(force: changed)
    }

    func hide() {
        visible = false
        generation += 1
        work?.cancel()
        work = nil
        dirty = false
        replying = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func discard() {
        hide()
        cached = nil
        cacheIsStale = false
        onChange = { _ in }
    }

    func badgeChanged(_ badge: String?) {
        guard visible, self.badge != badge else { return }
        self.badge = badge
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard visible else { return }
        if force { cacheIsStale = cached != nil }
        guard reader.isRunning() else { cached = nil; onChange(.notRunning); return }
        switch reader.permission(false) {
        case .needsConsent: cached = nil; onChange(.noAccess); return
        case .denied: cached = nil; onChange(.denied); return
        case .unavailable: cached = nil; onChange(.notRunning); return
        case .granted: break
        }
        if work != nil { dirty = dirty || force; return }
        let now = clock()
        if !force, !cacheIsStale, let cached, now.timeIntervalSince(cached.date) < 30 {
            publish(cached, stale: false)
            return
        }
        if let cached {
            cacheIsStale = true
            publish(cached, stale: true)
        } else { onChange(.loading) }
        let reader = self.reader
        let generation = self.generation
        let cancellation = DockMailCancellation()
        work = cancellation
        queue.async { [weak self] in
            let result = reader.read(now: now, cancellation: cancellation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.generation == generation else { return }
                self.work = nil
                guard reader.isRunning(), reader.permission(false) == .granted else {
                    self.refresh(force: true)
                    return
                }
                switch result {
                case .success(let reading):
                    if !reading.complete { self.logIssue("account_inbox_unavailable") }
                    if reading.unread == 0, let count = self.badgeCount {
                        self.logIssue("badge_positive_script_zero")
                        self.cacheIsStale = true
                        self.onChange(.unread(count))
                    } else if !reading.complete {
                        self.cacheIsStale = true
                        if let cached = self.cached { self.publish(cached, stale: true) }
                        else { self.onChange(.unread(self.badgeCount)) }
                    } else {
                        self.cached = reading
                        self.cacheIsStale = false
                        self.publish(reading, stale: false)
                    }
                case .failure(.unavailable): self.cached = nil; self.onChange(.notRunning)
                case .failure(.denied): self.cached = nil; self.onChange(.denied)
                case .failure:
                    self.cacheIsStale = true
                    self.publishFailure()
                }
                if self.dirty { self.dirty = false; self.refresh(force: true) }
            }
        }
    }

    private var badgeCount: Int? {
        guard let badge else { return nil }
        let digits = badge.filter { $0.isNumber }
        // Accept grouping separators, but never reinterpret labels such as "99+".
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ",. \u{a0}\u{202f}"))
        guard badge.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let count = Int(digits), count > 0 else { return nil }
        return count
    }

    private func publish(_ reading: DockMailReading, stale: Bool) {
        if reading.unread == 0, let count = badgeCount { onChange(.unread(count)) }
        else { onChange(stale ? .stale(reading) : .messages(reading)) }
    }

    private func publishFailure() {
        if let cached { publish(cached, stale: true) }
        else if let count = badgeCount { onChange(.unread(count)) }
        else { onChange(.timeout) }
    }

    func requestAccess() async {
        guard visible else { return }
        let reader = self.reader
        await PermissionRequest.live(permission: .automation, status: {
            let permission = await Task.detached { reader.permission(false) }.value
            return SetupModel.automationStatus(permission)
        }, prompt: {
            _ = await Task.detached { reader.permission(true) }.value
        }, settingsURL: AutomationPermission.settingsURL).perform()
        refresh(force: true)
    }

    func reply(_ message: DockMailMessage) {
        guard visible, !replying, cached?.messages.contains(where: { $0.id == message.id }) == true else { return }
        let reader = self.reader
        let cancellation = DockMailCancellation()
        // Share cancellation with the read lifecycle so hide/off always stops the child.
        if let activeRead = work {
            activeRead.cancel()
            self.generation += 1
            dirty = true
        }
        replying = true
        work = cancellation
        let generation = self.generation
        queue.async { [weak self] in
            let result: Result<String, DockMailError>
            if reader.isRunning(), reader.permission(false) == .granted, !cancellation.cancelled {
                result = reader.runner(DockMailReader.replyScript, [message.id], cancellation)
            } else { result = .failure(.unavailable) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.generation == generation else { return }
                self.work = nil
                self.replying = false
                if case .failure = result { self.publishFailure() }
                if self.dirty { self.dirty = false; self.refresh(force: true) }
            }
        }
    }
}
