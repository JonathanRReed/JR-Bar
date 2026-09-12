import AppKit
import JRBarCore
import UserNotifications

/// macOS notifications for daemon events. Permission is requested the
/// first time a notification is actually due, never at launch. Clicking
/// a banner opens the session; the ask category adds Approve and Deny
/// actions that type the answer into the session's terminal — the daemon
/// raises that terminal first, so the banner is not "without opening
/// anything", it answers without the panel.
///
/// `UNUserNotificationCenter` needs a bundle identifier, so when the app
/// runs unbundled (`swift run`) every call becomes a log line.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let askCategory = "jrbar.ask"
    static let plainCategory = "jrbar.plain"
    static let approveAction = "jrbar.approve"
    static let denyAction = "jrbar.deny"

    var onOpenSession: ((String) -> Void)?
    var onAnswerAsk: ((String, Bool) -> Void)?
    /// Awaited answerer, preferred over `onAnswerAsk` when set: returns the
    /// daemon's refusal message (or nil on success), so a refused banner
    /// action surfaces instead of doing nothing. The app wires it to
    /// `CoreModel.answerAskNow`.
    var onAnswerAskNow: (@MainActor (String, Bool) async -> String?)?
    var onLog: ((String) -> Void)?

    private var center: UNUserNotificationCenter?
    private var authorization: UNAuthorizationStatus = .notDetermined
    private var categoriesRegistered = false

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in self?.authorization = status }
        }
    }

    func deliver(_ notification: EventDelivery.Notification) {
        guard let center else {
            onLog?("notification (unbundled, not shown): \(notification.title) — \(notification.body)")
            return
        }
        registerCategories()
        ensureAuthorized { [weak self] granted in
            guard granted else { self?.onLog?("notification skipped: permission denied"); return }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.categoryIdentifier = notification.category == .ask ? Self.askCategory : Self.plainCategory
            content.threadIdentifier = notification.session ?? "jrbar"
            content.interruptionLevel = notification.category == .ask ? .timeSensitive : .active
            if let session = notification.session { content.userInfo["session"] = session }
            content.userInfo["identifier"] = notification.identifier
            let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard let error else { return }
                let message = "notification failed: \(error.localizedDescription)"
                Task { @MainActor [weak self] in self?.onLog?(message) }
            }
        }
    }

    func withdraw(identifier: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func registerCategories() {
        guard !categoriesRegistered, let center else { return }
        categoriesRegistered = true
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let ask = UNNotificationCategory(identifier: Self.askCategory, actions: [approve, deny], intentIdentifiers: [], options: [])
        let plain = UNNotificationCategory(identifier: Self.plainCategory, actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([ask, plain])
    }

    /// Lazy: the system prompt appears the first time a notification is due.
    private func ensureAuthorized(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let center else { completion(false); return }
        switch authorization {
        case .authorized, .provisional:
            completion(true)
        case .denied:
            completion(false)
        default:
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                Task { @MainActor [weak self] in
                    self?.authorization = granted ? .authorized : .denied
                    if let error { self?.onLog?("notification permission: \(error.localizedDescription)") }
                    completion(granted)
                }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // We play our own sound through AVAudioPlayer; the banner still shows while the app is frontmost.
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let session = response.notification.request.content.userInfo["session"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.approveAction:
                if let session { answer(session, approve: true) }
            case Self.denyAction:
                if let session { answer(session, approve: false) }
            case UNNotificationDismissActionIdentifier:
                break
            default:
                if let session { onOpenSession?(session) }
            }
        }
    }

    /// Approve/Deny on a banner. With `onAnswerAskNow` wired the answer is
    /// awaited: a refusal becomes a follow-up banner naming why, and
    /// clicking that banner opens the session to answer it there.
    private func answer(_ session: String, approve: Bool) {
        guard let onAnswerAskNow else {
            onAnswerAsk?(session, approve)
            return
        }
        Task { @MainActor in
            let refusal = await onAnswerAskNow(session, approve)
            guard let refusal else { return }
            onLog?("answer_ask refused: \(refusal)")
            deliver(.init(identifier: "answer-refused:\(session)",
                          title: "Could not \(approve ? "approve" : "deny") the ask",
                          body: "\(refusal) — click to open the session.",
                          category: .plain, session: session))
        }
    }
}
