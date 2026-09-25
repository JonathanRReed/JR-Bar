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
                            readOnly: json["read_only"]?.boolValue ?? false, observation: observation)
    }

    /// The row's status line, in plain words.
    var line: String {
        guard enabled else {
            return readOnly
                ? "A newer JR-Bar wrote the integration settings, so this switch is locked."
                : "Shows T3 Code's threads beside your other sessions. Read-only, and nothing leaves this Mac."
        }
        guard let observation else { return "Reading T3 Code…" }
        if observation.available {
            var parts = [observation.threads == 1 ? "1 thread" : "\(observation.threads) threads"]
            if observation.active > 0 { parts.append("\(observation.active) working") }
            if observation.needsUser > 0 { parts.append("\(observation.needsUser) \(observation.needsUser == 1 ? "needs" : "need") you") }
            // A failed re-read keeps the last good look, and says so.
            if let reason = observation.reason { parts.append(Self.staleWords(for: reason)) }
            return "Watching " + parts.joined(separator: " · ")
        }
        if let reason = observation.reason { return Self.words(for: reason) }
        return "Reading T3 Code…"
    }

    /// Switched on, but the line still shows a look on its way: no
    /// observation yet, a first read in flight or not yet begun, or a busy
    /// database being retried. Turning the switch on returns before the
    /// reader's first look lands, so the model reads again while this holds.
    var isSettling: Bool {
        guard enabled else { return false }
        guard let observation else { return true }
        if observation.available { return false }
        return observation.inFlight || observation.reason == nil
            || observation.reason == "t3_database_busy"
    }

    /// The reader's refusal codes, said plainly.
    static func words(for reason: String) -> String {
        switch reason {
        case "t3_database_missing": "T3 Code's database has gone missing."
        case "t3_schema_unsupported": "This T3 Code version isn't one JR-Bar can read yet."
        case "t3_database_busy": "T3 Code's database was busy; trying again."
        default: "JR-Bar couldn't read T3 Code's database."
        }
    }

    /// The same codes, as the tail of a line that still shows the last
    /// good look.
    static func staleWords(for reason: String) -> String {
        switch reason {
        case "t3_database_busy": "database busy, retrying"
        case "t3_database_missing": "database missing"
        case "t3_schema_unsupported": "version not supported"
        default: "last read failed"
        }
    }
}


/// The T3 Code row's state: read when the Agents page shows, written only
/// by the row's switch.
@MainActor
@Observable
final class T3CodeModel {
    private(set) var status: T3CodeStatus?
    private(set) var busy = false
    /// The last switch's refusal, in the monitor's words.
    private(set) var error: String?

    /// Follow-up reads taken since the last settled look, page show or
    /// click — capped so a reader that never settles stops being asked.
    @ObservationIgnored private var settleReads = 0
    @ObservationIgnored private var followUp: Task<Void, Never>?
    static let settleReadLimit = 8

    nonisolated init() {}

    func refresh(core: CoreModel) {
        settleReads = 0
        reread(core: core)
    }

    /// The explicit click: the opt-in written, the reader reconciled.
    func setEnabled(_ on: Bool, core: CoreModel) {
        guard core.isLive, !busy else { return }
        settleReads = 0
        Task { [weak self] in await self?.run(core: core, args: ["enabled": .bool(on)]) }
    }

    private func reread(core: CoreModel) {
        guard core.isLive, !busy else { return }
        Task { [weak self] in await self?.run(core: core, args: [:]) }
    }

    /// Reads once more in a moment while the reader's look is still on
    /// its way, so the row reaches "Watching …" or a refusal without the
    /// page being left and reopened.
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

    func run(core: CoreModel, args: [String: JSONValue]) async {
        busy = true
        defer { busy = false }
        do {
            let reply = try await core.send("t3code_integration", args: args, timeout: 10)
            if reply.ok, let parsed = T3CodeStatus.parse(reply.result) {
                status = parsed
                error = nil
                followUpIfSettling(parsed, core: core)
            } else if !args.isEmpty {
                error = reply.error?.message ?? "The monitor refused the change."
            }
        } catch {
            if !args.isEmpty { self.error = "The monitor is not answering." }
        }
    }
}

/// Settings › Agents' T3 Code row — shown only when T3 Code's database is
/// on this Mac. The switch is the opt-in; nothing is read before it.
struct T3CodeRow: View {
    let model: T3CodeModel
    let core: CoreModel

    private var style: ProviderStyle { ProviderStyle.style(for: "t3code") }

    var body: some View {
        if let status = model.status, status.present {
            HStack(alignment: .top, spacing: 10) {
                ProviderTile(style: style, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name)
                    Text(model.error ?? status.line)
                        .font(.caption)
                        .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { DelayedWait(size: 12) }
                Toggle("Read T3 Code", isOn: Binding(
                    get: { status.enabled },
                    set: { model.setEnabled($0, core: core) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!core.isLive || model.busy || status.readOnly)
                    .help("Reads T3 Code's local database, read-only, to list its threads with your sessions")
            }
            .padding(.vertical, 1)
        }
    }
}
