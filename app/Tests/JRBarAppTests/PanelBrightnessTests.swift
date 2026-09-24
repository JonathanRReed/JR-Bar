import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// One brightness story: when the strip, the Dot and the Screen Bar
/// disagree the slider says "Mixed", stands at the brightest and names
/// each in its tooltip; a drag sets them all and ends the mix.
@Suite("Panel brightness")
@MainActor
struct PanelBrightnessTests {
    private func store(_ devices: [CoreDevice]) -> PanelStore {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(devices: devices)))
        return PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                          screenBarShown: false)
    }

    @Test("devices that agree show their number")
    func agreeing() {
        let panel = store([
            CoreDevice(id: "pro", kind: "pro", name: "Pro", connected: true, brightness: 80),
            CoreDevice(id: "bar", kind: "screen_bar", enabled: true, brightness: 0.8),
        ])
        #expect(!panel.brightnessIsMixed)
        #expect(abs(panel.brightness - 0.8) < 0.001)
    }

    @Test("devices that disagree read Mixed at the brightest, each named in the tooltip")
    func disagreeing() {
        let panel = store([
            CoreDevice(id: "pro", kind: "pro", name: "Pro", connected: true, brightness: 40),
            CoreDevice(id: "dot", kind: "dot", connected: true, brightness: 0.6),
            CoreDevice(id: "bar", kind: "screen_bar", enabled: true, brightness: 1.0),
            CoreDevice(id: "gone", kind: "dot", connected: false, brightness: 0.1),
        ])
        #expect(panel.brightnessIsMixed)
        #expect(panel.brightness == 1.0)
        #expect(panel.brightnessBreakdown == "Pro 40% · Dot 60% · Screen Bar 100%", "a disconnected device has no say")
    }

    @Test("a drag in hand is one value, set on every device")
    func dragEndsTheMix() {
        let panel = store([
            CoreDevice(id: "pro", kind: "pro", name: "Pro", connected: true, brightness: 40),
            CoreDevice(id: "bar", kind: "screen_bar", enabled: true, brightness: 1.0),
        ])
        panel.localBrightness = 0.5
        #expect(!panel.brightnessIsMixed)
        #expect(panel.brightness == 0.5)
    }
}
