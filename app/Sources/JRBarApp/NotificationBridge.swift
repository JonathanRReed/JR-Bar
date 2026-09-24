import AppKit
import JRBarCore
import UserNotifications

/// macOS notifications for daemon events. Permission is requested the
/// first time a notification is actually due, never at launch. Clicking
/// a banner opens the session; the ask category adds Approve and Deny,
/// pinned to the ask the banner was posted for — a banner left in
/// Notification Center never answers the ask that replaced it.
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
    /// A banner's Approve or Deny, awaited: the session, the request the
    /// banner was pinned to, and the verdict. Returns the refusal line
    /// (or nil once the answer landed), so a refused banner action
    /// surfaces instead of doing nothing. `EventCoordinator` wires it to
    /// the shared answer desk.
    var onAnswerAskNow: (@MainActor (_ session: String, _ request: String?, _ approve: Bool) async -> String?)?
    var onLog: ((String) -> Void)?

    /// The banner's copy of its ask episode.
    nonisolated static let requestKey = "request"

    /// Said, then "click to open the session", when the ask a banner was
    /// posted for is no longer the session's live one.
    static let replacedLine = "That ask was replaced"

    /// The live ask a banner's Approve or Deny may answer: the session's
    /// open ask, and when the banner carries a request, only that same
    /// request. nil means the banner's ask was answered or replaced.
    nonisolated static func liveAsk(session: String, request: String?, in asks: [CoreAsk]) -> CoreAsk? {
        asks.first { $0.session == session && (request == nil || $0.request == request) }
    }

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

    /// `request` rides an ask banner's userInfo, so its Approve and Deny
    /// answer the episode it was posted for and no later one.
    func deliver(_ notification: EventDelivery.Notification, request: String? = nil) {
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
            if let request { content.userInfo[Self.requestKey] = request }
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
        let userInfo = response.notification.request.content.userInfo
        let session = userInfo["session"] as? String
        let request = userInfo[Self.requestKey] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.approveAction:
                if let session { answer(session, request: request, approve: true) }
            case Self.denyAction:
                if let session { answer(session, request: request, approve: false) }
            case UNNotificationDismissActionIdentifier:
                break
            default:
                if let session { onOpenSession?(session) }
            }
        }
    }

    /// Approve/Deny on a banner, awaited: a refusal becomes a follow-up
    /// banner naming why, and clicking that banner opens the session to
    /// answer it there.
    private func answer(_ session: String, request: String?, approve: Bool) {
        guard let onAnswerAskNow else {
            onLog?("banner answer dropped: nothing wired to answer it")
            return
        }
        Task { @MainActor in
            let refusal = await onAnswerAskNow(session, request, approve)
            guard let refusal else { return }
            onLog?("answer_ask refused: \(refusal)")
            deliver(.init(identifier: "answer-refused:\(session)",
                          title: "Could not \(approve ? "approve" : "deny") the ask",
                          body: "\(refusal) — click to open the session.",
                          category: .plain, session: session))
        }
    }
}
