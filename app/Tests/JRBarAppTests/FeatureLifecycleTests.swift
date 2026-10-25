import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Optional feature teardown", .serialized)
struct FeatureLifecycleTests {
    private func stopped(_ resources: [String: Int], feature: String) {
        #expect(resources.values.allSatisfy { $0 == 0 }, "\(feature): \(resources)")
    }

    private func store(_ core: CoreModel, notchRuntime: Bool = false) -> ToysStore {
        ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                  cardModel: makeTestCardModel(), notchRuntimeEnabled: notchRuntime,
                  nativeSourcesEnabled: false)
    }

    @Test("the recorder sees a run-loop timer after its owner drops the reference")
    func recordsRealTimerLifetime() {
        let handles = FeatureLifecycleHandles()
        weak var native: Timer?
        do {
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
            native = timer
            handles.track(timer: timer)
            RunLoop.main.add(timer, forMode: .common)
        }
        defer { native?.invalidate() }
        #expect(handles.liveTimers == 1)
        native?.invalidate()
        #expect(handles.liveTimers == 0)
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
