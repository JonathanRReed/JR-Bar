import AppKit
import Foundation
import Testing
import JRBarCore
import JRBarLEDS
@testable import JRBarApp

/// The Notch Buddy's pet half: taps pet it and cycle the trick
/// repertoire, treats feed it and burst hearts, completed sessions land
/// as crumbs, and the summary line names it. `CoreModel` without a
/// daemon has no sessions, so the ask-opening half of `tapped()` is a
/// no-op here rather than faked.
@Suite("Buddy interaction")
@MainActor
struct BuddyInteractionTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makeToy(state: ToysState = ToysState()) -> (NotchBuddyToy, ToysStore) {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel())
        return (store.notchBuddy, store)
    }

    @Test("a tap is a pet and cycles the tricks")
    func tapPetsAndTricks() {
        let (toy, store) = makeToy()
        toy.tapped(at: t0)
        #expect(store.state.notchBuddy.care.petCount == 1)
        #expect(store.state.notchBuddy.care.lastInteractionAt == t0.timeIntervalSince1970)
        guard !reducedMotion else { return }
        #expect(toy.trickStartedAt == t0)
        #expect(toy.trickKind == .hop)
        toy.tapped(at: t0)
        #expect(toy.trickKind == .spin, "the repertoire cycles, never repeating")
        toy.tapped(at: t0)
        #expect(toy.trickKind == .wave)
    }

    @Test("a treat feeds, bursts hearts, and hops when motion is on")
    func treatFeeds() {
        let (toy, store) = makeToy()
        toy.giveTreat(at: t0)
        #expect(store.state.notchBuddy.care.treatsGiven == 1)
        #expect(store.state.notchBuddy.care.petCount == 1, "a treat is also a pat")
        #expect(store.state.notchBuddy.care.mood(at: t0) == .fed)
        #expect(toy.treatBurstAt == t0)
        if reducedMotion {
            #expect(toy.hopUntil == nil)
        } else {
            #expect(toy.hopUntil == t0.addingTimeInterval(1.1))
        }
    }

    @Test("the name field writes through and the summary names the buddy")
    func naming() {
        let (toy, store) = makeToy()
        #expect(toy.buddyName == "Dot")
        #expect(toy.summary(at: t0).statusLine == "Dot is asleep.")
        toy.nameBinding.wrappedValue = "Pixel"
        #expect(store.state.notchBuddy.buddyName == "Pixel")
        #expect(toy.buddyName == "Pixel")
        #expect(toy.summary(at: t0).statusLine == "Pixel is asleep.")
        toy.nameBinding.wrappedValue = "   "
        #expect(toy.buddyName == "Dot", "spaces are not a name")
        store.state.notchBuddy.character = "crab"
        #expect(toy.buddyName == "Pinch")
    }

    @Test("a day of quiet turns the summary to missing, and says so")
    func missing() {
        var state = ToysState()
        state.notchBuddy.care.pet(at: t0.addingTimeInterval(-BuddyCare.lonelyAfter - 60))
        let (toy, store) = makeToy(state: state)
        let summary = toy.summary(at: t0)
        #expect(summary.care == .missing)
        #expect(summary.statusLine == "Dot misses you — tap it to say hi.")
        _ = store  // the toy's link to the store is weak; hold it
    }

    @Test("the card's friendship line reports pets and crumbs")
    func careLineReports() {
        let (toy, store) = makeToy()
        #expect(toy.careLine == "Never petted. It doesn't mind yet.")
        store.state.notchBuddy.care.pet(at: Date())
        store.state.notchBuddy.care.eat(at: Date(), count: 3)
        #expect(toy.careLine == "1 pet · 3 crumbs")
        store.state.notchBuddy.care.feed(at: Date())
        #expect(toy.careLine.hasPrefix("Blissed out"))
    }

    // MARK: Docked presentation

    @Test("the character stays in the slot; only Mini wears the dot")
    func dockedPresentation() {
        let (toy, store) = makeToy()
        #expect(toy.showsDot == false, "the docked slot is the character")
        // A published program no longer swaps the character for a seam
        // LED — one unsegmented Screen Bar, no second light beside it.
        applyProgram("#FF9F0A 1.6s pulse\nrepeat", anchor: t0.timeIntervalSince1970, to: toy.core)
        #expect(toy.showsDot == false, "a published program leaves the character in place")
        store.state.notchBuddy.presentation = "mini"
        #expect(toy.showsDot == true)
    }

    @Test("docked under a published program the buddy wears the band's hue, steady")
    func seamTintWearsTheBand() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        #expect(toy.seamTint(at: epoch) == nil, "nothing published, nothing worn")
        applyProgram("off 160ms cosine\n#FF9F0A 1.6s pulse\nrepeat", anchor: epoch, to: toy.core)
        // Mid-trough and mid-peak read the same colour: a hue to wear,
        // never a level that pulses with the band.
        let trough = toy.seamTint(at: epoch + 0.17)
        let peak = toy.seamTint(at: epoch + 0.96)
        #expect(trough != nil)
        #expect(trough == peak)
        #expect(abs((trough?.maxChannel ?? 0) - 1) < 1e-9, "worn at full strength")
        #expect((trough?.r ?? 0) > (trough?.b ?? 1), "amber stays amber")
        store.state.notchBuddy.wearsStripColor = false
        #expect(toy.seamTint(at: epoch) == nil, "the card can turn it off")
    }

    @Test("a seam too dark to name a colour is not worn")
    func darkSeamIsNotWorn() {
        #expect(NotchBuddyToy.wornHue(RGB(r: 0.01, g: 0.02, b: 0.0)) == nil)
        let hue = NotchBuddyToy.wornHue(RGB(r: 0.2, g: 0.1, b: 0.0))
        #expect(hue == RGB(r: 1, g: 0.5, b: 0))
    }

    @Test("the strip-colour switch decodes tolerantly and defaults on")
    func wearsStripColorDecodes() throws {
        let empty = try JSONDecoder().decode(NotchBuddySettings.self, from: Data("{}".utf8))
        #expect(empty.wearsStripColor == true)
        let off = try JSONDecoder().decode(NotchBuddySettings.self,
                                           from: Data(#"{"wearsStripColor": false}"#.utf8))
        #expect(off.wearsStripColor == false)
        let junk = try JSONDecoder().decode(NotchBuddySettings.self,
                                            from: Data(#"{"wearsStripColor": "yes"}"#.utf8))
        #expect(junk.wearsStripColor == true)
        var settings = NotchBuddySettings()
        settings.wearsStripColor = false
        let round = try JSONDecoder().decode(NotchBuddySettings.self,
                                             from: JSONEncoder().encode(settings))
        #expect(round.wearsStripColor == false)
    }

    // MARK: Strip link

    /// A lights document with `program` on the screen_bar surface.
    private func applyProgram(_ program: String, anchor: Double?, to core: CoreModel) {
        core.apply(.lights(CoreLights(surfaces: [
            "screen_bar": CoreLightSurface(program: program, anchor: anchor)
        ])))
    }

    @Test("with nothing published the dot has no link")
    func stripDotNeedsAProgram() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        #expect(toy.stripDot(at: epoch) == nil)
        applyProgram("  \n", anchor: epoch, to: toy.core)
        #expect(toy.stripDot(at: epoch) == nil)
        _ = store
    }

    @Test("the docked dot rides the program's anchor — bright at the peak, dark in the trough")
    func stripDotFollowsTheAnchor() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        // off for 160 ms, then a 1.6 s pulse — peak at 960 ms, dark at
        // both ends — looping. The daemon's ask pulse, shape-for-shape.
        applyProgram("off 160ms cosine\n#FF9F0A 1.6s pulse\nrepeat",
                     anchor: epoch, to: toy.core)
        let trough = toy.stripDot(at: epoch + 0.17)
        let peak = toy.stripDot(at: epoch + 0.16 + 0.8)
        #expect(trough != nil)
        #expect((trough?.maxChannel ?? 1) < 0.1, "the trough reaches the dot")
        #expect((peak?.maxChannel ?? 0) > 0.9, "the peak reaches the dot at full strength")
        // A whole lap later the phase is the same — the repeat loops.
        #expect((toy.stripDot(at: epoch + 1.76 + 0.16 + 0.8)?.maxChannel ?? 0) > 0.9)
        _ = store
    }

    @Test("the anchor, not the first sighting, is the clock")
    func stripDotUsesTheAnchorNotFirstSeen() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        // Anchored five seconds ago: the first frame the toy ever samples
        // already reads the true phase — no first-poll wrongness, no
        // inverted lap while a local clock catches up.
        applyProgram("off 160ms cosine\n#FF9F0A 1.6s pulse\nrepeat",
                     anchor: epoch - 5.0, to: toy.core)
        // 5000 ms in = lap 2's 1480 ms: 1320 into the 1600 ms pulse →
        // easing out of the peak, mid-bright — where a "starts now"
        // clock would still be on the dark lead-in.
        let dot = toy.stripDot(at: epoch)
        #expect(dot != nil)
        #expect((dot?.maxChannel ?? 0) > 0.15)
        #expect((dot?.maxChannel ?? 1) < 0.9)
        _ = store
    }

    @Test("a republished program with a moved anchor re-locks the dot")
    func stripDotReanchors() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        let program = "off 160ms cosine\n#FF9F0A 1.6s pulse\nrepeat"
        applyProgram(program, anchor: epoch, to: toy.core)
        #expect((toy.stripDot(at: epoch + 0.96)?.maxChannel ?? 0) > 0.9)
        // Same text, anchor pushed half a pulse later: the cached sampler
        // stays, the phase word moves — at the same instant the dot now
        // reads the rising edge, not the peak.
        applyProgram(program, anchor: epoch + 0.5, to: toy.core)
        let shifted = toy.stripDot(at: epoch + 0.96)
        #expect((shifted?.maxChannel ?? 1) < 0.6)
        _ = store
    }

    @Test("the dot reads the seam under the notch, not the strip's edge")
    func stripDotReadsTheCentreSeam() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        // LED 0 alone pulses while the seam LEDs wait on their delays —
        // the travelling "working" relay's first beat. A dot that
        // mirrored the strip's brightest LED would flash now; the seam's
        // extension stays dark until the wave reaches the notch.
        applyProgram("0:#00E5FF 1400ms pulse 0ms; 3:#00E5FF 1400ms pulse 510ms; 4:#00E5FF 1400ms pulse 680ms\nrepeat",
                     anchor: epoch, to: toy.core)
        let early = toy.stripDot(at: epoch + 0.7)   // LED 0 mid-pulse, seam still waiting
        #expect((early?.maxChannel ?? 1) < 0.2)
        let crossing = toy.stripDot(at: epoch + 0.68 + 0.7)  // LED 4's peak
        #expect((crossing?.maxChannel ?? 0) > 0.9)
        _ = store
    }

    @Test("Reduce Motion holds the link at the pulse's peak")
    func stripDotStillHoldsThePeak() {
        let (toy, store) = makeToy()
        let epoch = t0.timeIntervalSince1970
        applyProgram("off 160ms cosine\n#FF9F0A 1.6s pulse\nrepeat",
                     anchor: epoch, to: toy.core)
        // Asked mid-trough, the still frame still shows the peak.
        let still = toy.stripDot(at: epoch + 0.17, still: true)
        #expect((still?.maxChannel ?? 0) > 0.9)
        _ = store
    }
}
