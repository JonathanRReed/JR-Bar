import Testing
@testable import JRBarCore

/// Synced lyrics: the pure half — LRC parsing, timestamp order,
/// playhead selection, and the query's cache-key rules. The fetch
/// layer is thin URLSession code; every decision that can go wrong
/// lives here.
@Suite struct LyricsTests {

    // MARK: - Parsing

    @Test func parsesStampedLinesInOrder() {
        let lrc = """
            [00:00.15] Is this the real life?
            [00:07.13] Caught in a landslide
            [00:14.77] Open your eyes
            """
        let synced = SyncedLyrics.parse(lrc)
        #expect(synced.lines.count == 3)
        #expect(synced.lines[0].time == 0.15)
        #expect(synced.lines[2].text == "Open your eyes")
    }

    @Test func outOfOrderStampsSort() {
        let lrc = """
            [00:30.00] second
            [00:05.00] first
            """
        let synced = SyncedLyrics.parse(lrc)
        #expect(synced.lines.map(\.text) == ["first", "second"])
    }

    @Test func metadataTagsAreSkipped() {
        let lrc = """
            [ti:Bohemian Rhapsody]
            [ar:Queen]
            [offset:+250]
            [la:eng]
            [00:01.00] real line
            """
        let synced = SyncedLyrics.parse(lrc)
        #expect(synced.lines.count == 1)
        #expect(synced.lines[0].text == "real line")
    }

    @Test func multiStampLineYieldsAnEntryPerStamp() {
        // Rare but legal: [t1][t2] text — the text repeats at both.
        let synced = SyncedLyrics.parse("[00:10.00][00:20.00] chorus")
        #expect(synced.lines.count == 2)
        #expect(synced.lines.allSatisfy { $0.text == "chorus" })
    }

    @Test func karaokeTagsStripFromTheText() {
        let synced = SyncedLyrics.parse("[00:05.00] hel<00:05.50>lo <00:05.80>world")
        #expect(synced.lines.first?.text == "hello world")
    }

    @Test func untaggedAndMalformedLinesNeverLand() {
        let lrc = """
            not a stamp at all
            [xx:yy] bad tag
            [99:99.99] out of range seconds
            [00:10.00] good
            """
        let synced = SyncedLyrics.parse(lrc)
        #expect(synced.lines.count == 1)
        #expect(synced.lines[0].text == "good")
    }

    @Test func emptyAndGarbagePayloadsYieldEmpty() {
        #expect(SyncedLyrics.parse("").lines.isEmpty)
        #expect(SyncedLyrics.parse("plain lyrics\nno stamps").lines.isEmpty)
        #expect(SyncedLyrics.parse("[ti:only metadata]").lines.isEmpty)
    }

    @Test func stampPrecision() {
        #expect(SyncedLyrics.stamp("01:23.45") == 83.45)
        #expect(SyncedLyrics.stamp("01:23") == 83)
        #expect(SyncedLyrics.stamp("01:23.456") == 83.456)
        #expect(SyncedLyrics.stamp("ti:title") == nil)
        #expect(SyncedLyrics.stamp("offset") == nil)
        #expect(SyncedLyrics.stamp("01:75") == nil)  // 75 s is not a stamp
    }

    // MARK: - Line selection

    private func fixture() -> SyncedLyrics {
        SyncedLyrics.parse("""
            [00:05.00] first
            [00:10.00] second
            [00:15.00]
            [00:20.00] third
            """)
    }

    @Test func beforeTheFirstStampIsSilence() {
        #expect(fixture().line(at: 0) == nil)
        #expect(fixture().line(at: 4.99) == nil)
    }

    @Test func atAndBetweenStamps() {
        let lyrics = fixture()
        #expect(lyrics.line(at: 5.0) == "first")   // exactly on
        #expect(lyrics.line(at: 9.99) == "first")  // holds to the next
        #expect(lyrics.line(at: 10.0) == "second")
        #expect(lyrics.line(at: 99) == "third")    // past the end holds
    }

