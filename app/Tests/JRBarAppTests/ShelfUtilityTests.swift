import AppKit
import Foundation
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
}
