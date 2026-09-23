import Foundation
import Testing
import JRBarLEDS
@testable import JRBarCore

/// A due timer's strip flash: a program the firmware parser takes, and
/// the rule for when it plays at all.
@Suite("Notch timer lights")
struct NotchTimerLightsTests {
    @Test("the flash is a valid LEDS program that beats three times and ends dark")
    func programParses() throws {
        let program = try LEDSProgram.parse(NotchTimerLights.program, ledCount: 8)
        #expect(program.repeatCount == .some(3))
        #expect(NotchTimerLights.seconds >= 1.8, "the preview outlasts the three beats")
        #expect(NotchTimerLights.seconds <= 30, "inside preview_program's range")
    }

    @Test("it plays only on a connected strip, only while the Mac is not quiet, only when on")
    func when() {
        let strip = CoreDevice(id: "sidepulse:pro:B293A1", kind: "pro", connected: true)
        let unplugged = CoreDevice(id: "sidepulse:pro:B293A1", kind: "pro", connected: false)
        let band = CoreDevice(id: "virtual:status-bar", kind: "virtual", connected: true)
        #expect(NotchTimerLights.shouldFlash(enabled: true, devices: [strip], quiet: false))
        #expect(!NotchTimerLights.shouldFlash(enabled: true, devices: [strip], quiet: true))
        #expect(!NotchTimerLights.shouldFlash(enabled: false, devices: [strip], quiet: false))
        #expect(!NotchTimerLights.shouldFlash(enabled: true, devices: [unplugged, band], quiet: false),
                "the Screen Bar is not a strip, and the island already says it there")
    }

    @Test("old settings flash by default")
    func decodesDefault() throws {
        let settings = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(settings.timerLights)
    }
}
