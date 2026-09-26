import AppKit

/// Transient validity of one physical drag, not a saved layout preference.
@MainActor
final class MenuBarDragEnvironment {
    private(set) var isValid = true
    var onInvalidation: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         application: NotificationCenter = .default) {
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(name, on: workspace)
        }
        observe(NSApplication.didChangeScreenParametersNotification, on: application)
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
        observers.append((center, token))
    }

    func invalidate() {
        guard isValid else { return }
        let callback = onInvalidation
        finish()
        callback?()
    }

    func finish() {
        isValid = false
        onInvalidation = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }
}
