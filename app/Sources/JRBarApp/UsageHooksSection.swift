import Foundation
import JRBarCore
import SwiftUI

/// Settings › Usage › Hooks: the usage hooks the monitor runs when a quota
/// event happens (`usage_hooks` in the settings document; the daemon's
/// `usage_event_hooks`). One switch for all of them, and one row per rule
/// with its own switch, a Test button and the rule's last result.
///
/// Rules are added from the command line (`jrbar usage-hooks add`), where
/// an absolute path is easy to type; this section shows them, says plainly
/// when one will never run and why, and runs any of them once on demand.
struct UsageHooksSection: View {
    @Bindable var store: SettingsStore
    var model: UsageHooksModel = .shared

    private var rules: [UsageHookRuleRow] { UsageHookRuleRow.rows(in: store.document) }

    var body: some View {
        SettingGroup("Hooks", note: Self.note) {
            SettingToggle(store, "Run usage hooks",
                          subtitle: "Runs your own program when a quota runs low, runs out, resets or a provider stops answering.",
                          path: "usage_hooks.enabled")
            if let problem = model.configProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if rules.isEmpty {
                Text("No rules yet. Add one with jrbar usage-hooks add --event quota_low /path/to/script.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .settingRowStyle()
            }
            ForEach(rules) { rule in
                UsageHookRuleView(store: store, model: model, rule: rule)
            }
        }
        .task { await model.refresh(core: store.core) }
    }

    static let note = "Hooks run directly, never through a shell, with a small environment and the event as JSON on stdin. Resets are the confirmed ones the celebrations use."
}

/// One rule: what it answers to, what it runs, its switch, Test, and the
/// last thing that happened.
struct UsageHookRuleView: View {
    @Bindable var store: SettingsStore
    var model: UsageHooksModel
    let rule: UsageHookRuleRow

    private var problem: String? { rule.localProblem ?? model.problems[rule.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: store.bool("usage_hooks.rules.\(rule.index).enabled", default: true)) {
                    SettingLabel(title: rule.scopeText, subtitle: rule.commandText)
                }
                Button(model.testing.contains(rule.id) ? "Testing…" : "Test") {
                    _ = Task { await model.test(rule, core: store.core) }
                }
                .controlSize(.small)
                .disabled(model.testing.contains(rule.id) || problem != nil || !store.core.isLive)
                .help("Run this rule once now with a made-up \(rule.testEvent) event")
            }
            if let problem {
                Label("Will not run: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let last = model.lastResults[rule.id] {
                Label(last.line(now: Date()), systemImage: last.ok ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(last.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .monospacedDigit()
            }
        }
        .settingRowStyle()
    }
}

/// A rule as the settings document holds it (`usage_hooks.rules[n]`).
struct UsageHookRuleRow: Identifiable, Hashable {
    let index: Int
    let id: String
    let enabled: Bool
    let event: String
    let provider: String?
    let threshold: Double?
    let executable: String
    let arguments: [String]
    let legacyArgv: Bool

