import Foundation
import SwiftUI
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The ears' own marks: the ask-age ring on the asking session's mark
/// and the moon while a quiet dims the lights — marks only, words in
/// VoiceOver and the peek.
@Suite("Screen Bar ear marks")
@MainActor
struct ScreenBarEarMarksTests {
    private static let opened = Date(timeIntervalSince1970: 1_800_000_000)

    private static func age(fullAfter: TimeInterval = 300, provider: String = "claude") -> ScreenBarAskAge {
        ScreenBarAskAge(openedAt: opened, fullAfter: fullAfter, provider: provider)
    }

    // MARK: Ask age

    @Test func fullRingIsTheLoudestStageTheTierAllows() {
        #expect(ScreenBarAskAge.span(tier: "light", ramp: 20, menuBar: 90, final: 400) == 20)
        #expect(ScreenBarAskAge.span(tier: "menu_bar", ramp: 20, menuBar: 90, final: 400) == 90)
        #expect(ScreenBarAskAge.span(tier: "chime", ramp: 20, menuBar: 90, final: 400) == 400)
        #expect(ScreenBarAskAge.span(tier: "takeover", ramp: 20, menuBar: 90, final: 400) == 400)
        // Off still ages the ring, on the final stage's clock.
        #expect(ScreenBarAskAge.span(tier: "off", ramp: 20, menuBar: 90, final: 400) == 400)
        // The daemon's defaults when the document says nothing: menu bar, 120 s.
        #expect(ScreenBarAskAge.span(tier: nil, ramp: nil, menuBar: nil, final: nil) == 120)
    }

    @Test func fractionFillsWithTheWaitAndClamps() {
        let age = Self.age()
        #expect(age.fraction(at: Self.opened.addingTimeInterval(-5)) == 0)
        #expect(age.fraction(at: Self.opened) == 0)
        #expect(abs(age.fraction(at: Self.opened.addingTimeInterval(75)) - 0.25) < 1e-9)
        #expect(age.fraction(at: Self.opened.addingTimeInterval(3000)) == 1)
    }

    @Test func aProvidersCeilingOnlyEverLowersTheRing() {
        #expect(ScreenBarAskAge.tier(global: "chime", provider: "light") == "light")
        #expect(ScreenBarAskAge.tier(global: "menu_bar", provider: "takeover") == "menu_bar", "a ceiling never raises the stage")
        #expect(ScreenBarAskAge.tier(global: "off", provider: "light") == "off", "nothing escalates with the ladder off")
        #expect(ScreenBarAskAge.tier(global: "chime", provider: nil) == "chime")
        let document = SettingsDocument(.object([
            "escalation_tier": .string("chime"),
            "escalation_ramp_seconds": .number(20),
            "escalation_final_seconds": .number(400),
            "escalation_tier_by_provider": .object(["codex": .string("light")]),
        ]))
        let codex = ScreenBarAskAge.make(ask: CoreAsk(session: "s", openedAt: 100), provider: "codex", document: document)
        let claude = ScreenBarAskAge.make(ask: CoreAsk(session: "s", openedAt: 100), provider: "claude", document: document)
        #expect(codex?.fullAfter == 20, "Codex's asks stop at the light, so its ring is full at the ramp")
        #expect(claude?.fullAfter == 400)
    }

    @Test func undatedAskHasNoRing() {
        let document = SettingsDocument()
        #expect(ScreenBarAskAge.make(ask: CoreAsk(session: "s"), provider: "claude", document: document) == nil)
        let dated = ScreenBarAskAge.make(ask: CoreAsk(session: "s", openedAt: 100), provider: "codex",
                                         document: SettingsDocument(.object([
                                             "escalation_tier": .string("chime"),
                                             "escalation_final_seconds": .number(600),
                                         ])))
        #expect(dated?.fullAfter == 600)
        #expect(dated?.openedAt == Date(timeIntervalSince1970: 100))
        #expect(dated?.provider == "codex")
    }

