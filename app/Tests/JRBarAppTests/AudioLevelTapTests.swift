import Foundation
import Testing
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
}
