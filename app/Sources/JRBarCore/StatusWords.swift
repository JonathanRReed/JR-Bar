import Foundation

public enum MonitorWords {
    public static let label = "Monitor not connected"
    public static let sentence = "The monitor is not connected."
    public static let reconnecting = "Reconnecting…"
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
        if provider.isSignedOut { return .needsSignIn }
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
