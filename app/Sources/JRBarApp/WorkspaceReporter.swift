import AppKit
import JRBarCore

/// Native workspace readings for the headless daemon's existing policies.
@MainActor
final class WorkspaceReporter {
    private weak var core: CoreModel?
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    private var pending: [[String: JSONValue]] = []
    private var sending: Task<Void, Never>?

    init(core: CoreModel) {
        self.core = core
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in [
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens_wake"),
            (NSWorkspace.screensDidSleepNotification, "screens_sleep"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_active"),
            (NSWorkspace.sessionDidResignActiveNotification, "session_inactive"),
            (NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, "accessibility"),
            (NSWorkspace.didActivateApplicationNotification, "snapshot"),
        ] { observe(workspace, name, event) }
        observe(.default, .NSSystemClockDidChange, "clock")
        observe(.default, .NSSystemTimeZoneDidChange, "timezone")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(event) }
        }
        tokens.append((center, token))
    }

    func connected() { report("snapshot") }

    private func report(_ event: String) {
        guard let core, core.authState == .authenticated,
              core.hello?.capabilities.contains("environment") == true else { return }
        let workspace = NSWorkspace.shared
        var args: [String: JSONValue] = [
            "event": .string(event),
            "display_asleep": .bool(CGDisplayIsAsleep(CGMainDisplayID()) != 0),
            "accessibility": .object([
                "reduce_motion": .bool(workspace.accessibilityDisplayShouldReduceMotion),
                "reduce_transparency": .bool(workspace.accessibilityDisplayShouldReduceTransparency),
                "increase_contrast": .bool(workspace.accessibilityDisplayShouldIncreaseContrast),
                "differentiate_without_color": .bool(workspace.accessibilityDisplayShouldDifferentiateWithoutColor),
            ]),
        ]
        if let frontmost = workspace.frontmostApplication?.bundleIdentifier { args["frontmost"] = .string(frontmost) }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let active = session[kCGSessionOnConsoleKey as String] as? Bool {
            args["session_active"] = .bool(active)
        }
        // App switches only owe the newest snapshot. Sleep/wake edges keep
        // their order, including when a command reply is still in flight.
        if event == "snapshot", pending.last?["event"] == .string("snapshot") { pending.removeLast() }
        pending.append(args)
        guard sending == nil else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            defer { self.sending = nil }
            while !self.pending.isEmpty, !Task.isCancelled {
                let args = self.pending.removeFirst()
                guard let core = self.core, core.authState == .authenticated else {
                    self.pending.removeAll()
                    return
                }
                _ = try? await core.send("environment", args: args)
            }
        }
    }

    func stop() {
        sending?.cancel()
        sending = nil
        pending.removeAll()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
