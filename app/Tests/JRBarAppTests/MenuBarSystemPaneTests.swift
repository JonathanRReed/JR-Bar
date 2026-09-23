import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The combined readout's popover: it hid Control Center's Bluetooth and
/// Now Playing, so it carries them — and the agents, which no Control
/// Center does. Only the pure shaping is tested; nothing here reads
/// Bluetooth, the media feed or the hardware.
@Suite("Menu Bar — the combined popover")
struct MenuBarSystemPaneTests {
    @Test("connected devices list in name order, whatever order they connect in")
    func devicesSorted() {
        let devices = [MenuBarBluetoothDevice(name: "MX Master 3S", battery: 80),
                       MenuBarBluetoothDevice(name: "AirPods Pro", battery: nil),
                       MenuBarBluetoothDevice(name: "keyboard", battery: 12)]
        #expect(MenuBarSystemReadings.sorted(devices).map(\.name) == ["AirPods Pro", "keyboard", "MX Master 3S"])
    }

    @Test("Now Playing reads the track and who it is by, or the album; nothing without a title")
    func nowPlaying() {
        var media = AlcoveMedia(title: "Teardrop", artist: "Massive Attack", album: "Mezzanine",
                                playing: true)
        #expect(MenuBarSystemReadings.nowPlaying(media)?.title == "Teardrop")
        #expect(MenuBarSystemReadings.nowPlaying(media)?.detail == "Massive Attack")
        media.artist = nil
        #expect(MenuBarSystemReadings.nowPlaying(media)?.detail == "Mezzanine")
        media.album = nil
        #expect(MenuBarSystemReadings.nowPlaying(media)?.detail == "")
        media.title = ""
        #expect(MenuBarSystemReadings.nowPlaying(media) == nil)
        #expect(MenuBarSystemReadings.nowPlaying(nil) == nil)
    }

    @MainActor
    @Test("the popover's agent line comes from the utility's feed, word and tint")
    func agentLine() {
        let utility = MenuBarUtility()
        utility.agentState = { (.needsInput, "claude · waiting 2m") }
        let line = utility.combinedAgentLine()
        #expect(line.label == "Agents — \(AgentAggregateState.needsInput.label)")
        #expect(line.detail == "claude · waiting 2m")
        #expect(line.tintHex == AgentAggregateState.needsInput.tintHex)
    }
}
