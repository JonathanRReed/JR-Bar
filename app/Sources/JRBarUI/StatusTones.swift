import JRBarCore

public extension HookStatus {
    var tone: Tone { self == .live ? .live : .neutral }
}

public extension UsageStatus {
    var tone: Tone {
        switch self {
        case .usedUp, .incident, .unavailable, .needsSignIn: .failure
        case .ready: .done
        case .runsOut: .warning
        case .stale: .stale
        case .reset: .reset
        default: .neutral
        }
    }
}

public extension StateDot {
    init(hookStatus: HookStatus) { self.init(tone: hookStatus.tone, label: hookStatus.word) }
}

public extension StatusBadge {
    init(_ status: UsageStatus) { self.init(status.word, tone: status.tone) }
}
