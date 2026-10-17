import Foundation
import JRBarCore

@MainActor
final class MenuBarQuietLease {
    enum Action: String, Sendable { case acquire, release }
    enum Reply: Equatable, Sendable {
        case acquired(String), deferred(String), released(String)
        case superseded, failed
    }

    var currentRevision: @MainActor () -> String? = { nil }
    var send: @MainActor (Action, String, String?) async -> Reply = { _, _, _ in .failed }
    private(set) var isChanging = false

    @MainActor
    private final class Cycle {
        let id = UUID().uuidString
        var revision: String?
        var needsRenewal = true
        var needsRelease = false
        var yielded = false
        init(revision: String?) { self.revision = revision }
    }

    private var desired: Cycle?
    private var active: Cycle?

    func connect(to core: CoreModel) {
        currentRevision = { [weak core] in
            guard core?.isLive == true else { return nil }
            return core?.state?.focus?.overrideRevision
        }
        send = { [weak core] action, id, revision in
            guard let core, core.isLive else { return .failed }
            var args: [String: JSONValue] = ["action": .string(action.rawValue), "lease_id": .string(id)]
            if let revision { args["expected_revision"] = .string(revision) }
            do {
                let reply = try await core.send("quiet_lease", args: args)
                if !reply.ok {
                    if reply.error?.code == "conflict" { return .superseded }
                    core.appendLocalLog(level: "warning", "Automatic Quiet change was refused.")
                    return .failed
                }
                guard let result = Self.receipt(reply, action: action) else {
                    core.appendLocalLog(level: "warning", "Automatic Quiet returned an incomplete result.")
                    return .failed
                }
                return result
            } catch {
                core.appendLocalLog(level: "warning", "Automatic Quiet could not reach the monitor.")
                return .failed
            }
        }
    }

    func setHolding(_ on: Bool) {
        guard on != (desired != nil) else { return }
        desired = on ? Cycle(revision: currentRevision()) : nil
        reconcile()
    }

    func renew() {
        desired?.needsRenewal = true
        resume()
    }

    func resume() {
        if let desired, desired.revision == nil { desired.revision = currentRevision() }
        reconcile()
    }

    private func reconcile() {
        guard !isChanging else { return }
        if let active, active !== desired {
            if active.needsRelease { perform(.release, cycle: active) }
            else { self.active = nil; reconcile() }
            return
        }
        guard let desired, !desired.yielded, desired.needsRenewal,
              desired.revision != nil else { return }
        active = desired
        perform(.acquire, cycle: desired)
    }

    private func perform(_ action: Action, cycle: Cycle) {
        isChanging = true
        cycle.needsRenewal = false
        // A lost reply can follow a committed acquisition. Release by ID
        // when this cycle retires; the daemon checks ownership again.
        if action == .acquire { cycle.needsRelease = true }
        let revision = cycle.revision
        _ = Task { @MainActor in
            let reply = await send(action, cycle.id, action == .acquire ? revision : nil)
            isChanging = false
            if action == .release {
                active = nil
                if case .released(let revision) = reply { desired?.revision = revision }
            } else {
                switch reply {
                case .acquired(let revision): cycle.revision = revision
                case .deferred(let revision):
                    cycle.revision = revision
                    cycle.needsRelease = false
                case .superseded:
                    cycle.yielded = true
                    cycle.needsRelease = false
                case .failed, .released:
                    cycle.yielded = true
                }
            }
            reconcile()
        }
    }

    private static func receipt(_ reply: CoreReply, action: Action) -> Reply? {
        guard let revision = reply.result?["revision"]?.stringValue,
              !revision.isEmpty, revision.utf8.count <= 128,
              let status = reply.result?["status"]?.stringValue else { return nil }
        switch (action, status) {
        case (.acquire, "acquired"), (.acquire, "deferred"):
            guard case .number(let until) = reply.result?["until"], until.isFinite else { return nil }
            return status == "acquired" ? .acquired(revision) : .deferred(revision)
        case (.release, "released"):
            guard let until = reply.result?["until"] else { return nil }
            switch until {
            case .null: return .released(revision)
            case .number(let epoch) where epoch.isFinite: return .released(revision)
            default: return nil
            }
        default: return nil
        }
    }
}
