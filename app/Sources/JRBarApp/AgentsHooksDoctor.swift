import JRBarUI
import Foundation
import JRBarCore
import Observation
import SwiftUI

/// `hooks_doctor` for Settings › Providers: one line per provider saying
/// how its hooks stand — how many events are hooked, when one last
/// reached the monitor, what is queued while it was away — and, where
/// something is off, why and a Repair (`install_hooks`) beside it. The
/// daemon's report is content-free (paths, shapes, counts and times),
/// and nothing here writes anything until Repair is clicked.
struct HooksDoctorEntry: Equatable, Sendable {
    let provider: String
    let installed: Bool
    let hookEvents: Int
    /// The shapes the registered commands take: `shim`, `python`,
    /// `legacy`, `foreign`, `none`, `unknown`.
    let registered: [String]
    /// The shape a Repair would write.
    let wouldInstall: String?
    /// Claude and Codex only: `installed`, `missing` or `not_installed`
    /// for the permission hook that answers from JR-Bar.
    let decide: String?
    let lastEventAt: Double?
    let pendingLines: Int
    let error: String?
    /// False when the hooks are installed but the agent's own settings turn
    /// them off (Claude's `disableAllHooks`, Codex's hooks feature); nil from
    /// a monitor that does not say.
    var hooksEnabled: Bool? = nil
    /// The CLI's own `--version`, when the doctor found it.
    var version: String? = nil
    /// How that version stands against what JR-Bar verified: "verified",
    /// "newer than verified (2.1.263)", … A note, never a warning.
    var compatibilityNote: String? = nil
    var isStale = false

    init(provider: String, installed: Bool = false, hookEvents: Int = 0, registered: [String] = [],
         wouldInstall: String? = nil, decide: String? = nil, lastEventAt: Double? = nil,
         pendingLines: Int = 0, error: String? = nil) {
        self.provider = provider
        self.installed = installed
        self.hookEvents = hookEvents
        self.registered = registered
        self.wouldInstall = wouldInstall
        self.decide = decide
        self.lastEventAt = lastEventAt
        self.pendingLines = pendingLines
        self.error = error
    }

    init?(_ value: JSONValue) {
        guard let provider = value["provider"]?.stringValue, !provider.isEmpty else { return nil }
        self.init(provider: provider,
                  installed: value["installed"]?.boolValue ?? false,
                  hookEvents: value["hook_events"]?.intValue ?? 0,
                  registered: value["registered"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  wouldInstall: value["would_install"]?.stringValue,
                  decide: value["decide"]?.stringValue,
                  lastEventAt: value["last_event_at"]?.doubleValue,
                  pendingLines: value["pending_lines"]?.intValue ?? 0,
                  error: value["error"]?.stringValue)
        hooksEnabled = value["hooks_enabled"]?.boolValue
        version = value["version"]?.stringValue
        compatibilityNote = value["compatibility"]?["note"]?.stringValue
    }
}

enum HooksDoctor {
    /// The report's providers, by id.
    static func entries(from result: JSONValue?) -> [String: HooksDoctorEntry] {
        var out: [String: HooksDoctorEntry] = [:]
        for value in result?["providers"]?.arrayValue ?? [] {
            if let entry = HooksDoctorEntry(value) { out[entry.provider] = entry }
        }
        return out
    }

    /// Why a provider wants a Repair, or nil when it does not. The one
    /// that matters most first: without the permission hook, Approve and
    /// Deny can only type into a terminal JR-Bar can prove, so Ghostty
    /// and IDE sessions fall back to Open.
    static func repairReason(_ entry: HooksDoctorEntry) -> String? {
        guard entry.installed, entry.error == nil else { return nil }
        if entry.hooksEnabled == false {
            return "Hooks are turned off in the agent's own settings — Repair turns them back on"
        }
        if entry.decide == "missing" {
            return "Answering from JR-Bar isn't hooked up — Repair adds the permission hook"
        }
        let current = entry.wouldInstall ?? "shim"
        if entry.registered.contains(where: { $0 == "legacy" || $0 == "python" }), current == "shim" {
            return "Runs an older hook command — Repair moves it to the fast one"
        }
        return nil
    }

