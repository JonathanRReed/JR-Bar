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

    public var word: String {
        switch self {
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
