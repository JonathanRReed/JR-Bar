import JRBarCore
import Observation
import SwiftUI

/// What `t3code_integration` says about T3 Code on this Mac: whether its
/// database is here, whether JR-Bar reads it, and the reader's last look.
struct T3CodeStatus: Equatable {
    struct Observation: Equatable {
        var available: Bool
        var threads: Int
        var active: Int
        var needsUser: Int
        var reason: String?
        var inFlight: Bool
    }

    var present: Bool
    var enabled: Bool
    var readOnly: Bool
    var observation: Observation?
    var running: Bool = false

    /// The reply's document; nil when it is not one.
    static func parse(_ json: JSONValue?) -> T3CodeStatus? {
        guard let json, let present = json["present"]?.boolValue,
              let enabled = json["enabled"]?.boolValue else { return nil }
        var observation: Observation?
        if let seen = json["observation"], seen["available"] != nil {
            observation = Observation(
                available: seen["available"]?.boolValue ?? false,
                threads: seen["threads"]?.intValue ?? 0,
                active: seen["active"]?.intValue ?? 0,
                needsUser: seen["needs_user"]?.intValue ?? 0,
                reason: seen["reason"]?.stringValue,
                inFlight: seen["in_flight"]?.boolValue ?? false)
        }
        return T3CodeStatus(present: present, enabled: enabled,
                            readOnly: json["read_only"]?.boolValue ?? false, observation: observation,
                            running: json["running"]?.boolValue ?? false)
    }

    var line: String { running ? "Detected" : "Not running" }

    var isSettling: Bool {
        guard running else { return false }
        guard let observation else { return true }
        return !observation.available && (observation.inFlight || observation.reason == nil
            || observation.reason == "t3_database_busy")
    }


}


/// Automatic integration status while Settings is open.
@MainActor
@Observable
final class T3CodeModel {
    private(set) var status: T3CodeStatus?
    private(set) var busy = false
    /// Stop follow-up reads after eight attempts.
    @ObservationIgnored private var settleReads = 0
    @ObservationIgnored private var followUp: Task<Void, Never>?
    static let settleReadLimit = 8

    nonisolated init() {}

    func refresh(core: CoreModel) {
        settleReads = 0
        reread(core: core)
    }

    private func reread(core: CoreModel) {
        guard core.isLive, !busy else { return }
        Task { [weak self] in await self?.run(core: core) }
    }

    /// Refresh while the first observation is pending.
    private func followUpIfSettling(_ parsed: T3CodeStatus, core: CoreModel) {
        followUp?.cancel()
        followUp = nil
        guard parsed.isSettling else { settleReads = 0; return }
        guard settleReads < Self.settleReadLimit else { return }
        settleReads += 1
        followUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.reread(core: core)
        }
    }

    private func run(core: CoreModel) async {
        busy = true
        defer { busy = false }
        do {
            let reply = try await core.send("t3code_integration", args: [:], timeout: 10)
            if reply.ok, let parsed = T3CodeStatus.parse(reply.result) {
                status = parsed
                followUpIfSettling(parsed, core: core)
            }
        } catch {
            return
        }
    }
}

/// Automatic T3 Code detection in Settings.
struct T3CodeRow: View {
    let model: T3CodeModel
    let core: CoreModel

    private var style: ProviderStyle { ProviderStyle.style(for: "t3code") }

    var body: some View {
        if let status = model.status {
            HStack(spacing: 10) {
                ProviderTile(style: style, size: 24)
                Text(style.name)
                Spacer()
                Text(status.line)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        }
    }
}
