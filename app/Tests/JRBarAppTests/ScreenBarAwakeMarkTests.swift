import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The right ear's keep-awake mark: the cup while the person's own
/// lease holds, the moon while the closed-lid hold runs — marks only,
/// riding beside whatever the ear shows; the words stay in VoiceOver
/// and the peek.
@Suite("Screen Bar keep-awake mark")
@MainActor
struct ScreenBarAwakeMarkTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private static func lease(_ kind: String, until: Double? = nil, display: Bool? = nil,
                              suspended: String? = nil) -> CorePower {
        CorePower(keepAwake: suspended == nil,
                  hold: CoreAwakeHold(state: "manual", active: suspended == nil,
                                      lease: CoreAwakeLease(kind: kind, until: until, display: display),
                                      suspended: suspended))
    }

    @Test func nothingHoldsNothingShows() {
        #expect(ScreenBarEarMarks.awake(power: nil) == nil)
        #expect(ScreenBarEarMarks.awake(power: CorePower()) == nil)
        // The agents' own hold comes and goes with every run: not a mark.
        let agents = CorePower(keepAwake: true, hold: CoreAwakeHold(state: "agents", agents: 2, active: true))
        #expect(ScreenBarEarMarks.awake(power: agents) == nil)
        // A lid policy that is not holding right now is not a mark either.
        let armed = CorePower(closedLid: CoreClosedLid(policy: "agents", holding: false))
        #expect(ScreenBarEarMarks.awake(power: armed) == nil)
    }

    @Test func aLeaseIsTheCupAndSaysWhenItLetsGo() throws {
        // 14:30 UTC.
        let until = 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400) + 14.5 * 3600
        let timed = try #require(ScreenBarEarMarks.awake(power: Self.lease("duration", until: until),
                                                         calendar: Self.utc))
        #expect(timed.symbol == ScreenBarEarMarks.leaseSymbol)
        // The clock's spelling is the Mac's locale; the time is the lease's.
        #expect(timed.text.hasPrefix("Held awake until "))
        #expect(timed.text.contains("30"))
        #expect(ScreenBarEarMarks.awake(power: Self.lease("duration"))?.text == "Held awake")
        #expect(timed.tone == .neutral)
        #expect(ScreenBarEarMarks.awake(power: Self.lease("agents"))?.text == "Held awake until the agents finish")
        #expect(ScreenBarEarMarks.awake(power: Self.lease("indefinite"))?.text == "Held awake until you turn it off")
        #expect(ScreenBarEarMarks.awake(power: Self.lease("indefinite", display: true))?.text
                == "Held awake until you turn it off, the screen too")
    }

    @Test func aYieldedLeaseTurnsAmberAndSaysWhy() throws {
        let warm = try #require(ScreenBarEarMarks.awake(power: Self.lease("agents", suspended: "thermal")))
        #expect(warm.symbol == ScreenBarEarMarks.leaseSymbol)
        #expect(warm.tone == .attention)
        #expect(warm.text == "Keep-awake paused — the Mac is too warm")
        #expect(ScreenBarEarMarks.awake(power: Self.lease("agents", suspended: "battery"))?.text
                == "Keep-awake paused — the battery is low")
    }

    @Test func theClosedLidHoldIsTheMoonAndOutranksALease() throws {
        var power = Self.lease("indefinite")
        power.closedLid = CoreClosedLid(policy: "agents", holding: true, lidClosed: true)
        let shut = try #require(ScreenBarEarMarks.awake(power: power))
        #expect(shut.symbol == ScreenBarEarMarks.lidSymbol)
        #expect(shut.text == "Running with the lid closed")
        power.closedLid?.lidClosed = false
        #expect(ScreenBarEarMarks.awake(power: power)?.text == "Keeps running if the lid closes")
        #expect(ScreenBarEarMarks.lidSymbol != "moon.fill", "the quiet's moon on the other ear stays its own")
    }

    @Test func theMarkRidesTheRightEarWithoutTakingIt() throws {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        var marks = ScreenBarEarMarks()
        marks.awake = .init(symbol: ScreenBarEarMarks.leaseSymbol, text: "Held awake until 14:30")
        let dressed = ScreenBarEarMarks.apply(marks, to: ScreenBarWings(left: nil, right: meter))
        let right = try #require(dressed.right)
        #expect(right.meter == 0.42, "the meter keeps its ear")
        #expect(right.accessory == ScreenBarWingAccessory(symbol: ScreenBarEarMarks.leaseSymbol))
        #expect(right.text == "42% · Held awake until 14:30", "VoiceOver hears both")
        #expect(ScreenBarController.sameWingSubject(right, meter), "the cup is not a new subject")
        #expect(dressed.left == nil, "the left ear is the agents' and the quiet's")

        // With nothing else on the side the cup is the ear's own mark.
        let alone = ScreenBarEarMarks.apply(marks, to: .empty)
        #expect(alone.right?.symbol == ScreenBarEarMarks.leaseSymbol)
        #expect(alone.right?.accessory == nil)
    }

    @Test func thePeekSpellsTheHoldTheEarOnlyMarks() {
        let model = ScreenBarPeekModel()
        #expect(!model.hasWords)
        model.awake = .init(symbol: ScreenBarEarMarks.leaseSymbol, text: "Held awake until you turn it off")
        #expect(model.hasWords, "a sentence at the peek's foot sets its reading width")
        #expect(ScreenBarPeekLayout.width(tileWidths: [22], hasWords: model.hasWords)
                == ScreenBarPeekLayout.wordsWidth + 2 * ScreenBarPeekLayout.padding)
    }

    @Test func theAccessoryWidensItsEarBySlice() {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        var cupped = meter
        cupped.accessory = ScreenBarWingAccessory(symbol: ScreenBarEarMarks.leaseSymbol)
        #expect(ScreenBarView.contentWidth(cupped) == ScreenBarView.contentWidth(meter) + ScreenBarWingAccessory.width)
        var watched = cupped
        watched.sensors = NotchSensorState(microphoneInUse: true)
        var bare = meter
        bare.sensors = watched.sensors
        #expect(ScreenBarView.contentWidth(watched) == ScreenBarView.contentWidth(bare) + ScreenBarWingAccessory.width)
    }
}
