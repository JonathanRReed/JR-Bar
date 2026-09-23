import Testing
@testable import JRBarCore

/// The bounded memo: at most `limit` keys, the least recently stored or
/// read forgotten first, and a peek that never reorders.
@Suite("Recency cache")
struct RecencyCacheTests {
    @Test("past its limit the cache forgets the key used longest ago")
    func forgetsOldest() {
        var cache = RecencyCache<String, Int>(limit: 3)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.set(3, for: "c")
        #expect(cache.count == 3)
        cache.set(4, for: "d")
        #expect(cache.count == 3)
        #expect(cache.peek("a") == nil, "the oldest went")
        #expect(cache.peek("d") == 4)
    }

    @Test("a read keeps a key; a peek does not")
    func readsMark() {
        var cache = RecencyCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        #expect(cache.value(for: "a") == 1)
        cache.set(3, for: "c")
        #expect(cache.peek("a") == 1, "read just now, so kept")
        #expect(cache.peek("b") == nil)

        _ = cache.peek("a")
        cache.set(4, for: "d")
        #expect(cache.peek("a") == nil, "a peek is not a use")
        #expect(cache.peek("c") == 3 && cache.peek("d") == 4)
    }

    @Test("overwriting a key refreshes it and never grows the cache")
    func overwrite() {
        var cache = RecencyCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.set(10, for: "a")
        #expect(cache.count == 2)
        cache.set(3, for: "c")
        #expect(cache.peek("a") == 10)
        #expect(cache.peek("b") == nil)
    }

    @Test("an optional value is a hit, not a miss")
    func storedNil() {
        var cache = RecencyCache<String, Int?>(limit: 2)
        cache.set(nil, for: "none")
        #expect(cache.value(for: "none") == .some(nil), "a folder with no repository is still known")
        #expect(cache.value(for: "unseen") == nil)
    }

    @Test("remove forgets one key or all; a zero limit still keeps one")
    func removal() {
        var cache = RecencyCache<String, Int>(limit: 0)
        #expect(cache.limit == 1)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        #expect(cache.count == 1 && cache.peek("b") == 2)
        cache.removeValue(forKey: "b")
        #expect(cache.count == 0)
        cache.set(3, for: "c")
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
