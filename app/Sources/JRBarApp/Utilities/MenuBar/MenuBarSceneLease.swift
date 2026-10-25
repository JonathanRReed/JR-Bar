import Foundation
import JRBarCore
import Observation

@MainActor
final class MenuBarSceneLease {
    enum Action: String { case acquire, release }
    enum Reply: Equatable {
        case acquired(String), released(String), superseded, failed
    }
    struct State {
        let stream: String
        let revision: String
    }
    var currentState: () -> State? = { nil }
    var send: (Action, String, String?, String?) async -> Reply = { _, _, _, _ in .failed }
    private(set) var isChanging = false
    private var changeTask: Task<Void, Never>?

    func waitUntilIdle() async -> Bool {
        while let task = changeTask { await task.value }
        return !isChanging
    }
    private weak var core: CoreModel?
    private var renewal: Task<Void, Never>?
    var waitForRenewal: @MainActor () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }

    private final class Cycle {
        let id = UUID().uuidString
        let scene: String
        var state: State?
        var needsAcquire = true
        var needsRelease = false
        var releaseBlocked = false
        var yielded = false
        init(scene: String, state: State?) { self.scene = scene; self.state = state }
    }
    private var desired: Cycle?
    private var active: Cycle?

    func connect(to core: CoreModel) {
        self.core = core
        currentState = { [weak core] in
            guard let core, core.isLive, let stream = core.hello?.stream, !stream.isEmpty,
                  core.settingsFrame?.stream == stream,
                  let revision = core.settings?.document["scene_state"]?["revision"]?.stringValue,
                  !revision.isEmpty, revision.utf8.count <= 128 else { return nil }
            return State(stream: stream, revision: revision)
        }
        send = { [weak core] action, id, revision, scene in
            guard let core, core.isLive else { return .failed }
            var args: [String: JSONValue] = ["action": .string(action.rawValue), "lease_id": .string(id)]
            if let revision { args["expected_revision"] = .string(revision) }
            if let scene { args["scene"] = .string(scene) }
            do {
                let reply = try await core.send("scene_lease", args: args)
                guard reply.ok else {
                    if reply.error?.code == "conflict" { return .superseded }
                    core.appendLocalLog(level: "warning", "Automatic scene change was refused.")
                    return .failed
                }
                guard let result = reply.result,
                      let keptRevision = result["revision"]?.stringValue,
                      !keptRevision.isEmpty, keptRevision.utf8.count <= 128,
                      let keptScene = result["scene"]?.stringValue,
                      EffectScene(rawValue: keptScene) != nil,
                      let until = result["until"] else {
                    core.appendLocalLog(level: "warning", "Automatic scene returned an incomplete result.")
                    return .failed
                }
                switch (action, result["status"]?.stringValue, until) {
                case (.acquire, "acquired", .number(let epoch)) where epoch.isFinite && keptScene == scene && keptRevision == revision:
                    return .acquired(keptRevision)
                case (.release, "released", .null): return .released(keptRevision)
                case (.release, "released", .number(let epoch)) where epoch.isFinite: return .released(keptRevision)
                default:
                    core.appendLocalLog(level: "warning", "Automatic scene returned an incomplete result.")
                    return .failed
                }
            } catch {
                core.appendLocalLog(level: "warning", "Automatic scene could not reach the monitor.")
                return .failed
            }
        }
        observeCore()
        resume()
    }

    private func observeCore() {
        guard let core else { return }
        withObservationTracking {
            _ = core.settingsFrame
            _ = core.hello
            _ = core.isLive
            _ = core.connection
        } onChange: { [weak self] in
            _ = Task { @MainActor [weak self] in
                self?.resume()
                self?.observeCore()
            }
        }
    }

    func setDesiredScene(_ scene: String?) {
        guard scene != desired?.scene else { return }
        desired = scene.map { Cycle(scene: $0, state: currentState()) }
        renewal?.cancel()
        renewal = nil
        if scene != nil {
            renewal = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let wait = self?.waitForRenewal else { return }
                    do { try await wait() } catch { return }
                    guard let self, self.desired != nil else { return }
                    self.renew()
                }
            }
        }
        reconcile()
    }

    func renew() {
        desired?.needsAcquire = true
        resume()
    }

    func resume() {
        active?.releaseBlocked = false
        reconcile()
    }

    private func reconcile() {
        guard !isChanging else { return }
        if let state = currentState() {
            if let active, active.state?.stream != state.stream { self.active = nil }
            if let desired, !desired.yielded {
                if desired.state == nil { desired.state = state }
                else if desired.state?.stream != state.stream {
                    self.desired = Cycle(scene: desired.scene, state: state)
                } else if desired.state?.revision != state.revision {
                    desired.yielded = true
                }
            }
        }
        if let active, active !== desired || active.yielded {
            if !active.needsRelease { self.active = nil; reconcile() }
            else if !active.releaseBlocked { perform(.release, cycle: active) }
            return
        }
        guard let desired, !desired.yielded, desired.needsAcquire, desired.state != nil else { return }
        active = desired
        perform(.acquire, cycle: desired)
    }

    private func perform(_ action: Action, cycle: Cycle) {
        isChanging = true
        if action == .acquire {
            cycle.needsAcquire = false
            cycle.needsRelease = true
        }
        changeTask = Task { @MainActor [self] in
            let reply = await send(action, cycle.id, action == .acquire ? cycle.state?.revision : nil,
                                   action == .acquire ? cycle.scene : nil)
            isChanging = false
            changeTask = nil
            if action == .release {
                switch reply {
                case .released, .superseded: active = nil
                default: cycle.releaseBlocked = true
                }
            } else {
                switch reply {
                case .acquired: break
                case .superseded:
                    cycle.yielded = true
                    cycle.needsRelease = false
                default: break
                }
            }
            reconcile()
        }
    }

    isolated deinit { renewal?.cancel() }
}