    static func rows(in document: SettingsDocument) -> [UsageHookRuleRow] {
        guard let items = document.array("usage_hooks.rules") else { return [] }
        return items.enumerated().compactMap { index, item in
            guard let object = item.objectValue else { return nil }
            return UsageHookRuleRow(
                index: index,
                id: object["id"]?.stringValue ?? "rule-\(index + 1)",
                enabled: object["enabled"]?.boolValue ?? true,
                event: object["event"]?.stringValue ?? "*",
                provider: object["provider"]?.stringValue,
                threshold: object["threshold_remaining"]?.doubleValue,
                executable: object["executable"]?.stringValue ?? "",
                arguments: object["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                legacyArgv: object["argv"]?.stringValue == "legacy")
        }
    }

    static let eventWords: [String: String] = [
        "*": "Every event",
        "quota_low": "Quota low",
        "quota_reached": "Quota reached",
        "quota_reset": "Window reset",
        "usage_updated": "Usage updated",
        "provider_unavailable": "Provider unavailable",
        "provider_recovered": "Provider recovered",
        "refresh_failed": "Refresh failed",
    ]

    /// "Quota low · Claude · at or below 20% left".
    var scopeText: String {
        var parts = [Self.eventWords[event] ?? event]
        if let provider { parts.append(ProviderStyle.style(for: provider).name) }
        if let threshold { parts.append("at or below \(Int(threshold.rounded()))% left") }
        return parts.joined(separator: " · ")
    }

    /// "Runs ~/bin/chime.sh --loud", with a note for a migrated rule.
    var commandText: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = executable.hasPrefix(home + "/") ? "~" + executable.dropFirst(home.count) : Substring(executable)
        let command = ([String(path)] + arguments).joined(separator: " ")
        return legacyArgv ? "Runs \(command), with the first version's arguments" : "Runs \(command)"
    }

    /// What the app can tell without asking the monitor.
    var localProblem: String? {
        if executable.isEmpty { return "no program to run" }
        if !executable.hasPrefix("/") { return "the executable must be an absolute path" }
        if event != "*" && Self.eventWords[event] == nil { return "unknown event \(event)" }
        return nil
    }

    /// The event the Test button sends: the rule's own, or quota_low.
    var testEvent: String { event == "*" ? "quota_low" : event }
}

/// A rule's last run, as `usage_hooks_status` and `usage_hooks_test` report it.
struct UsageHookLastResult: Hashable {
    let sentence: String
    let at: Double?
    let ok: Bool

    init(sentence: String, at: Double?, ok: Bool) {
        self.sentence = sentence
        self.at = at
        self.ok = ok
    }

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue, let sentence = object["sentence"]?.stringValue else { return nil }
        self.init(sentence: sentence, at: object["at"]?.doubleValue, ok: object["outcome"]?.stringValue == "ok")
    }

    /// "Last run: quota_low: exit 0 in 0.1 s · 3m ago".
    func line(now: Date) -> String {
        guard let at, let age = PanelStore.elapsed(since: Date(timeIntervalSince1970: at), now: now) else {
            return "Last run: \(sentence)"
        }
        return "Last run: \(sentence) · \(age) ago"
    }
}

/// The monitor's side of the Hooks section: why a rule will not run, the
/// last result per rule, and the Test button's round trip.
@MainActor
@Observable
final class UsageHooksModel {
    static let shared = UsageHooksModel()

    var lastResults: [String: UsageHookLastResult] = [:]
    var problems: [String: String] = [:]
    var configProblem: String?
    var testing: Set<String> = []

    func apply(status: JSONValue?) {
        guard let object = status?.objectValue else { return }
        configProblem = object["problem"]?.stringValue
        var problems: [String: String] = [:]
        var results: [String: UsageHookLastResult] = [:]
        for rule in object["rules"]?.arrayValue ?? [] {
            guard let row = rule.objectValue, let id = row["id"]?.stringValue else { continue }
            if let problem = row["problem"]?.stringValue { problems[id] = problem }
            if let result = UsageHookLastResult(row["last_result"]) { results[id] = result }
        }
        self.problems = problems
        lastResults = lastResults.merging(results) { _, fresh in fresh }
    }

    func refresh(core: CoreModel) async {
        guard core.isLive, let reply = try? await core.send("usage_hooks_status"), reply.ok else { return }
        apply(status: reply.result)
    }

    func test(_ rule: UsageHookRuleRow, core: CoreModel) async {
        testing.insert(rule.id)
        defer { testing.remove(rule.id) }
        let args: [String: JSONValue] = [
            "rule": .string(rule.id),
            "event": .string(rule.testEvent),
            "provider": .string(rule.provider ?? "claude"),
        ]
        do {
            let reply = try await core.send("usage_hooks_test", args: args, timeout: 12)
            guard reply.ok else {
                let why = reply.error?.message ?? "the monitor refused the test"
                lastResults[rule.id] = UsageHookLastResult(sentence: why, at: Date().timeIntervalSince1970, ok: false)
                return
            }
            apply(status: reply.result?["status"])
            if let first = reply.result?["results"]?.arrayValue?.first, let result = UsageHookLastResult(first) {
                lastResults[rule.id] = result
            }
        } catch {
            lastResults[rule.id] = UsageHookLastResult(sentence: "the monitor did not answer", at: Date().timeIntervalSince1970, ok: false)
        }
    }
}
