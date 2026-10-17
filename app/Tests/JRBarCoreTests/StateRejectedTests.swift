import Foundation
import Testing
@testable import JRBarCore

/// A `state` frame the app cannot use leaves the frame before it on screen.
/// That frame must stop counting as current until a good one arrives.
@Suite("A rejected state frame")
@MainActor
struct StateRejectedTests {
    private func liveModel() -> CoreModel {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(CoreModelObservationTests.state(1)))
        return core
    }

    @Test("a refused state frame makes the model not live, and the next good one clears it")
    func rejectionAndRecovery() {
        let core = liveModel()
        #expect(core.isLive)
        #expect(core.stateRejected == nil)

        core.handle(.stateRejected("malformed frame: state: keyNotFound"))
        #expect(!core.isLive, "the frame on screen is not the monitor's newest")
        #expect(core.stateRejected == "malformed frame: state: keyNotFound")
        #expect(core.state != nil, "the last good frame is kept, only no longer called current")

        core.apply(.state(CoreModelObservationTests.state(2)))
        #expect(core.isLive)
        #expect(core.stateRejected == nil)
    }

    @Test("a state frame from another protocol version is refused the same way")
    func versionSkew() {
        let core = liveModel()
        core.apply(.unknown(type: "state", version: 2))
        #expect(!core.isLive)
        #expect(core.stateRejected?.contains("version is 2") == true)

        core.apply(.state(CoreModelObservationTests.state(3)))
        #expect(core.isLive)
    }

    @Test("an unknown frame of another kind leaves a live model live")
    func otherUnknownFramesAreHarmless() {
        let core = liveModel()
        core.apply(.unknown(type: "weather", version: nil))
        #expect(core.isLive)
        #expect(core.stateRejected == nil)
    }

    @Test("a dropped connection forgets the rejection")
    func disconnectClears() {
        let core = liveModel()
        core.handle(.stateRejected("too big"))
        core.handle(.disconnected(reason: "gone"))
        #expect(core.stateRejected == nil)
        core.handle(.connected)
        core.apply(.state(CoreModelObservationTests.state(4)))
        #expect(core.isLive)
    }

    @Test("the frame's kind is read from its first bytes")
    func declaredType() {
        #expect(CoreCodec.declaredType(ofFrame: Data(#"{"t":"state","v":1,"now":1}"#.utf8)) == "state")
        #expect(CoreCodec.declaredType(ofFrame: Data(#"{"v":1, "t" : "lights"}"#.utf8)) == "lights")
        #expect(CoreCodec.declaredType(ofFrame: Data("not json".utf8)) == nil)
        #expect(CoreCodec.declaredType(ofFrame: Data()) == nil)
    }

    @Test("a state frame over the limit is dropped and named")
    func oversizedStateIsNamed() {
        var splitter = NDJSONSplitter()
        var big = Data(#"{"t":"state","v":1,"pad":""#.utf8)
        big.append(Data(repeating: 0x78, count: CoreCodec.maxFrameBytes + 10))
        #expect(splitter.feed(big).isEmpty)
        #expect(splitter.droppedOversizedFrames == 1)
        #expect(splitter.lastDroppedOversizedType == "state")
    }
}