    @Test func scheduleRedrawsAboutAHundredTimesThenRests() {
        let age = Self.age(fullAfter: 300)
        let entries = Array(ScreenBarAskAgeSchedule(age: age).entries(from: Self.opened, mode: .normal))
        #expect(entries.first == Self.opened)
        #expect(entries.last == age.fullAt, "the last redraw lands exactly on full")
        #expect(entries.count <= Int(ScreenBarAskAgeSchedule.steps) + 2)
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0 < $1 })
        // A ring already full draws once and stops.
        let late = Array(ScreenBarAskAgeSchedule(age: age).entries(from: age.fullAt.addingTimeInterval(60), mode: .normal))
        #expect(late.count == 1)
        // A long ladder still keeps its redraws to the step budget.
        let long = Self.age(fullAfter: 14_400)
        let longEntries = Array(ScreenBarAskAgeSchedule(age: long).entries(from: Self.opened, mode: .lowFrequency))
        #expect(longEntries.count <= Int(ScreenBarAskAgeSchedule.steps / 4) + 2)
    }

    @Test func ringLandsOnlyOnTheAskingSessionsMark() {
        let marks = ScreenBarEarMarks(askAge: Self.age(provider: "claude"))
        let asking = ScreenBarWings(left: ScreenBarWingSlot(text: "Needs you", provider: "claude", tone: .attention))
        #expect(ScreenBarEarMarks.apply(marks, to: asking).left?.askAge == Self.age(provider: "claude"))
        // A working ear is not an ask; another provider's ear is not this ask.
        let working = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "claude"))
        #expect(ScreenBarEarMarks.apply(marks, to: working).left?.askAge == nil)
        let other = ScreenBarWings(left: ScreenBarWingSlot(text: "Needs you", provider: "codex", tone: .attention))
        #expect(ScreenBarEarMarks.apply(marks, to: other).left?.askAge == nil)
        // The right ear is the meter's — never dressed.
        let right = ScreenBarWings(right: ScreenBarWingSlot(text: "42%", provider: "claude", meter: 0.42, tone: .attention))
        #expect(ScreenBarEarMarks.apply(marks, to: right).right?.askAge == nil)
    }

    @Test func ringDoesNotChangeTheWingsSubject() {
        let bare = ScreenBarWingSlot(text: "Needs you", provider: "claude", tone: .attention)
        var ringed = bare
        ringed.askAge = Self.age()
        #expect(ScreenBarController.sameWingSubject(bare, ringed),
                "a dismissed ask ear must stay dismissed when its ring starts")
    }

    // MARK: Quiet moon

    @Test func moonOnlyForQuietsThatChangeTheLight() {
        #expect(ScreenBarEarMarks.quiet(mode: "mute", word: "Muted", until: nil) == nil)
        #expect(ScreenBarEarMarks.quiet(mode: nil, word: "Quiet", until: nil) == nil)
        #expect(ScreenBarEarMarks.quiet(mode: "pause", word: "Paused", until: nil)
                == ScreenBarEarMarks.Quiet(symbol: "moon.fill", text: "Paused"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let until = Date(timeIntervalSince1970: 14 * 3600 + 30 * 60)
        let timed = ScreenBarEarMarks.quiet(mode: "dark", word: "Dark", until: until, calendar: calendar)
        #expect(timed?.text.hasPrefix("Dark until ") == true)
        #expect(timed?.text.contains("30") == true, "the end is a clock time, not a countdown")
    }

    @Test func moonYieldsToAsksFailuresAndMedia() {
        let moon = ScreenBarEarMarks(quiet: .init(symbol: "moon.fill", text: "Paused"))
        #expect(ScreenBarEarMarks.apply(moon, to: .empty).left?.symbol == "moon.fill")
        let working = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"))
        #expect(ScreenBarEarMarks.apply(moon, to: working).left?.symbol == "moon.fill")
        let asking = ScreenBarWings(left: ScreenBarWingSlot(text: "Needs you", provider: "codex", tone: .attention))
        #expect(ScreenBarEarMarks.apply(moon, to: asking).left == asking.left)
        let failed = ScreenBarWings(left: ScreenBarWingSlot(text: "Failed", provider: "codex", tone: .alert))
        #expect(ScreenBarEarMarks.apply(moon, to: failed).left == failed.left)
        let media = ScreenBarWings(left: ScreenBarWingSlot(text: "Track", visualizer: true))
        #expect(ScreenBarEarMarks.apply(moon, to: media).left == media.left)
    }

    @Test func storeReadsTheQuietTheDaemonReports() {
        let core = CoreModel()
        let store = PanelStore(core: core, screenBarShown: false)
        #expect(store.screenBarEarMarks == ScreenBarEarMarks())
        core.apply(.state(CoreState(focus: CoreFocus(mode: "asks_only", source: "override", until: nil))))
        #expect(store.screenBarEarMarks.quiet?.text == "Asks only")
        core.apply(.state(CoreState(focus: CoreFocus(mode: "mute", source: "override", until: nil))))
        #expect(store.screenBarEarMarks.quiet == nil, "mute leaves the lights alone")
    }
}

