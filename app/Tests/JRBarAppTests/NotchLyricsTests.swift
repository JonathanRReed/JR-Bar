import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Lyrics that keep time and keep quiet: the LRC offset applied, the
/// next line and the sweep's progress, the lookups remembered across
/// launches, and the switch that sends nothing. No network — every
/// store here answers from its disk cache or not at all.
@Suite("Notch lyrics")
@MainActor
struct NotchLyricsTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "jrbar-test-lyrics-\(UUID().uuidString).json")
    }

    @Test("the offset tag moves every stamp, sooner for a positive offset")
    func offset() throws {
        #expect(SyncedLyrics.offsetMilliseconds(in: "[ti:x]\n[offset:+250]\n[00:01.00] a") == 250)
        #expect(SyncedLyrics.offsetMilliseconds(in: "[offset: -500]") == -500)
        #expect(SyncedLyrics.offsetMilliseconds(in: "[00:01.00] a") == nil)
        let lrc = "[offset:500]\n[00:00.20] first\n[00:02.00] second"
        let shifted = SyncedLyrics.parse(lrc).applyingOffset(in: lrc)
        #expect(shifted.lines.map(\.time) == [0, 1.5], "clamped at the top of the track")
        let later = "[offset:-1000]\n[00:02.00] a"
        #expect(SyncedLyrics.parse(later).applyingOffset(in: later).lines.first?.time == 3)
        let record = try JSONDecoder().decode(LRCLIBRecord.self,
                                              from: Data(#"{"syncedLyrics":"[offset:1000]\n[00:03.00] hi"}"#.utf8))
        #expect(record.synced?.line(at: 2.1) == "hi", "the record's lyrics arrive on time")
    }

    @Test("the next line and how far through the current one the playhead is")
    func position() {
        let lyrics = SyncedLyrics.parse("[00:10.00] one\n[00:12.00] \n[00:14.00] two\n[00:18.00] three")
        let before = lyrics.position(at: 5)
        #expect(before.next == "one")
        #expect(before.progress == nil)
        let mid = lyrics.position(at: 15)
        #expect(mid.next == "three")
        #expect(abs((mid.progress ?? 0) - 0.25) < 0.001)
        let gap = lyrics.position(at: 12.5)
        #expect(gap.next == "two", "a breath between verses skips to the next words")
        let last = lyrics.position(at: 20)
        #expect(last.next == nil)
        #expect(last.progress == 0.5, "the last line sweeps over four seconds")
    }

    @Test("hits and misses survive a relaunch; a miss is retried after a week")
    func diskCache() {
        let url = tempURL()
        let now = Date()
        let lyrics = SyncedLyrics(lines: [.init(time: 1, text: "hello")])
        let first = LyricsDiskCache(url: url)
        #expect(first.lookup("song") == nil, "never looked up")
        first.store(lyrics, for: "song", now: now)
        first.store(nil, for: "instrumental", now: now)

        let relaunched = LyricsDiskCache(url: url)
        #expect(relaunched.lookup("song", now: now) == .some(lyrics))
        #expect(relaunched.lookup("instrumental", now: now) == .some(nil), "a remembered miss")
        #expect(relaunched.lookup("instrumental",
                                  now: now.addingTimeInterval(LyricsDiskCache.missLife + 1)) == nil,
                "lyrics get added; a week-old miss asks again")
        #expect(relaunched.lookup("song", now: now.addingTimeInterval(365 * 86_400)) == .some(lyrics))
    }

    @Test("the cache holds its cap, oldest out")
    func diskCap() {
        let cache = LyricsDiskCache(url: tempURL())
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0...LyricsDiskCache.cap {
            cache.store(nil, for: "k\(i)", now: start.addingTimeInterval(Double(i)))
        }
        #expect(cache.lookup("k0", now: start) == nil, "the oldest fell out")
        #expect(cache.lookup("k\(LyricsDiskCache.cap)", now: start) == .some(nil))
    }

    @Test("a known track answers from disk; the switch off answers nothing")
    func storeFromDisk() {
        let url = tempURL()
        let media = AlcoveMedia(title: "Papillon", artist: "Editors", playing: true)
        let key = LyricsQuery(media: media)!.cacheKey
        LyricsDiskCache(url: url).store(SyncedLyrics(lines: [.init(time: 0, text: "la")]), for: key)

        let store = LyricsStore(diskURL: url)
        store.note(media: media)
        #expect(store.lyrics?.lines.first?.text == "la", "no network: the disk knew")

        let off = LyricsStore(diskURL: url)
        off.enabled = { false }
        off.note(media: media)
        #expect(off.lyrics == nil)
        #expect(NotchSettings().lyrics, "on by default, as it shipped")
    }
}
