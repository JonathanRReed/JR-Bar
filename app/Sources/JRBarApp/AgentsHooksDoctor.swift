import Foundation
import JRBarCore
import Observation
import SwiftUI

/// `hooks_doctor` for Settings › Agents: one line per provider saying
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
    /// The CLI's own `--version`, when the doctor found it.
    var version: String? = nil
    /// How that version stands against what JR-Bar verified: "verified",
    /// "newer than verified (2.1.263)", … A note, never a warning.
    var compatibilityNote: String? = nil

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
        guard entry.installed else { return nil }
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
        line(entry) != nil && versionWords(entry) != nil
    }

    /// "12 events hooked · last event 4 min ago · 3 queued · answers
    /// from JR-Bar" — nil for a provider with nothing installed, which
    /// the row's own "Not installed" already says.
    static func line(_ entry: HooksDoctorEntry, now: Date = Date()) -> String? {
        guard entry.installed else { return nil }
        var parts = ["\(entry.hookEvents) event\(entry.hookEvents == 1 ? "" : "s") hooked"]
        if let at = entry.lastEventAt {
            let ago = PanelStore.elapsed(since: Date(timeIntervalSince1970: at), now: now)
            parts.append(ago.map { "last event \($0) ago" } ?? "last event just now")
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
        return parts.joined(separator: " · ")
    }
}

/// The report, read when the Agents page shows and again after every
/// install or removal settles, so the line follows what just changed.
@MainActor
@Observable
final class HooksDoctorModel {
    private(set) var entries: [String: HooksDoctorEntry] = [:]
    private(set) var loading = false
    /// The last read failed; the lines keep what they had.
    private(set) var failed = false

    nonisolated init() {}

    func entry(for provider: String) -> HooksDoctorEntry? { entries[provider] }

    func refresh(core: CoreModel) {
        guard core.isLive, !loading else { return }
        loading = true
        Task { [weak self] in
            let reply = try? await core.send("hooks_doctor", timeout: 10)
            guard let self else { return }
            self.loading = false
            if let reply, reply.ok {
                self.entries = HooksDoctor.entries(from: reply.result)
                self.failed = false
            } else {
                self.failed = true
            }
        }
    }
}

// MARK: - Updating a provider's CLI

/// Settings › Agents' update line for one provider: the version installed,
/// "2.1.290 available" when update checks are on and a newer one is known,
/// and the daemon's own one-line result of the last Update click. The words
/// are the daemon's (`state.provider_updates`); this only decides which of
/// them are worth showing.
enum ProviderUpdateWords {
    /// The providers the daemon has an updater for (`provider_update`).
    nonisolated static let updatable: Set<String> = ["claude", "codex", "grok", "devin", "opencode"]

    /// Said for Gemini CLI, which has no updater of its own; no button.
    nonisolated static let geminiAdvice =
        "Gemini CLI has no updater of its own: update it the way you installed it (for example `brew upgrade gemini-cli` or `npm install -g @google/gemini-cli`)."

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

    /// Whether the row's Update button can be pressed.
    nonisolated static func canUpdate(provider: String, status: ProviderUpdateStatus?, live: Bool, busy: Bool) -> Bool {
        hasUpdater(provider) && live && !busy && status?.isRunning != true
    }
}

/// One provider's update line under its Agents row: the version, the Update
/// button (T3 Code's pattern: it runs the CLI's own updater, and only when
/// clicked) and the daemon's one-line result. Gemini CLI has no updater of
/// its own, so it gets the advice and no button.
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
                        .font(.caption)
                        .foregroundStyle(status?.updateAvailable == true ? Color.primary : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if ProviderUpdateWords.hasUpdater(provider) {
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
                                                             live: store.isLive, busy: running))
                    .help("Runs \(name)'s own updater. Nothing runs until you click.")
                    .accessibilityLabel(running ? "Updating \(name)" : "Update \(name)")
                }
            }
            if let result = ProviderUpdateWords.resultLine(status, now: Date()) {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(status?.phase == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == "gemini" {
                Text(ProviderUpdateWords.geminiAdvice)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
