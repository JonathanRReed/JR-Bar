import Foundation
import Testing
@testable import JRBarApp

/// The lyric sweep's clock: the display's rate only while a track plays
/// and the row can be seen, a calm step under Reduce Motion, and no
/// clock at all out of sight.
@Suite struct LyricLinesClockTests {
    @Test("the sweep runs at 30 fps only while it plays and can be seen")
    func live() {
        let clock = LyricLines.clock(playing: true, reduceMotion: false, visible: true)
        #expect(clock.interval == 1.0 / 30.0)
        #expect(!clock.paused)
        #expect(clock.sweeps)
    }

    @Test("out of sight — covered, another Space, scrolled away — the clock stops")
    func hidden() {
        let clock = LyricLines.clock(playing: true, reduceMotion: false, visible: false)
        #expect(clock.paused, "no redraws for a row nobody can see")
        #expect(!clock.sweeps)
        #expect(LyricLines.clock(playing: true, reduceMotion: true, visible: false).paused)
    }

    @Test("a paused track stops the clock; Reduce Motion steps calmly with no sweep")
    func pausedAndCalm() {
        let paused = LyricLines.clock(playing: false, reduceMotion: false, visible: true)
        #expect(paused.paused && !paused.sweeps)
        let calm = LyricLines.clock(playing: true, reduceMotion: true, visible: true)
        #expect(!calm.paused)
        #expect(!calm.sweeps)
        #expect(calm.interval == 0.5)
    }
}
