import Foundation

/// The words every surface uses for the monitor's connection. The client's
/// own reasons ("core closed the socket", a strerror) belong in the log and
/// Diagnostics; a person reads these instead.
///
/// - `connection(_:hasState:)` is the short status: a row value, a menu
///   line, a banner title.
/// - `reason(_:)` is the plain sentence for why it dropped, from the
///   client's raw reason or from an error a command threw.
/// - `restarting(failures:delay:)` and `crashed(failures:)` are the
///   supervisor's two bad states.
public enum MonitorWords {
    public static let label = "Monitor not connected"
    public static let sentence = "The monitor is not connected."
    public static let reconnecting = "Reconnecting…"
    public static let starting = "Starting the monitor…"
    public static let connected = "Connected"
    public static let waiting = "Connected, waiting for the first update"
    public static let notConnected = "Not connected"
    public static let notStarted = "Not started"

    /// The connection as a short status. `hasState` is whether the first
    /// state document has arrived on this connection. The first attempt
    /// reads "Starting the monitor…"; later ones read "Reconnecting…".
    public static func connection(_ connection: CoreModel.Connection, hasState: Bool = true) -> String {
        switch connection {
        case .connected: return hasState ? self.connected : self.waiting
        case .connecting(let attempt): return attempt <= 1 ? self.starting : self.reconnecting
        case .disconnected: return self.notConnected
        case .idle: return self.notStarted
        }
    }

    /// A plain sentence for the client's raw disconnect reason. Unknown
    /// reasons read as `sentence`, never as the raw text.
    public static func reason(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (needle, words) in reasonWords where text.contains(needle) { return words }
        return sentence
    }

    /// A plain sentence for an error a monitor command threw: the error's
    /// own description when it has one, else `sentence`.
    public static func reason(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        return sentence
    }

    /// The supervisor restarts a monitor that exited.
    public static func restarting(failures: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded(.up)))
        return "The monitor stopped. Restarting in \(seconds) s."
    }

    /// The supervisor gave up after too many exits in a short time.
    public static func crashed(failures: Int) -> String {
        let times = failures == 1 ? "once" : "\(failures) times"
        return "The monitor crashed \(times). Restart it from the panel."
    }

    /// Lowercased fragments of the client's reasons and strerror texts,
    /// each with its sentence. Checked in order.
    private static let reasonWords: [(String, String)] = [
        ("closed the socket", "The monitor closed the connection."),
        ("connection reset", "The monitor closed the connection."),
        ("broken pipe", "The monitor closed the connection."),
        ("no hello", "The monitor started but did not answer."),
        ("connection refused", "The monitor is not running."),
        ("no such file", "The monitor is not running."),
        ("timed out", "The monitor did not answer in time."),
        ("did not reply", "The monitor did not answer in time."),
        ("owned by uid", "The monitor's socket belongs to another user."),
        ("permission denied", "JR-Bar may not open the monitor's socket."),
        ("frame over", "The monitor sent an update too large to read."),
        ("stopped", "The connection was closed."),
    ]
}

public enum HookStatus: String, CaseIterable, Sendable {
    case live, quiet, notInstalled, off, notReported

    public init(_ raw: String?) {
        switch raw {
        case "ok": self = .live
        case "stale": self = .quiet
        case "missing": self = .notInstalled
        case "disabled": self = .off
        default: self = .notReported
        }
    }

    public var word: String {
        switch self {
        case .live: "Live"
        case .quiet: "Quiet"
        case .notInstalled: "Not installed"
        case .off: "Off"
        case .notReported: "Not reported"
        }
    }
}

public enum UsageStatus: String, CaseIterable, Sendable {
    case stale, usedUp, runsOut, noReading, noQuotaSource, noPace, reset, holding, paused, comfortable, notBurning, resetsFirst, incident
    case off, needsConsent, needsSignIn, unavailable, ready

    public static func provider(_ provider: CoreProviderUsage) -> Self {
        if provider.incident?.isEmpty == false { return .incident }
        if provider.usageIsOff || ["disabled", "off"].contains(provider.state) { return .off }
        if provider.isSignedOut || ["sign_in", "resign_in"].contains(provider.actionKind ?? "") { return .needsSignIn }
        if provider.actionKind == "manage" {
            let consentReasons = ["usage_consent_required", "browser_consent_required", "browser_refresh_consent_required"]
            return consentReasons.contains(provider.reason ?? "") ? .needsConsent : .needsSignIn
        }
        // The daemon's answer that this account has no quota ("no Go
        // subscription", "this plan reports none") is neutral, whatever
        // state carried it.
        if !provider.quotaSource, provider.availability == "available",
           !["needs_consent", "needs_sign_in"].contains(provider.state ?? "") { return .noQuotaSource }
        switch provider.state {
        case "needs_consent": return .needsConsent
        case "needs_sign_in": return .needsSignIn
        case "error", "failed", "unavailable", "source_not_found": return .unavailable
        default: break
        }
        if provider.isStale || ["source_idle", "missing_recent", "failing"].contains(provider.availability) { return .stale }
        if !provider.quotaSource { return .noQuotaSource }
        return provider.windows.isEmpty && provider.creditsRemaining == nil ? .noReading : .ready
    }

    public var word: String {
        switch self {
        case .off: "Off"
        case .needsConsent: "Needs consent"
        case .needsSignIn: "Needs sign in"
        case .unavailable: "Unavailable"
        case .ready: "Ready"
        case .stale: "Stale"
        case .usedUp: "Used up"
        case .runsOut: "Runs out"
        case .noReading: "No reading"
        case .noQuotaSource: "No quota source"
        case .noPace: "No pace yet"
        case .reset: "Reset"
        case .holding: "Holding"
        case .paused: "Paused"
        case .comfortable: "Comfortable"
        case .notBurning: "Not burning"
        case .resetsFirst: "Resets first"
        case .incident: "Incident"
        }
    }
}
