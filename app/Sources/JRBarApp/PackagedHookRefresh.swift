import JRBarCore

enum PackagedHookRefresh {
    enum Action: Equatable {
        case none, stampOnly, wait, refresh
    }

    static func action(previous: String?, current: String, coreLive: Bool) -> Action {
        guard let previous else { return .stampOnly }
        guard previous != current else { return .none }
        return coreLive ? .refresh : .wait
    }

    static func completedProviders(in reply: CoreReply) -> [String]? {
        guard reply.ok,
              let rows = reply.result?["providers"]?.arrayValue,
              let results = reply.result?["results"]?.objectValue else { return nil }
        let providers = rows.compactMap(\.stringValue)
        guard providers.count == rows.count,
              providers.allSatisfy({ results[$0]?["ok"]?.boolValue == true }) else { return nil }
        return providers
    }

    static func peerMatches(connected: Bool, peerPID: Int?, supervisor: CoreSupervisor.State?) -> Bool {
        guard connected, let supervisor, case .running(let pid) = supervisor else { return false }
        return peerPID == Int(pid)
    }
}
