import Foundation

/// A dictionary that keeps at most `limit` keys and forgets the one
/// stored or read longest ago first. It is for memos a long uptime would
/// otherwise grow without end, such as a repository per folder any
/// session ever worked in or a cost per session ever read. A forgotten
/// entry is simply worked out again the next time it is wanted.
public struct RecencyCache<Key: Hashable, Value> {
    public let limit: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var count: Int { entries.count }

    /// `key`'s value, marking it used: a key read often outlives one
    /// stored once and never asked about again.
    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    /// `key`'s value without marking it: for a hot read, like a sort's
    /// comparator, that must not reorder what gets forgotten.
    public func peek(_ key: Key) -> Value? {
        entries[key]?.value
    }

    /// Store `value` for `key`, marking it used, and forget the least
    /// recently used key while there are more than `limit`.
    public mutating func set(_ value: Value, for key: Key) {
        clock &+= 1
        entries[key] = (value, clock)
        while entries.count > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            entries[oldest.key] = nil
        }
    }

    public mutating func removeValue(forKey key: Key) {
        entries[key] = nil
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

extension RecencyCache: Sendable where Key: Sendable, Value: Sendable {}
