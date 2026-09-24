import JRBarCore
import SwiftUI

/// Settings › Usage: the sections lane oss adds under Quota alerts — the
/// Claude Code status line and the usage hooks — behind one mount.
struct UsageExtrasSections: View {
    @Bindable var store: SettingsStore

    var body: some View {
        ClaudeStatusLineSection(store: store)
        UsageHooksSection(store: store)
    }
}

/// Settings › Usage › Claude Code status line: an opt-in source for the
/// Claude 5-hour and weekly numbers, from Claude Code's own status line.
///
/// Turning it on points Claude Code's `statusLine` at JR-Bar's shim
/// (`claude_statusline_install`). Someone's own status line is never
/// replaced: the switch asks first and, with a yes, keeps it and shows
/// JR-Bar's line above it. Turning it off puts back exactly what was there.
struct ClaudeStatusLineSection: View {
    @Bindable var store: SettingsStore
    @ViewState private var busy = false
    /// The daemon's words when an existing status line needs a yes first.
    @ViewState private var askToWrap: String?
    @ViewState private var failure: String?

    private var on: Bool { store.document.bool("claude_statusline_source") ?? false }

    var body: some View {
        SettingGroup("Claude Code status line", note: Self.note) {
            Provided(store, "claude_statusline_source") {
                Toggle(isOn: Binding(get: { on }, set: { wanted in change(wanted) })) {
                    SettingLabel(title: "Read Claude Code's status line", subtitle: Self.subtitle)
                }
                .disabled(busy || !store.core.isLive)
            }
            if let askToWrap {
                VStack(alignment: .leading, spacing: 6) {
                    Label(askToWrap, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Keep Mine and Add JR-Bar's Line") { install(wrap: true) }
                        Button("Cancel") { self.askToWrap = nil }
                    }
                    .controlSize(.small)
                }
                .settingRowStyle()
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            SettingToggle(store, "Show JR-Bar's line", subtitle: "\"JR-Bar · 2 working · 5h 58% left\" in Claude Code. Off keeps only the reading.",
                          path: "statusline_text_enabled", default: true)
                .disabled(!on)
        }
    }

    static let subtitle = "Claude Code reports your 5-hour and weekly limits after each reply. JR-Bar uses them when the usage endpoint is rate limited or signed out."
    static let note = "Only the rate limits, the model and the session id are kept. The status line never counts as agent activity."

    private func change(_ wanted: Bool) {
        if wanted { install(wrap: false) } else { uninstall() }
    }

    private func install(wrap: Bool) {
        busy = true
        failure = nil
        let core = store.core
        _ = Task {
            defer { busy = false }
            do {
                let reply = try await core.send("claude_statusline_install", args: ["wrap": .bool(wrap)])
                guard reply.ok else {
                    failure = reply.error?.message ?? "The monitor could not install the status line."
                    return
                }
                if reply.result?["needs_wrap"]?.boolValue == true {
                    askToWrap = reply.result?["message"]?.stringValue ?? "Claude Code already has a status line."
                } else {
                    askToWrap = nil
                }
            } catch {
                failure = "The monitor did not answer."
            }
        }
    }

    private func uninstall() {
        busy = true
        failure = nil
        askToWrap = nil
        let core = store.core
        _ = Task {
            defer { busy = false }
            do {
                let reply = try await core.send("claude_statusline_uninstall")
                if !reply.ok { failure = reply.error?.message ?? "The monitor could not remove the status line." }
            } catch {
                failure = "The monitor did not answer."
            }
        }
    }
}
