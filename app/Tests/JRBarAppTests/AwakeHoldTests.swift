import Foundation
import Testing
import JRBarCore
import JRBarUI
@testable import JRBarApp

/// The footer's hold mark: why the Mac is awake, from `state.power`.
@Suite("Awake hold mark")
struct AwakeHoldTests {
    private func power(_ json: String) throws -> CorePower {
        try JSONDecoder().decode(CorePower.self, from: Data(json.utf8))
    }

    @Test("no hold, no mark")
    func none() throws {
        #expect(PanelStore.awakeHold(power: nil, working: 2) == nil)
        #expect(PanelStore.awakeHold(power: try power(#"{"keep_awake":false}"#), working: 2) == nil)
    }

    @Test("keep-awake names the agents and when it lets go")
    func keepAwake() throws {
        let hold = try #require(PanelStore.awakeHold(power: try power(#"{"keep_awake":true}"#), working: 2))
        #expect(hold.symbol == "cup.and.saucer.fill")
        #expect(hold.text == "Keeping this Mac awake while 2 agents work; it lets go a few minutes after they stop")
        #expect(PanelStore.awakeHold(power: try power(#"{"keep_awake":true}"#), working: 1)?.text.contains("1 agent works") == true)
    }

    @Test("a closed lid held open outranks the plain hold")
    func closedLid() throws {
        let hold = try #require(PanelStore.awakeHold(
            power: try power(#"{"keep_awake":true,"closed_lid":{"policy":"agents","holding":true,"lid_closed":true}}"#),
            working: 0))
        #expect(hold.symbol == "laptopcomputer")
        #expect(hold.text.hasPrefix("Running with the lid closed"))
    }

    @Test("an armed closed-lid hold with the lid open wears the cup")
    func lidOpen() throws {
        let armed = try power(#"{"keep_awake":true,"closed_lid":{"policy":"agents","holding":true,"lid_closed":false}}"#)
        let hold = try #require(PanelStore.awakeHold(power: armed, working: 2))
        #expect(hold.symbol == "cup.and.saucer.fill")
        #expect(hold.text.hasPrefix("Keeping this Mac awake while 2 agents work"))
        #expect(!hold.text.contains("lid closed"))
        let unread = try power(#"{"keep_awake":true,"closed_lid":{"policy":"agents","holding":true}}"#)
        #expect(PanelStore.awakeHold(power: unread, working: 2)?.symbol == "cup.and.saucer.fill")
    }

    @Test("the mark's tooltip carries the power facts; a short runway wears the battery")
    func facts() throws {
        let hold = try #require(PanelStore.awakeHold(power: try power(
            #"{"keep_awake":true,"battery":{"runway":{"agents":2,"minutes_left":20,"short":true}}}"#), working: 2))
        #expect(hold.symbol == "battery.25percent")
        #expect(hold.text.hasSuffix("\nOn battery with 2 agents working: about 20 min left"))
    }
}

/// The panel cup, the notch chip and the Settings row read the same hold.
@Suite("Awake marks")
@MainActor
struct AwakeMarkTests {
    @Test("the cup steams while it holds and stays a plain mark otherwise")
    func cupSteams() {
        #expect(KeepAwakeSteam.none.symbol == "cup.and.saucer.fill")
        #expect(KeepAwakeSteam.full.symbol != KeepAwakeSteam.none.symbol)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = KeepAwakeReading(localHeld: true, until: start.addingTimeInterval(3_600), display: false,
                                       startedAt: start)
        #expect(reading.steam(now: start) == .full)
        #expect(reading.steam(now: start.addingTimeInterval(2_400)) == .low)
        #expect(reading.steam(now: start.addingTimeInterval(3_400)) == .faint)
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(ScratchDefaults.suiteName("awake-mark")),
                               screenBarShown: false)
        #expect(store.awakeSteam == .none, "no monitor, no hold, no steam")
    }

    @Test("a failed status reads red on the Settings row; others stay amber")
    func failedRowTint() {
        #expect(SettingsFeatureRow.chipTint(.failed("Couldn't hold the Mac awake")) == Tone.failure.color)
        #expect(SettingsFeatureRow.chipTint(.paused("Waiting")) == Tone.neutral.color)
    }
}
