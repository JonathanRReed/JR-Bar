import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The right ear's keep-awake mark: the cup while the person's own
/// lease holds, the laptop while the closed-lid hold keeps a shut lid
/// running — marks only,
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

    @Test func theClosedLidHoldIsTheLaptopOnlyWhileTheLidIsShut() throws {
        var power = Self.lease("indefinite")
        power.closedLid = CoreClosedLid(policy: "agents", holding: true, lidClosed: true)
        let shut = try #require(ScreenBarEarMarks.awake(power: power))
        #expect(shut.symbol == "laptopcomputer")
        #expect(shut.text == "Running with the lid closed", "a shut lid outranks the lease")
        // Open again, the hold is only armed: the lease's cup comes back.
        power.closedLid?.lidClosed = false
        let open = try #require(ScreenBarEarMarks.awake(power: power))
        #expect(open.symbol == ScreenBarEarMarks.leaseSymbol)
        #expect(open.text == "Held awake until you turn it off")
        // With no lease either, an armed lid hold draws nothing.
        let armed = CorePower(closedLid: CoreClosedLid(policy: "agents", holding: true, lidClosed: false))
        #expect(ScreenBarEarMarks.awake(power: armed) == nil)
        let unknown = CorePower(closedLid: CoreClosedLid(policy: "agents", holding: true))
        #expect(ScreenBarEarMarks.awake(power: unknown) == nil, "an unread lid is not a shut one")
        // The moon means quiet and nothing else.
        #expect(!ScreenBarEarMarks.lidSymbol.hasPrefix("moon"))
        #expect(!ScreenBarEarMarks.leaseSymbol.hasPrefix("moon"))
    }

    @Test func aShortRunwayIsAnAmberMarkThatOutranksTheHold() throws {
        var power = Self.lease("agents")
        power.battery = CoreBattery(percent: 18, plugged: false,
                                    runway: CoreBatteryRunway(agents: 2, minutesLeft: 22, short: true))
        let short = try #require(ScreenBarEarMarks.awake(power: power))
        #expect(short.symbol == ScreenBarEarMarks.runwaySymbol)
        #expect(short.tone == .attention)
        #expect(short.text == "The battery won't outlast the agents — under half an hour left"
                + " · Held awake until the agents finish", "the peek and VoiceOver hear both")
        // The words never count down: a minute later nothing repaints.
        power.battery?.runway?.minutesLeft = 21
        #expect(ScreenBarEarMarks.awake(power: power) == short)

        // The charger falling behind needs no hold at all.
        var plugged = CorePower()
        plugged.battery = CoreBattery(percent: 60, plugged: true,
                                      runway: CoreBatteryRunway(agents: 3, adapterShort: true, fullSpeedWatts: 96))
        let adapter = try #require(ScreenBarEarMarks.awake(power: plugged))
        #expect(adapter.symbol == ScreenBarEarMarks.adapterSymbol)
        #expect(adapter.tone == .attention)
        #expect(adapter.text == "The charger can't keep up with the agents — a 96 W adapter keeps up")

        // A runway with room to spare is no mark; the hold's own stays.
        power.battery?.runway = CoreBatteryRunway(agents: 2, minutesLeft: 140, short: false, adapterShort: false)
        #expect(ScreenBarEarMarks.awake(power: power)?.symbol == ScreenBarEarMarks.leaseSymbol)
        #expect(ScreenBarEarMarks.runway(battery: nil) == nil)
    }

    @Test func theRunwayMarkIsAMarkOnTheEarNeverWords() throws {
        var marks = ScreenBarEarMarks()
        marks.awake = ScreenBarEarMarks.runway(battery: CoreBattery(
            runway: CoreBatteryRunway(short: true)))
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        let right = try #require(ScreenBarEarMarks.apply(marks, to: ScreenBarWings(left: nil, right: meter)).right)
        #expect(right.accessory == ScreenBarWingAccessory(symbol: ScreenBarEarMarks.runwaySymbol, tone: .attention))
        #expect(right.meter == 0.42, "the meter keeps its ear")
        let alone = try #require(ScreenBarEarMarks.apply(marks, to: .empty).right)
        #expect(alone.symbol == ScreenBarEarMarks.runwaySymbol)
        #expect(alone.tone == .attention)
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