    @Test func aBlankLyricLineIsAQuietGap() {
        // The [00:15.00] breath: the gap shows nothing, not "second".
        #expect(fixture().line(at: 17) == nil)
        #expect(fixture().line(at: 20) == "third")
    }

    // MARK: - Query

    @Test func queryNeedsTitleAndArtist() {
        let bare = AlcoveMedia(title: "Song", artist: nil, playing: true)
        #expect(LyricsQuery(media: bare) == nil)
        let blank = AlcoveMedia(title: " ", artist: "  ", playing: true)
        #expect(LyricsQuery(media: blank) == nil)
        let full = AlcoveMedia(title: "Song", artist: "Artist",
                               album: "Alb", playing: true, duration: 200.4)
        let query = LyricsQuery(media: full)
        #expect(query?.title == "Song")
        #expect(query?.duration == 200)
    }

    @Test func cacheKeyNormalizesCase() {
        let a = LyricsQuery(title: "Song", artist: "Artist", duration: 200)
        let b = LyricsQuery(title: "SONG", artist: "artist", duration: 200)
        #expect(a.cacheKey == b.cacheKey)
        let c = LyricsQuery(title: "Song", artist: "Artist", duration: 201)
        #expect(a.cacheKey != c.cacheKey)
    }

    @Test func cacheKeysKeepFieldSeparatorsUnambiguous() {
        let queries = [
            LyricsQuery(title: "One|Two", artist: "Three", album: "Four", duration: 120),
            LyricsQuery(title: "One", artist: "Two|Three", album: "Four", duration: 120),
            LyricsQuery(title: "One", artist: "Two", album: "Three|Four", duration: 120),
        ]
        #expect(Set(queries.map(\.cacheKey)).count == queries.count)
        let same = LyricsQuery(title: "ONE|TWO", artist: "THREE", album: "FOUR", duration: 120)
        #expect(same.cacheKey == queries[0].cacheKey)
        #expect(LyricsQuery(title: "Song", artist: "Artist", duration: 200).cacheKey == "song|artist||200")
    }

    @Test func encodedCacheKeysKeepUnicodeAndEmptyFieldsDistinct() {
        let queries = [
            LyricsQuery(title: "Écho|", artist: "声", album: ""),
            LyricsQuery(title: "Écho", artist: "|声", album: ""),
            LyricsQuery(title: "Écho", artist: "声", album: "|"),
            LyricsQuery(title: "Écho|", artist: "声", album: "", duration: 0),
        ]
        #expect(Set(queries.map(\.cacheKey)).count == queries.count)
        let uppercase = LyricsQuery(title: "ÉCHO|", artist: "声", album: nil)
        #expect(uppercase.cacheKey == queries[0].cacheKey)
        // Ordinary keys always have separators, so a version-like title
        // cannot collide with the encoded keys.
        let ordinary = LyricsQuery(title: queries[0].cacheKey, artist: "声")
        #expect(ordinary.cacheKey != queries[0].cacheKey)
        #expect(LyricsQuery(title: "Song", artist: "Artist").cacheKey == "song|artist||")
    }

    /// A nonfinite duration stays unknown. Large finite values clamp to a day.
    @Test func nonFiniteAndAbsurdDurationsNeverTrap() {
        let nan = AlcoveMedia(title: "S", artist: "A", playing: true,
                              duration: .nan)
        #expect(LyricsQuery(media: nan)?.duration == nil)
        let inf = AlcoveMedia(title: "S", artist: "A", playing: true,
                              duration: .infinity)
        #expect(LyricsQuery(media: inf)?.duration == nil)
        let huge = AlcoveMedia(title: "S", artist: "A", playing: true,
                               duration: 1e30)
        #expect(LyricsQuery(media: huge)?.duration == 86_400)
        let negative = AlcoveMedia(title: "S", artist: "A", playing: true,
                                   duration: -5)
        #expect(LyricsQuery(media: negative)?.duration == 0)
    }
}