    /// "v2.1.280, newer than verified (2.1.263)": the CLI's version with
    /// the doctor's note, told plainly, never as a problem.
    static func versionWords(_ entry: HooksDoctorEntry) -> String? {
        guard let version = entry.version, !version.isEmpty else { return nil }
        guard let note = entry.compatibilityNote, !note.isEmpty, note != "verified" else { return "v\(version)" }
        return "v\(version), \(note)"
    }

    /// Whether `line` carries the CLI's version, so the update line under it
    /// need not repeat it: the entry has hooks installed and a version.
    static func lineShowsVersion(_ entry: HooksDoctorEntry) -> Bool {
        entry.error == nil && line(entry) != nil && versionWords(entry) != nil
    }

    /// "12 events hooked · last event 4 min ago · 3 queued · answers
    /// from JR-Bar" — nil for a provider with nothing installed, which
    /// the row's own "Not installed" already says.
    static func line(_ entry: HooksDoctorEntry, now: Date = Date()) -> String? {
        let prefix = entry.isStale ? "Last report · " : ""
        if let error = entry.error, !error.isEmpty {
            return prefix + "Could not read hook settings: \(error)"
        }
        guard entry.installed else { return nil }
        if entry.hooksEnabled == false {
            return prefix + "\(entry.hookEvents) event\(entry.hookEvents == 1 ? "" : "s") hooked, but turned off in the agent's own settings"
        }
        var parts = ["\(entry.hookEvents) event\(entry.hookEvents == 1 ? "" : "s") hooked"]
        if let at = entry.lastEventAt {
            if at.isFinite, at > 0, at <= now.timeIntervalSince1970 {
                parts.append("last event \(UsageTime.ago(now.timeIntervalSince1970 - at))")
            } else {
                parts.append("event time unavailable")
            }
        } else {
            parts.append("no event yet")
        }
        if entry.pendingLines > 0 {
            parts.append("\(entry.pendingLines) queued")
        }
        if entry.decide == "installed" {
            parts.append("answers from JR-Bar")
        }
        if let version = versionWords(entry) {
            parts.append(version)
        }
        return prefix + parts.joined(separator: " · ")
    }
}

/// The report, read when the Agents page shows and again after every
/// install or removal settles, so the line follows what just changed.
@MainActor
@Observable
final class HooksDoctorModel {
    private(set) var entries: [String: HooksDoctorEntry] = [:]
    private(set) var checkedAt: Double?
    private(set) var receiverAnswers: Bool?
    /// "3 hook events were refused today. The newest: …", or nil when
    /// none were (the report's `rejected.sentence`).
    private(set) var refusedLine: String?
    private(set) var loading = false
    /// The last read failed; the lines keep what they had.
    private(set) var failed = false
    @ObservationIgnored private var pendingRefresh: (@MainActor () async throws -> CoreReply)?

    nonisolated init() {}

    func entry(for provider: String, live: Bool = true) -> HooksDoctorEntry? {
        guard var entry = entries[provider] else { return nil }
        entry.isStale = failed || loading || !live
        return entry
    }

    @discardableResult
    func refresh(core: CoreModel) -> Task<Void, Never>? {
        guard core.isLive else { return nil }
        return refresh {
            let reply = try await core.send("hooks_doctor", timeout: 10)
            return core.isLive ? reply : CoreReply(id: reply.id, ok: false)
        }
    }

    @discardableResult
    func recheck(core: CoreModel) -> Task<Void, Never>? {
        recheck(live: core.isLive) { name, timeout in
            let reply = try await core.send(name, timeout: timeout)
            return core.isLive ? reply : CoreReply(id: reply.id, ok: false)
        }
    }

    @discardableResult
    func recheck(live: Bool,
                 send: @escaping @MainActor (String, TimeInterval) async throws -> CoreReply) -> Task<Void, Never>? {
        guard live, !loading else { return nil }
        return refresh { try await send("hooks_doctor", 10) }
    }