/// The privacy dots on the right ear: with the ears drawn the island
/// rests bare, so the mic/camera LEDs ride the ear — never hidden by a
/// crowded flank, a flick, or a notice.
@Suite("Screen Bar privacy dots")
@MainActor
struct ScreenBarSensorDotsTests {
    private static let camera = NotchSensorState(microphoneInUse: false, cameraInUse: true)
    private static let both = NotchSensorState(microphoneInUse: true, cameraInUse: true)

    @Test func dotsJoinTheRightEarOrStandAlone() {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        let dressed = ScreenBarWings.withSensors(Self.both, on: ScreenBarWings(right: meter))
        #expect(dressed.right?.sensors == Self.both)
        #expect(dressed.right?.meter == 0.42, "the mark stays; the dots sit beside it")
        #expect(dressed.right?.text == "42% · camera and microphone in use")
        let alone = ScreenBarWings.withSensors(Self.camera, on: .empty)
        #expect(alone.right?.sensors == Self.camera)
        #expect(alone.right?.hasMark == false)
        #expect(alone.right?.text == "Camera in use")
        #expect(alone.left == nil, "the dots never claim the left ear")
        // Nothing live, nothing added.
        #expect(ScreenBarWings.withSensors(NotchSensorState(), on: .empty) == .empty)
    }

    @Test func dotsNeverChangeTheEarsSubject() {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        var dotted = meter
        dotted.sensors = Self.both
        #expect(ScreenBarController.sameWingSubject(meter, dotted))
    }

    @Test func earWidensByTheDotsLead() {
        #expect(ScreenBarView.contentWidth(nil) == 0)
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        #expect(ScreenBarView.contentWidth(meter) == 36)
        var dotted = meter
        dotted.sensors = Self.both
        // inset 6 + two 5 pt dots 4 pt apart + the mark's 36.
        #expect(ScreenBarView.contentWidth(dotted) == CGFloat(6 + 14 + 36))
        let alone = ScreenBarWingSlot(text: "Camera in use", sensors: Self.camera)
        #expect(ScreenBarView.contentWidth(alone) == CGFloat(6 + 5 + 6))
    }

    @Test func aRefusedProgramHoldsTheRightEarWithAMark() {
        let slot = ScreenBarNotices.refused("too-long")
        #expect(slot?.symbol == "exclamationmark.triangle.fill")
        #expect(slot?.tone == .alert)
        #expect(slot?.text.contains("too-long") == true, "the reason is VoiceOver's, not the ear's face")
        #expect(ScreenBarNotices.refused(nil) == nil)
        #expect(ScreenBarNotices.refused("") == nil)
    }

    @Test func aDotsOnlyEarDrawsOnTheNotchedFlank() throws {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 500,
            leftExtent: 0, rightExtent: 60)
        view.wings = ScreenBarWings.withSensors(Self.camera, on: .empty)
        view.relayout()
        let ear = try #require(view.rightWingRect)
        #expect(ear.width == 17)
        #expect(ear.width >= ScreenBarView.minimumEarWidth)
        #expect(view.leftWingRect == nil)
    }
}
