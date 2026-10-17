import Foundation

/// A working session that has gone quiet: the agent is listed as running,
/// its process still vouches for it, and it has said nothing for a while.
///
/// Silence is counted from the session's last signal (`since`, which is
/// the time of its newest hook event) and only while no tool call is open.
/// A tool that was started and has not finished is the agent waiting on a
/// build, a test run or a download, and a long one says nothing for many
/// minutes by design; flagging it would call every slow build a stuck
/// agent. Pure: the clock comes in as an argument.
public enum SilentSession {
    /// How long a working session may say nothing before the panel marks it.
    public static let threshold: TimeInterval = 10 * 60

    /// Hook events that begin a tool call. The call stays open until a
    /// finishing event replaces this one as the session's last word.
    private static let toolOpenEvents: Set<String> = ["PreToolUse"]
    /// Modes the daemon uses for a run that is inside a tool or a long task.
    private static let toolOpenModes: Set<String> = ["tool_running", "long_task_progress"]

    /// Whether the session's last word was the start of a tool call.
    public static func hasOpenToolCall(event: String?, mode: String?) -> Bool {
        if let event, toolOpenEvents.contains(event.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
        if let mode, toolOpenModes.contains(mode.lowercased()) { return true }
        return false
    }

    public static func hasOpenToolCall(_ session: CoreSession) -> Bool {
        hasOpenToolCall(event: session.event, mode: session.mode)
    }

    /// Seconds of silence when the row counts as silent, else nil: it is
    /// working, not stale, has no tool call open, and its last signal is at
    /// least `threshold` old at `now`.
    public static func silence(activity: SessionActivity, stale: Bool, openToolCall: Bool,
                               lastSignal: Date?, now: Date, threshold: TimeInterval = threshold) -> TimeInterval? {
        guard activity == .working, !stale, !openToolCall, let lastSignal else { return nil }
        let seconds = now.timeIntervalSince(lastSignal)
        return seconds >= threshold ? seconds : nil
    }

    /// The same for a daemon session row.
    public static func silence(of session: CoreSession, now: Date, threshold: TimeInterval = threshold) -> TimeInterval? {
        silence(activity: SessionActivity.reduce(session), stale: session.stale,
                openToolCall: hasOpenToolCall(session),
                lastSignal: (session.updatedAt ?? session.since).map { Date(timeIntervalSince1970: $0) },
                now: now, threshold: threshold)
    }
}

/// Says each silent stretch once. A stretch is one session's quiet since one
/// last signal: it is announced the first time it crosses the threshold, and
/// not again until the session speaks (a new last signal) and goes quiet
/// again. Value type with an injected clock; the app feeds it the sessions
/// on every state and on a slow tick.
public struct SilentSessionWatcher: Equatable, Sendable {
    public struct Notice: Equatable, Sendable {
        public var session: String
        public var label: String
        public var seconds: TimeInterval
    }

    /// Session id -> the last-signal time of the stretch already announced.
    private var announced: [String: Double] = [:]

    public init() {}

    /// The stretches that just became worth a word. `muted` names sessions
    /// the person has quieted or is looking at: they are left unannounced
    /// so the word comes if they are still silent when that ends.
    public mutating func observe(_ sessions: [CoreSession], now: Date, muted: (CoreSession) -> Bool = { _ in false },
                                 threshold: TimeInterval = SilentSession.threshold) -> [Notice] {
        var live: Set<String> = []
        var notices: [Notice] = []
        for session in sessions where !session.isChildWorker && !session.isRemote {
            live.insert(session.id)
            let signal = session.updatedAt ?? session.since ?? 0
            guard let seconds = SilentSession.silence(of: session, now: now, threshold: threshold) else {
                // It spoke, or is no longer silent: the next quiet is a new stretch.
                announced[session.id] = nil
                continue
            }
            if announced[session.id] == signal { continue }
            if muted(session) { continue }
            announced[session.id] = signal
            notices.append(Notice(session: session.id, label: session.displayLabel, seconds: seconds))
        }
        announced = announced.filter { live.contains($0.key) }
        return notices
    }

    /// "jr-bar has been quiet for 12m": the banner's words.
    public static func title(_ notice: Notice) -> String {
        "\(notice.label) has been quiet for \(FinishBanner.durationWords(notice.seconds) ?? "a while")"
    }

    /// The banner for a notice, after quiet's hold: nil while a Focus or a
    /// quiet mode holds courtesy banners. Silence is a courtesy kind, like a
    /// finish: only the `all` outbound level admits it.
    public static func banner(for notice: Notice, focus: CoreFocus?) -> EventDelivery.Notification? {
        let delivery = EventDelivery(notification: .init(identifier: "silent:\(notice.session)", title: title(notice),
                                                         body: body, session: notice.session))
        let event = CoreEvent(id: "silent:\(notice.session)", kind: "silent_session")
        return EventPolicy.holdingQuiet(delivery, for: event, focus: focus).notification
    }

    public static let body = "It is still running but has sent nothing for a while. Click to open the session."
}
