import AppKit
import JRBarCore
import SwiftUI

@MainActor
enum UsageCenterShortcut: Equatable {
    case range(UsageHistoryRange)
    case metric(UsageCenterStore.Metric)

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags, blocked: Bool) -> Self? {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        let base: NSEvent.ModifierFlags = [.command, .option]
        let numeric = ["1", "2", "3", "4"].contains(key)
        guard !blocked, relevant == base || (numeric && relevant == base.union(.shift)) else { return nil }
        switch key.lowercased() {
        case "1": return .range(.week)
        case "2": return .range(.month)
        case "3": return .range(.quarter)
        case "4": return .range(.year)
        case "t": return .metric(.tokens)
        case "c": return .metric(.cost)
        default: return nil
        }
    }

    static func dispatch(key: String, modifiers: NSEvent.ModifierFlags, blocked: Bool,
                         handler: (Self) -> Bool) -> Bool {
        guard let command = resolve(key: key, modifiers: modifiers, blocked: blocked) else { return false }
        return handler(command)
    }

    func handle(on store: UsageCenterStore) -> Bool {
        guard store.isLive else { return false }
        _ = perform(on: store)
        return true
    }

    @MainActor
    func perform(on store: UsageCenterStore) -> Task<Void, Never>? {
        guard store.isLive else { return nil }
        switch self {
        case .range(let range): return store.setRange(range)
        case .metric(let metric): return store.setMetric(metric)
        }
    }
}

struct UsageCenterShortcutReader: NSViewRepresentable {
    let onCommand: (UsageCenterShortcut) -> Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onCommand = onCommand
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onCommand = onCommand }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stopMonitoring() }

    final class ReaderView: NSView {
        var onCommand: ((UsageCenterShortcut) -> Bool)?
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var trackingMenus = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            let center = NotificationCenter.default
            menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackingMenus += 1 }
            })
            menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1)
                }
            })
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil else { return event }
                let blocked = self.trackingMenus > 0 || Self.blocksShortcuts(window.firstResponder)
                let handled = UsageCenterShortcut.dispatch(
                    key: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags,
                    blocked: blocked) { self.onCommand?($0) ?? false }
                return handled ? nil : event
            }
        }

        static func blocksShortcuts(_ responder: NSResponder?) -> Bool {
            var current = responder
            while let candidate = current {
                if candidate is NSText || candidate is NSControl { return true }
                let name = NSStringFromClass(type(of: candidate)).lowercased()
                if name.contains("recorder") || name.contains("shortcutcapture") { return true }
                current = candidate.nextResponder
            }
            return false
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
            menuObservers.removeAll()
            trackingMenus = 0
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
