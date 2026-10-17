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
    @Test("retired output listeners cannot read after a fold or a new watch")
    func retiredOutputListenersDoNotRead() {
        let model = ShelfUtilityModel()
        var callbacks: [@MainActor () -> Void] = []
        var reads = 0
        var removals = 0
        model.readOutputs = { reads += 1; return ([], 0) }
        model.readOutputVolume = { nil }
        model.watchOutputs = { changed in
            callbacks.append(changed)
            return {
                removals += 1
                changed()
            }
        }
        model.startWatchingOutputs()
        callbacks[0]()
        #expect(reads == 1)
        model.stopWatchingOutputs()
        callbacks[0]()
        #expect(reads == 1)
        model.startWatchingOutputs()
        callbacks[0]()
        #expect(reads == 1)
        callbacks[1]()
        #expect(reads == 2)
        model.stopWatchingOutputs()
        model.stopWatchingOutputs()
        #expect(reads == 2)
        #expect(removals == 2)
    }


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

    @Test func aFoldDuringAScrubDropsTheDrag() {
        let model = ShelfUtilityModel()
        model.beginScrub()
        model.mediaScrub = 42
        #expect(model.elapsedShown() == 42, "while held, the slider follows the drag")
        model.stop()
        #expect(model.mediaScrub == nil)
        #expect(model.elapsedShown() == 0, "after the fold the slider follows the media again")
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
        model.readOutputVolume = { route.current == speakers.id ? 0.4 : 0.7 }
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
        #expect(model.outputVolume == 0.7)
        #expect(airpods.symbol == "airpodspro")
        #expect(CoreAudioOutputs.symbol(name: "LG HDR 4K", transport: kAudioDeviceTransportTypeHDMI) == "tv")
    }

    @Test func theOutputListFollowsDevicesWhileTheCardIsUp() {
        let model = ShelfUtilityModel()
        let speakers = CoreAudioOutputs.Device(id: 41, name: "MacBook Pro Speakers",
                                               transport: kAudioDeviceTransportTypeBuiltIn)
        let airpods = CoreAudioOutputs.Device(id: 77, name: "Jonathan's AirPods Pro",
                                              transport: kAudioDeviceTransportTypeBluetooth)
        final class Route {
            var devices: [CoreAudioOutputs.Device] = []
            var current: AudioDeviceID = 41
            var volume: Double? = 0.4
            var changed: (@MainActor () -> Void)?
            var stops = 0
        }
        let route = Route()
        route.devices = [speakers]
        model.readOutputs = { (route.devices, route.current) }
        model.readOutputVolume = { route.volume }
        model.watchOutputs = { changed in
            route.changed = changed
            return { route.stops += 1 }
        }
        model.refreshOutputs()
        model.startWatchingOutputs()
        #expect(model.watchingOutputs)
        // AirPods connect while the card is open.
        route.devices = [speakers, airpods]
        route.changed?()
        #expect(model.outputs == [speakers, airpods])
        route.current = airpods.id
        route.volume = nil
        route.changed?()
        #expect(model.currentOutput == airpods)
        #expect(model.outputVolume == nil, "an output without hardware volume hides the slider")
        route.current = speakers.id
        route.volume = 0.25
        route.changed?()
        #expect(model.currentOutput == speakers)
        #expect(model.outputVolume == 0.25, "returning to speakers restores their current volume")
        // The card folds: the listeners go, once.
        model.stopWatchingOutputs()
        model.stopWatchingOutputs()
        #expect(!model.watchingOutputs)
        #expect(route.stops == 1)
    }

    @Test func thePickerOffersOnlyDevicesTheSoundCanMoveTo() {
        #expect(CoreAudioOutputs.offers(hasOutput: true, hidden: false, canBeDefault: true))
        #expect(CoreAudioOutputs.offers(hasOutput: true, hidden: nil, canBeDefault: true),
                "a device that doesn't say it is hidden is shown")
        #expect(!CoreAudioOutputs.offers(hasOutput: true, hidden: true, canBeDefault: true),
                "an aggregate's hidden parts are not offered")
        #expect(!CoreAudioOutputs.offers(hasOutput: true, hidden: false, canBeDefault: false))
        #expect(!CoreAudioOutputs.offers(hasOutput: true, hidden: false, canBeDefault: nil))
        #expect(!CoreAudioOutputs.offers(hasOutput: false, hidden: false, canBeDefault: true),
                "a microphone plays nothing")
    }
}
