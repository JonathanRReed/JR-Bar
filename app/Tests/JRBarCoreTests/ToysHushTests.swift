import CoreGraphics
import Foundation
import Testing
import JRBarCore

/// The toys' manners: the daemon's quiet reading, call presence and
/// fullscreen screens decide whether a celebration plays now, waits, or
/// is let go.
@Suite("Toys hush")
struct ToysHushTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("off, normal or missing is a clear room")
    func normalIsClear() {
        // The daemon's own word for nothing quiet (docs/CORE-PROTOCOL.md):
        // `off`, never null — the reading every connected app sees.
        #expect(ToysHush.quietReason(mode: "off", source: nil, until: nil, now: now) == nil)
        #expect(ToysHush.quietReason(mode: " OFF ", source: nil, until: nil, now: now) == nil)
        #expect(ToysHush.reason(mode: "off", source: nil, until: nil, onCall: false, now: now) == nil)
        #expect(ToysHush.quietReason(mode: nil, source: nil, until: nil, now: now) == nil)
        #expect(ToysHush.quietReason(mode: "normal", source: "schedule", until: nil, now: now) == nil)
        #expect(ToysHush.quietReason(mode: " Normal ", source: nil, until: nil, now: now) == nil)
        #expect(ToysHush.quietReason(mode: "", source: nil, until: nil, now: now) == nil)
    }

    @Test("any quiet mode hushes; a Focus names itself")
    func quietModes() {
        for mode in ["mute", "dim", "dark", "pause", "asks_only", "dnd"] {
            #expect(ToysHush.quietReason(mode: mode, source: "manual", until: nil, now: now) == .quiet)
        }
        #expect(ToysHush.quietReason(mode: "dnd", source: "focus", until: nil, now: now) == .focus)
        #expect(ToysHush.quietReason(mode: "dnd", source: "Focus", until: nil, now: now) == .focus)
    }

    @Test("a quiet whose until has passed is over")
    func expiredQuiet() {
        let t = now.timeIntervalSince1970
        #expect(ToysHush.quietReason(mode: "dnd", source: "manual", until: t - 1, now: now) == nil)
        #expect(ToysHush.quietReason(mode: "dnd", source: "manual", until: t + 60, now: now) == .quiet)
        #expect(ToysHush.quietReason(mode: "dnd", source: "manual", until: 0, now: now) == .quiet,
                "a zero until is no deadline")
    }

    @Test("a call outranks the quiet reading")
    func callOutranks() {
        #expect(ToysHush.reason(mode: "dnd", source: "focus", until: nil, onCall: true, now: now) == .call)
        #expect(ToysHush.reason(mode: nil, source: nil, until: nil, onCall: true, now: now) == .call)
        #expect(ToysHush.reason(mode: nil, source: nil, until: nil, onCall: false, now: now) == nil)
    }

    @Test("every reason has words for the chip")
    func reasonsHaveText() {
        for reason in ToysHush.Reason.allCases { #expect(!reason.text.isEmpty) }
    }

    @Test("a clear room with a free screen fires; otherwise the card's pick")
    func verdicts() {
        #expect(ConfettiRoom.verdict(hush: nil, freeScreens: 1, whenHeld: .later) == .fire)
        #expect(ConfettiRoom.verdict(hush: nil, freeScreens: 1, whenHeld: .drop) == .fire)
        #expect(ConfettiRoom.verdict(hush: .focus, freeScreens: 2, whenHeld: .later) == .hold)
        #expect(ConfettiRoom.verdict(hush: .call, freeScreens: 2, whenHeld: .drop) == .drop)
        #expect(ConfettiRoom.verdict(hush: nil, freeScreens: 0, whenHeld: .later) == .hold,
                "every screen fullscreen is a hush of its own")
    }

    @Test("a held burst goes stale after half an hour")
    func holdLimit() {
        #expect(ConfettiRoom.stillWorthPlaying(heldAt: now, now: now.addingTimeInterval(60)))
        #expect(ConfettiRoom.stillWorthPlaying(heldAt: now, now: now.addingTimeInterval(ConfettiRoom.holdLimit)))
        #expect(!ConfettiRoom.stillWorthPlaying(heldAt: now,
                                                now: now.addingTimeInterval(ConfettiRoom.holdLimit + 1)))
        #expect(ConfettiRoom.replayDensity < 1)
    }

    @Test("a window covering a whole screen is fullscreen; a zoomed one is not")
    func coveredScreens() {
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let fullscreen = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        // A zoomed window stops under the menu bar.
        let zoomed = CGRect(x: 0, y: 33, width: 1512, height: 949)
        #expect(ConfettiRoom.coveredScreens(windows: [zoomed], screens: [builtIn, external]).isEmpty)
        #expect(ConfettiRoom.coveredScreens(windows: [zoomed, fullscreen],
                                            screens: [builtIn, external]) == [1])
        let halfPoint = CGRect(x: 0.4, y: 0, width: 1512.5, height: 982)
        #expect(ConfettiRoom.coveredScreens(windows: [halfPoint], screens: [builtIn]) == [0],
                "a scaled display's fractional point still matches")
        #expect(ConfettiRoom.coveredScreens(windows: [builtIn], screens: [.zero]).isEmpty)
    }

    @Test("the new confetti and page settings decode tolerantly")
    func settingsDecode() throws {
        let empty = try JSONDecoder().decode(ToysState.self, from: Data("{}".utf8))
        #expect(empty.hushDuringQuiet == true)
        #expect(empty.confetti.whenHeld == .later)
        #expect(empty.confetti.sound == false)
        #expect(empty.confetti.triggers.milestones == false)
        let junk = try JSONDecoder().decode(ToysState.self, from: Data(#"""
            {"hushDuringQuiet": "no", "confetti": {"whenHeld": "never", "sound": 3,
             "triggers": {"milestones": "yes"}}}
            """#.utf8))
        #expect(junk.hushDuringQuiet == true)
        #expect(junk.confetti.whenHeld == .later)
        #expect(junk.confetti.sound == false)
        #expect(junk.confetti.triggers.milestones == false)
        var state = ToysState()
        state.hushDuringQuiet = false
        state.confetti.whenHeld = .drop
        state.confetti.sound = true
        state.confetti.triggers.milestones = true
        let round = try JSONDecoder().decode(ToysState.self, from: JSONEncoder().encode(state))
        #expect(round == state)
    }
}
