import Foundation

/// Coverage of positive-token records in the chart's selected range and providers.
public struct CoreUsageCostCoverage: Codable, Hashable, Sendable {
    public var observedRecords: Int
    public var pricedRecords: Int
    public var unpricedRecords: Int
    /// Sessions with any unpriced usage, including mixed-model sessions.
    public var unpricedSessions: Int
    public var tokenCategories: TokenCategories

    public struct TokenCategories: Codable, Hashable, Sendable {
        public var input: Int
        public var cachedInput: Int
        public var cacheCreation: Int
        public var output: Int

        enum CodingKeys: String, CodingKey {
            case input, output
            case cachedInput = "cached_input"
            case cacheCreation = "cache_creation"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = try c.decode(Int.self, forKey: .input)
            cachedInput = try c.decode(Int.self, forKey: .cachedInput)
            cacheCreation = try c.decode(Int.self, forKey: .cacheCreation)
            output = try c.decode(Int.self, forKey: .output)
            guard [input, cachedInput, cacheCreation, output].allSatisfy({ $0 >= 0 }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Negative unpriced token count"))
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case observedRecords = "observed_records"
        case pricedRecords = "priced_records"
        case unpricedRecords = "unpriced_records"
        case unpricedSessions = "unpriced_sessions"
        case tokenCategories = "token_categories"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedRecords = try c.decode(Int.self, forKey: .observedRecords)
        pricedRecords = try c.decode(Int.self, forKey: .pricedRecords)
        unpricedRecords = try c.decode(Int.self, forKey: .unpricedRecords)
        unpricedSessions = try c.decode(Int.self, forKey: .unpricedSessions)
        tokenCategories = try c.decode(TokenCategories.self, forKey: .tokenCategories)
        guard observedRecords >= 0, pricedRecords >= 0, unpricedRecords >= 0,
              unpricedSessions >= 0, pricedRecords <= observedRecords,
              unpricedRecords == observedRecords - pricedRecords,
              unpricedSessions <= unpricedRecords else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Inconsistent cost coverage counts"))
        }
    }
}
