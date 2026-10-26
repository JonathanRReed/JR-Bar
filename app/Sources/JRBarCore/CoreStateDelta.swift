import Foundation

public struct CoreStateDelta: Codable, Hashable, Sendable {
    public struct Edit: Codable, Hashable, Sendable {
        public var path: [String]
        public var value: JSONValue?
        public var remove: Bool?
    }
    public struct Slice: Codable, Hashable, Sendable {
        public var generation: Int
        public var value: JSONValue
        public var changes: [String: [String: JSONValue]]?
        public var removed: [String]?
        public var order: [String]?
        public var patch: [Edit]?

        enum CodingKeys: String, CodingKey { case generation, value, changes, removed, order, patch }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            generation = try values.decode(Int.self, forKey: .generation)
            value = try values.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
            changes = try values.decodeIfPresent([String: [String: JSONValue]].self, forKey: .changes)
            removed = try values.decodeIfPresent([String].self, forKey: .removed)
            order = try values.decodeIfPresent([String].self, forKey: .order)
            patch = try values.decodeIfPresent([Edit].self, forKey: .patch)
            guard values.contains(.value) || patch != nil || (changes != nil && removed != nil && order != nil) else {
                throw CoreCodecError.malformed("slice has no value or complete row changes")
            }
        }
    }

    public var generation: Int
    public var now: Double?
    public var slices: [String: Slice]
}
