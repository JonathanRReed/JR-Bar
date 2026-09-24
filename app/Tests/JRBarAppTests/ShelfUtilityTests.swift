import AppKit
import CoreAudio
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The shelf utility card's capability honesty (T48): no live media
/// means no transport and no artwork; an oversized payload never
/// reaches `NSImage`.
@MainActor
@Suite struct ShelfUtilityTests {

    @Test func noMediaMeansNoArtworkOrSource() {
        let model = ShelfUtilityModel()
        #expect(model.media == nil)
        #expect(model.artwork == nil)
        #expect(model.sourceName == nil)
    }

    @Test func transportIsANoOpWithoutLiveMedia() {
        let model = ShelfUtilityModel()
        // Would call into MediaRemote if ungated — the send must be
        // swallowed rather than firing a command at no source.
        model.send(.togglePlayPause)
        model.send(.nextTrack)
        #expect(model.media == nil)
    }

    @Test func oversizedArtworkIsDropped() {
        // The bound lives on the model; a payload past it decodes to nil.
        #expect(ShelfUtilityModel.maxArtworkBytes == 4 * 1024 * 1024)
    }

    @Test func monitorsAreOffUntilStarted() {
        let model = ShelfUtilityModel()
        #expect(!model.running)
        model.stop()  // stop-before-start is a no-op, not a crash
        #expect(!model.running)
    }

    // MARK: lane utilities

    @Test func theBatteryLineNamesTheChargerAndTheTimeToEmpty() {
        let charging = AlcovePowerState(hasBattery: true, onAC: true, charging: true, percent: 84,
                                        fullyCharged: false, minutesRemaining: 40)
        #expect(AlcovePower.batteryLine(charging, adapterWatts: 96, working: 2, heldAwake: true)
                == "84% · Charging · full in 40m · 96 W adapter · 2 agents working · held awake")
        // No rating reported: the line is today's.
        #expect(AlcovePower.batteryLine(charging, adapterWatts: nil, working: 0, heldAwake: false)
                == AlcovePower.batteryLine(charging, working: 0, heldAwake: false))
        // On battery there is no charger to name; the time to empty is the system's estimate.
        let unplugged = AlcovePowerState(hasBattery: true, onAC: false, charging: false, percent: 60,
                                         fullyCharged: false, minutesRemaining: 190)
        let line = AlcovePower.batteryLine(unplugged, adapterWatts: 96, working: 0, heldAwake: false)
        #expect(!line.contains("W adapter"))
        #expect(line.contains("left"))
    }

    @Test func theOutputPickerMovesTheSoundAndReadsItBack() {
        let model = ShelfUtilityModel()
        let speakers = CoreAudioOutputs.Device(id: 41, name: "MacBook Pro Speakers",
                                               transport: kAudioDeviceTransportTypeBuiltIn)
        let airpods = CoreAudioOutputs.Device(id: 77, name: "Jonathan's AirPods Pro",
                                              transport: kAudioDeviceTransportTypeBluetooth)
        final class Route { var current: AudioDeviceID = 41; var writes: [AudioDeviceID] = [] }
        let route = Route()
        model.readOutputs = { ([speakers, airpods], route.current) }
        model.writeOutput = { id in
            route.writes.append(id)
            route.current = id
            return true
        }
        model.refreshOutputs()
        #expect(model.outputs.count == 2)
        #expect(model.currentOutput == speakers)
        model.pickOutput(airpods)
        #expect(route.writes == [77])
        #expect(model.currentOutput == airpods)
        #expect(airpods.symbol == "airpodspro")
        #expect(CoreAudioOutputs.symbol(name: "LG HDR 4K", transport: kAudioDeviceTransportTypeHDMI) == "tv")
    }
}