    func statusLine(live: Bool, now: Date = Date()) -> String {
        if !live { return "\(MonitorWords.sentence) Recheck when it reconnects." }
        if loading { return "Checking hooks…" }
        if failed { return entries.isEmpty ? "Recheck failed. No report available." : "Recheck failed. Showing the last report." }
        if let checkedAt, checkedAt > 0, checkedAt <= now.timeIntervalSince1970 {
            return "Checked \(UsageTime.ago(now.timeIntervalSince1970 - checkedAt))"
        }
        return entries.isEmpty ? "No hook report yet" : "Hook report loaded"
    }

    func receiverLine(live: Bool) -> String? {
        guard !entries.isEmpty || checkedAt != nil else { return nil }
        let prefix = failed || loading || !live ? "Last report · " : ""
        switch receiverAnswers {
        case .some(true): return prefix + "Hook receiver answering"
        case .some(false): return prefix + "Hook receiver not answering"
        case nil: return prefix + "Hook receiver status unavailable"
        }
    }

    /// An install can finish while the first report is reading. Keep one
    /// follow-up read so that report cannot hide the install's result.
    @discardableResult
    func refresh(load: @escaping @MainActor () async throws -> CoreReply) -> Task<Void, Never>? {
        guard !loading else {
            pendingRefresh = load
            return nil
        }
        loading = true
        return Task { [weak self] in
            guard let self else { return }
            defer { self.loading = false }
            var read = load
            while true {
                let reply = try? await read()
                if let pending = self.pendingRefresh {
                    self.pendingRefresh = nil
                    read = pending
                    continue
                }
                if let reply, reply.ok, reply.result?["providers"]?.arrayValue != nil {
                    self.entries = HooksDoctor.entries(from: reply.result)
                    let checkedAt = reply.result?["checked_at"]?.doubleValue
                    self.checkedAt = checkedAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    self.receiverAnswers = reply.result?["ingress_socket"]?["answers"]?.boolValue
                    let refused = reply.result?["rejected"]?["sentence"]?.stringValue
                    self.refusedLine = refused?.isEmpty == false ? refused : nil
                    self.failed = false
                } else {
                    self.failed = true
                }
                return
            }
        }
    }
}

struct HooksDoctorStatusRow: View {
    @Bindable var doctor: HooksDoctorModel
    let live: Bool
    var onRecheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doctor.statusLine(live: live))
                    .jrbarType(.caption)
                    .foregroundStyle(doctor.failed && live ? Tone.failure.color : Color.secondary)
                if let line = doctor.receiverLine(live: live) {
                    Text(line)
                        .jrbarType(.caption)
                        .foregroundStyle(doctor.receiverAnswers == false ? Tone.failure.color : Color.secondary)
                }
                if let refused = doctor.refusedLine {
                    Text(refused)
                        .jrbarType(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Recheck hooks", action: onRecheck)
                .controlSize(.small)
                .disabled(!live || doctor.loading)
                .help("Read local hook configuration, receiver health and last event arrival without changing anything")
        }
        .padding(.top, 8)
    }
}

// MARK: - Updating a provider's CLI

/// Settings › Agents & Usage' update line for one provider: the version installed,
/// "2.1.290 available" when update checks are on and a newer one is known,
/// and the daemon's own one-line result of the last Update click. The words
/// are the daemon's (`state.provider_updates`); this only decides which of
/// them are worth showing.
enum ProviderUpdateWords {
    /// The providers the daemon has an updater for (`provider_update`).
    nonisolated static let updatable: Set<String> = ["claude", "codex", "grok", "devin", "opencode", "gemini"]

    /// Gemini updates depend on its installation manager.
    nonisolated static let geminiAdvice =
        "Update supports Gemini CLI installed with npm or Homebrew. For other installations, use the original installer."

    /// How long a finished, successful run stays on the row. A failure, or
    /// an updater waiting for a terminal, stays until the next click.
    nonisolated static let successLife: TimeInterval = 600

    nonisolated static func hasUpdater(_ provider: String) -> Bool { updatable.contains(provider) }

    /// Whether the row says anything about updating: it has an updater, or
    /// it is Gemini CLI with its advice.
    nonisolated static func isRelevant(_ provider: String) -> Bool { hasUpdater(provider) || provider == "gemini" }

