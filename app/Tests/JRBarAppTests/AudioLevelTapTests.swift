import CoreAudio
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The tap's lifecycle against a fake engine: the gating table, the
/// process→global selection, retargeting, and the failure paths —
/// all without touching a real Core Audio device.
@MainActor @Suite struct AudioLevelTapTests {

    private final class FakeEngine: AudioTapEngine {
        var processes: [pid_t]?
        var running = false
        var onLevels: (([Float]) -> Void)?
        var onDeath: (() -> Void)?
        var startError: Error?

        func start(processes: [pid_t]?,
                   completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
            if let startError {
                completion(.failure(startError))
                return
            }
            self.processes = processes
            running = true
            completion(.success(()))
        }
        func stop() { running = false }
    }

    /// The engine start is async now — `live` flips on a main hop after
    /// the completion lands. One tick is enough for the fake.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func makeTap() -> (AudioLevelTap, () -> FakeEngine) {
        let tap = AudioLevelTap()
        var latest: FakeEngine!
        tap.makeEngine = { let engine = FakeEngine(); latest = engine; return engine }
        return (tap, { latest })
    }

    @Test func oldEngineCallbacksCannotOverwriteOrKillItsReplacement() async {
        let tap = AudioLevelTap()
        var engines: [FakeEngine] = []
        tap.makeEngine = { let engine = FakeEngine(); engines.append(engine); return engine }
        tap.resolvePIDs = { $0 == "a.app" ? [111] : [222] }
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "a.app")
        await settle()
        let staleLevels = engines[0].onLevels
        let staleDeath = engines[0].onDeath
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "b.app")
        await settle()
        engines[1].onLevels?([0.2, 0.4, 0.6, 0.8, 1, 0.5])
        await settle()
        staleLevels?([1, 1, 1, 1, 1, 1])
        staleDeath?()
        await settle()
        #expect(tap.live)
        #expect(engines[1].running)
        #expect(tap.levels == [0.2, 0.4, 0.6, 0.8, 1, 0.5])
        tap.stop()
        #expect(!engines[1].running)
    }

    @Test func aFailureFromAnEarlierStartCannotRejectAReusedEngineRun() async {
        let tap = AudioLevelTap()
        let engine = FakeEngine()
        tap.makeEngine = { engine }
        engine.startError = AudioTapError.noOutputDevice
        tap.sync(visible: true, playing: true, enabled: true)
        tap.stop()
        engine.startError = nil
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        #expect(tap.live)
        #expect(engine.running)
        tap.stop()
    }

    @Test func failedRetargetClearsThePreviousSamples() async {
        let tap = AudioLevelTap()
        var engines: [FakeEngine] = []
        tap.makeEngine = {
            let engine = FakeEngine()
            if !engines.isEmpty { engine.startError = AudioTapError.noOutputDevice }
            engines.append(engine)
            return engine
        }
        tap.resolvePIDs = { $0 == "a.app" ? [111] : [222] }
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "a.app")
        await settle()
        engines[0].onLevels?([1, 1, 1, 1, 1, 1])
        await settle()
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "b.app")
        await settle()
        #expect(!tap.live)
        #expect(tap.levels == [Float](repeating: 0, count: 6))
        #expect(!engines[1].running)
    }

    @Test func zeroLengthBuffersContributeNoSamplesOrChannels() {
        let samples = TapSampleBuffer()
        var stereo: [Float] = [1, 3, 5, 7]
        var emptyStorage: [Float] = [1000, 1000]
        stereo.withUnsafeMutableBufferPointer { valid in
            emptyStorage.withUnsafeMutableBufferPointer { empty in
                let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
                let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes,
                                                               alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { storage.deallocate() }
                let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
                list.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(valid.count * MemoryLayout<Float>.size),
                    mData: valid.baseAddress)))
                defer { list.deinitialize(count: 1) }
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: empty.baseAddress)
                samples.ingest(UnsafePointer(list))
            }
        }
        #expect(samples.window(2).samples == [2, 6])
    }

    @Test func theGateStartsAndStopsTheEngine() async {
        let (tap, engine) = makeTap()
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        #expect(tap.live && engine().running)

        // Each dropped gate stops the tap.
        tap.sync(visible: false, playing: true, enabled: true)
        #expect(!tap.live && !engine().running)
        tap.sync(visible: true, playing: false, enabled: true)
        #expect(!tap.live)
        tap.sync(visible: true, playing: true, enabled: false)
        #expect(!tap.live)
        // Everything true again brings it back.
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        #expect(tap.live)
    }

    @Test func clientResolutionChoosesTheProcessTap() async {
        let (tap, engine) = makeTap()
        tap.resolvePIDs = { $0 == "com.spotify.client" ? [444] : [] }
        tap.sync(visible: true, playing: true, enabled: true,
                 clientBundleID: "com.spotify.client")
        await settle()
        #expect(engine().processes == [444],
                "a known client gets its own process tap")
    }

    @Test func anUnresolvableClientFallsBackToGlobal() async {
        let (tap, engine) = makeTap()
        tap.resolvePIDs = { _ in [] }
        tap.sync(visible: true, playing: true, enabled: true,
                 clientBundleID: "com.vendor.unknown")
        await settle()
        #expect(engine().processes == nil,
                "no resolved PIDs → the global mixdown tap")
    }

    @Test func aClientChangeRetargetsTheTap() async {
        let tap = AudioLevelTap()
        var engines: [FakeEngine] = []
        tap.makeEngine = { let e = FakeEngine(); engines.append(e); return e }
        tap.resolvePIDs = { $0 == "a.app" ? [111] : [222] }
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "a.app")
        await settle()
        #expect(engines.count == 1 && engines[0].processes == [111])
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "b.app")
        await settle()
        #expect(engines.count == 2,
                "a different client rebuilds the tap")
        #expect(!engines[0].running && engines[1].processes == [222])
        // The same facts again build nothing — no churn per frame.
        tap.sync(visible: true, playing: true, enabled: true, clientBundleID: "b.app")
        await settle()
        #expect(engines.count == 2)
    }

    @Test func aFailedStartStaysQuiet() async {
        let (tap, _) = makeTap()
        let tap2 = tap
        tap2.makeEngine = {
            let engine = FakeEngine()
            engine.startError = AudioTapError.tapCreationFailed(-1)
            return engine
        }
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        #expect(!tap.live, "denied permission → decorative bars, no crash")
    }

    @Test func engineDeathDropsTheLiveFlag() async throws {
        let (tap, engine) = makeTap()
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        #expect(tap.live)
        engine().onDeath?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!tap.live, "the IOProc dying must release the row")
    }

    @Test func levelsPublishOnMainAndZeroOnStop() async throws {
        let (tap, engine) = makeTap()
        var seen: [[Float]] = []
        tap.onLevels = { seen.append($0) }
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        engine().onLevels?([1, 0.5, 0, 0.5, 1, 0])
        try await Task.sleep(for: .milliseconds(50))
        #expect(tap.levels == [1, 0.5, 0, 0.5, 1, 0])
        tap.stop()
        #expect(tap.levels == [Float](repeating: 0, count: 6))
        #expect(seen.last == [Float](repeating: 0, count: 6),
                "collapse leaves a decaying tail, not a frozen frame")
    }

    @Test func everyLiveEdgeReachesTheListener() async throws {
        let (tap, engine) = makeTap()
        var edges: [Bool] = []
        tap.onLiveChange = { edges.append($0) }
        tap.sync(visible: true, playing: true, enabled: true)
        #expect(edges.isEmpty, "the start is async: nothing is live yet")
        await settle()
        engine().onDeath?()
        try await Task.sleep(for: .milliseconds(50))
        tap.sync(visible: true, playing: true, enabled: true)
        await settle()
        tap.stop()
        #expect(edges == [true, false, true, false], "up, death, up, stop")
    }

    @Test func theCardFollowsTheTapAfterTheAsyncStartAndDropsOnDeath() async throws {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        let utility = toy.cardModel.utility
        var latest: FakeEngine!
        toy.audioTap.makeEngine = { let engine = FakeEngine(); latest = engine; return engine }

        toy.audioTap.sync(visible: true, playing: true, enabled: true)
        #expect(!utility.audioTapLive, "sync returns before the pipeline is up")
        await settle()
        #expect(utility.audioTapLive, "the async start lands on the card by itself")
        latest.onLevels?([0.2, 0.4, 0.6, 0.8, 1, 0.5])
        try await Task.sleep(for: .milliseconds(50))
        #expect(utility.audioLevels == [0.2, 0.4, 0.6, 0.8, 1, 0.5])

        latest.onDeath?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!utility.audioTapLive, "a dead tap gives the row back its decorative bars")
        #expect(utility.audioLevels == [Float](repeating: 0, count: 6), "no frozen frame")
    }
}
