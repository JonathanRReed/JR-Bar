import Foundation

/// Compatibility imports describe their source separately from the provider.
public struct CoreUsageSourceStatistic: Codable, Hashable, Sendable {
    public var sourceId: String
    public var label: String
    public var attributionStatus: String
    public var tokens: Int?
    public var sessions: Int?
    public var includedTokens: Int?
    public var includedSessions: Int?
    public var dataStatus: String
    public var providerIds: [String]
    public var detail: String

    public init(sourceId: String, label: String, attributionStatus: String = "unattributed",
                tokens: Int? = nil, sessions: Int? = nil,
                includedTokens: Int? = nil, includedSessions: Int? = nil,
                dataStatus: String = "unavailable", providerIds: [String] = [], detail: String = "") {
        self.sourceId = sourceId
        self.label = label
        self.attributionStatus = attributionStatus
        self.tokens = tokens
        self.sessions = sessions
        self.includedTokens = includedTokens
        self.includedSessions = includedSessions
        self.dataStatus = dataStatus
        self.providerIds = providerIds
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case label, tokens, sessions, detail
        case sourceId = "source_id"
        case attributionStatus = "attribution_status"
        case includedTokens = "included_tokens"
        case includedSessions = "included_sessions"
        case dataStatus = "data_status"
        case providerIds = "provider_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(String.self, forKey: .sourceId)
        guard !sourceId.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sourceId, in: c, debugDescription: "Missing source identity")
        }
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? sourceId
        attributionStatus = (try? c.decodeIfPresent(String.self, forKey: .attributionStatus)) ?? "unattributed"
        func count(_ key: CodingKeys) -> Int? {
            guard let value = try? c.decodeIfPresent(Int.self, forKey: key), value >= 0 else { return nil }
            return value
        }
        tokens = count(.tokens)
        sessions = count(.sessions)
        includedTokens = count(.includedTokens)
        includedSessions = count(.includedSessions)
        dataStatus = (try? c.decodeIfPresent(String.self, forKey: .dataStatus)) ?? "unavailable"
        if tokens == nil && sessions == nil && dataStatus == "available" { dataStatus = "unavailable" }
        providerIds = (try? c.decodeIfPresent([String].self, forKey: .providerIds)) ?? []
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
    }
}