    /// "v2.1.285 · 2.1.290 available", or just one of them, or nil when
    /// nothing is known. A run that just finished names the version it
    /// installed, so the line is right before the doctor is read again.
    /// `includeInstalled` is false when the row's hook line above already
    /// says the version, so it is never said twice.
    nonisolated static func versionLine(installed: String?, status: ProviderUpdateStatus?,
                                        includeInstalled: Bool = true) -> String? {
        var parts: [String] = []
        let shown = (status?.phase == .updated ? status?.toVersion : nil) ?? installed
        if includeInstalled, let shown, !shown.isEmpty { parts.append("v\(shown)") }
        if let latest = status?.latestVersion, status?.phase != .running, status?.phase != .updated {
            parts.append("\(latest) available")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The daemon's sentence about the last run while it is worth showing.
    nonisolated static func resultLine(_ status: ProviderUpdateStatus?, now: Date) -> String? {
        guard let status, !status.message.isEmpty else { return nil }
        switch status.phase {
        case .idle: return nil
        case .running: return status.message
        case .failed, .needsTerminal: return status.message
        case .updated, .unchanged:
            guard let finished = status.finishedAt else { return status.message }
            return now.timeIntervalSince1970 - finished < successLife ? status.message : nil
        }
    }

    nonisolated static func showsUpdate(provider: String, status: ProviderUpdateStatus?, installed: String? = nil) -> Bool {
        guard hasUpdater(provider) else { return false }
        guard let status else { return true }
        if status.isRunning { return true }
        if status.updatable == false { return false }
        if status.updateAvailable { return true }
        if status.phase == .failed || status.phase == .needsTerminal { return true }
        if let installed, !installed.isEmpty, status.upToDateVersion == installed { return false }
        if status.phase == .updated { return false }
        if status.phase == .unchanged, let before = status.fromVersion, !before.isEmpty,
           status.toVersion == before { return false }
        return true
    }

    /// Whether the row's Update button can be pressed.
    nonisolated static func canUpdate(provider: String, status: ProviderUpdateStatus?, live: Bool, busy: Bool, installed: String? = nil) -> Bool {
        showsUpdate(provider: provider, status: status, installed: installed) && live && !busy && status?.isRunning != true
    }
}

/// The installed version, an explicit update action when available, and
/// the daemon's result. Gemini also explains which installers it supports.
struct ProviderUpdateLine: View {
    @Bindable var store: SettingsStore
    let provider: String
    /// The CLI's version from `hooks_doctor`.
    let version: String?
    /// True when the row's hook line above already says that version.
    var versionShownAbove = false

    private var name: String { store.providerStyle(provider).name }

    var body: some View {
        let status = store.core.providerUpdates[provider]
        let running = status?.isRunning == true || store.updateBusy.contains(provider)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let line = ProviderUpdateWords.versionLine(installed: version, status: status,
                                                              includeInstalled: !versionShownAbove) {
                    Text(line)
                        .jrbarType(.caption)
                        .foregroundStyle(status?.updateAvailable == true ? Color.primary : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if running || ProviderUpdateWords.showsUpdate(provider: provider, status: status, installed: version) {
                    Button {
                        store.updateProvider(provider)
                    } label: {
                        if running {
                            HStack(spacing: 4) {
                                DelayedWait(size: 10)
                                Text("Updating…")
                            }
                        } else {
                            Text("Update")
                        }
                    }
                    .controlSize(.small)
                    .disabled(!ProviderUpdateWords.canUpdate(provider: provider, status: status,
                                                             live: store.isLive, busy: running, installed: version))
                    .help("Updates \(name) using its updater or installation manager. Nothing runs until you click.")
                    .accessibilityLabel(running ? "Updating \(name)" : "Update \(name)")
                }
            }
            if let result = ProviderUpdateWords.resultLine(status, now: Date()) {
                Text(result)
                    .jrbarType(.caption)
                    .foregroundStyle(status?.phase == .failed ? Tone.failure.color : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let advice = status?.updateAdvice, !running, advice != status?.message {
                Text(advice)
                    .jrbarType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == "gemini", status?.updateAdvice != ProviderUpdateWords.geminiAdvice {
                Text(ProviderUpdateWords.geminiAdvice)
                    .jrbarType(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
