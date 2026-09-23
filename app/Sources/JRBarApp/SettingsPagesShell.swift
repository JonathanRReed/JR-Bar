import AppKit
import JRBarCore
import SwiftUI

// MARK: - Sounds

/// What JR-Bar sounds like: a sound (or silence) per moment with a
/// preview, one volume, and whether sounds follow macOS's alert device
/// so a chime stays on the speakers while a call runs in AirPods. The
/// person's own sounds in ~/Library/Sounds are offered beside the
/// system's.
struct SoundsPage: View {
    @Bindable var store: SettingsStore

    private func choice(_ role: SoundRole) -> Binding<String> {
        Binding(get: { store.soundPreferences.choices[role] ?? "" },
                set: { store.soundPreferences.choices[role] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        let available = SoundPlayer.availableSounds()
        SettingGroup("Event sounds", note: "Sounds stay silent in Pause, Dim and Dark quiet, and when the asking session is already in front.") {
            ForEach(SoundRole.allCases, id: \.self) { role in
                SettingRow(role.title, subtitle: role.subtitle) {
                    HStack(spacing: 6) {
                        Picker(role.title, selection: choice(role)) {
                            Text("\(role.defaultSound) (default)").tag("")
                            Text("None").tag(SoundPreferences.silent)
                            Divider()
                            ForEach(available.system, id: \.self) { Text($0).tag($0) }
                            if !available.custom.isEmpty {
                                Divider()
                                ForEach(available.custom, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Button {
                            store.previewSound(store.soundPreferences.choices[role] ?? role.defaultSound)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.soundPreferences.choices[role] == SoundPreferences.silent)
                        .help("Play it")
                        .accessibilityLabel("Preview \(role.title)")
                    }
                }
            }
        }

        SettingGroup("Volume") {
            SettingRow("JR-Bar sounds", subtitle: "Every sound above, apart from the Mac's own volume.") {
                HStack(spacing: 10) {
                    Slider(value: $store.soundPreferences.volume, in: 0...1) { editing in
                        if !editing { store.previewSound(SoundRole.completion.defaultSound) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityLabel("JR-Bar sound volume")
                    ValueText(text: SettingsStore.percent(store.soundPreferences.volume))
                }
            }
        }

        SettingGroup("Output", note: "The alert device is System Settings › Sound › Play sound effects through.") {
            Toggle(isOn: $store.soundPreferences.useAlertDevice) {
                SettingLabel(title: "Play through the alert device",
                             subtitle: "Sounds go where macOS plays its own alerts, not to the current output — a chime stays off your AirPods on a call.")
            }
            .settingRowStyle()
        }

        SettingGroup("Your own sounds", note: "Drop .aiff, .caf, .wav or .m4a files here and they join the menus above.") {
            SettingRow("Sounds folder", subtitle: "~/Library/Sounds, where macOS keeps custom alerts.") {
                Button("Show in Finder") {
                    let folder = URL(fileURLWithPath: SoundPlayer.userSoundsFolder)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Advanced › Report

/// The Advanced page's closing group: the whole picture — builds,
/// Doctor, permissions, the log — as one redacted block for a bug report
/// or a paste into a Claude session.
struct DiagnosticsCopyGroup: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingGroup("Report") {
            SettingRow("Copy diagnostics",
                       subtitle: "Version, build and commit beside the monitor's, the Doctor's checks, every permission and the last \(DiagnosticsReport.logLines) log lines — home folder, tokens, addresses and webhook paths taken out.") {
                Button(store.diagnosticsCopying ? "Copying…" : "Copy") { store.copyDiagnostics() }
                    .controlSize(.small)
                    .disabled(store.diagnosticsCopying)
            }
        }
    }
}

// MARK: - Shortcuts

/// Every global shortcut JR-Bar holds, on one page, each with a real
/// recorder: the panel and shelf summons, the Menu Bar utility's keys,
/// and the app actions any key can be bound to. The rows read the one
/// `HotkeyCenter`, so a key another app owns or another row already
/// holds is named where it happened — Raycast's Shortcuts tab, for the
/// things JR-Bar does.
struct ShortcutsPage: View {
    @Bindable var store: SettingsStore
    var center: HotkeyCenter = .shared

    var body: some View {
        SettingGroup("JR-Bar", note: "These work in every app. Click a shortcut, then press the new keys — Esc cancels, Delete clears it.") {
            ShortcutRow(title: "Show the panel", id: PanelHotkey.panelID,
                        chord: store.panelHotkeyChord, isOn: $store.panelHotkeyEnabled,
                        center: center,
                        onChange: { store.setShortcut($0, for: PanelHotkey.panelID) },
                        onTakeOver: { store.setShortcut(nil, for: $0) })
            ShortcutRow(title: "Open the shelf", subtitle: "Folds it again on a second press.",
                        id: PanelHotkey.shelfID,
                        chord: store.shelfHotkeyChord, isOn: $store.shelfHotkeyEnabled,
                        center: center,
                        onChange: { store.setShortcut($0, for: PanelHotkey.shelfID) },
                        onTakeOver: { store.setShortcut(nil, for: $0) })
        }

        SettingGroup("Actions", note: "No key until you record one. The same actions answer to jrbar:// links, below.") {
            ForEach(AppShortcutCatalog.actions) { action in
                ShortcutRow(title: action.title, id: action.id,
                            chord: store.actionShortcut(action.id), center: center,
                            onChange: { store.setShortcut($0, for: action.id) },
                            onTakeOver: { store.setShortcut(nil, for: $0) })
            }
        }

        QuickTogglesGroup(store: store, center: center)

        if let menuBar = store.utilities?.menuBar {
            SettingGroup("Menu bar", note: menuBar.isOn
                         ? "Held while the Menu Bar utility runs."
                         : "The Menu Bar utility is off, so these keys are not held. Turn it on in Utilities.") {
                ForEach(menuBar.resolvedHotkeyBindings(), id: \.action) { binding in
                    ShortcutRow(title: MenuBarHotkeys.title(for: binding.action),
                                id: MenuBarHotkeys.registryID(for: binding.action),
                                chord: HotkeyChord(binding),
                                isOn: Binding(get: { binding.enabled },
                                              set: { menuBar.setHotkeyEnabled($0, for: binding.action) }),
                                center: center,
                                onChange: { menuBar.setHotkeyChord($0, for: binding.action) },
                                onTakeOver: { store.setShortcut(nil, for: $0) })
                }
            }
        }

        LinksGroup()
        CommandLineGroup()
    }
}

/// `jrbar` in any terminal: a link at ~/.local/bin/jrbar to this app's
/// own CLI, installed or removed here, never over someone else's file.
private struct CommandLineGroup: View {
    @ViewState private var state: CommandLineTool.State = .unavailable
    @ViewState private var failure: String?

    private var bundled: String? { CoreSupervisor.bundledCore(in: .main)?.executable }
    private var link: URL { CommandLineTool.linkURL() }

    private var subtitle: String {
        switch state {
        case .unavailable: return "This build carries no bundled jrbar; a source checkout's own venv has one."
        case .notInstalled: return "Links ~/.local/bin/jrbar to this app's jrbar. ~/.local/bin must be on your PATH."
        case .installed: return "~/.local/bin/jrbar runs this app's jrbar — try jrbar status."
        case .stale: return "~/.local/bin/jrbar points at an older JR-Bar; Install moves it to this one."
        case .occupied: return "~/.local/bin/jrbar is another program, so JR-Bar leaves it alone."
        }
    }

    var body: some View {
        SettingGroup("Command line", note: failure) {
            SettingRow("jrbar in Terminal", subtitle: subtitle) {
                switch state {
                case .notInstalled, .stale:
                    Button("Install") { run { try CommandLineTool.install(link: link, bundled: $0) } }
                        .controlSize(.small)
                case .installed:
                    Button("Remove") { run { _ in try CommandLineTool.uninstall(link: link, bundled: bundled) } }
                        .controlSize(.small)
                case .unavailable, .occupied:
                    EmptyView()
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        state = CommandLineTool.state(link: link, bundled: bundled)
    }

    private func run(_ change: (String) throws -> Void) {
        guard let bundled else { return }
        do {
            try change(bundled)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

/// Every chip the notch strip can show: whether it is on the strip, and
/// a key for it — OnlySwitch's hotkey for every switch, on the one
/// store the card, links and Shortcuts share.
private struct QuickTogglesGroup: View {
    @Bindable var store: SettingsStore
    let center: HotkeyCenter
    private var toggles: SystemTogglesStore { .shared }

    var body: some View {
        SettingGroup("Quick toggles", note: "Checked chips show on the notch card's strip, in this order. Each can have its own key.") {
            ForEach(SystemToggle.allCases, id: \.rawValue) { toggle in
                let id = AppShortcutCatalog.toggleID(toggle)
                LabeledContent {
                    HStack(alignment: .top, spacing: 10) {
                        ShortcutRecorderField(id: id, chord: store.actionShortcut(id), center: center,
                                              onChange: { store.setShortcut($0, for: id) },
                                              onTakeOver: { store.setShortcut(nil, for: $0) })
                        Toggle("Strip", isOn: Binding(get: { toggles.strip.contains(toggle) },
                                                      set: { toggles.setInStrip(toggle, $0) }))
                            .toggleStyle(.checkbox)
                            .help("Show this chip on the notch card")
                    }
                } label: {
                    Label {
                        Text(toggle.longTitle)
                    } icon: {
                        Image(systemName: toggle.symbol)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingRowStyle()
            }
            Toggle(isOn: Binding(get: { toggles.awakeKeepsDisplay },
                                 set: { toggles.setAwakeKeepsDisplay($0) })) {
                SettingLabel(title: "Keep awake holds the display too",
                             subtitle: "No screen saver and no lock while held — for a talk or a long build log. Off keeps only the Mac awake.")
            }
            .settingRowStyle()
        }
    }
}

/// The `jrbar://` vocabulary, copyable — for Raycast Quicklinks, Alfred,
/// Shortcuts' Open URL, a deck key, or `open` in a script.
private struct LinksGroup: View {
    static let examples: [(link: String, what: String)] = [
        ("jrbar://panel/toggle", "Show or hide the panel"),
        ("jrbar://toggle/dark", "Flip a quick toggle (add ?on=1 or ?on=0 to set it)"),
        ("jrbar://awake?for=2h", "Keep awake for a while (for=off lets go)"),
        ("jrbar://quiet?mode=dim&for=1h", "Quiet JR-Bar (jrbar://quiet/end ends it)"),
        ("jrbar://ask", "Open the panel on the waiting ask"),
        ("jrbar://menubar/reveal", "Reveal the hidden menu bar items"),
        ("jrbar://settings/shortcuts", "Open Settings on a page"),
    ]

    var body: some View {
        SettingGroup("Links", note: "Links never answer an ask — Approve and Deny stay where the ask is on screen.") {
            ForEach(Self.examples, id: \.link) { example in
                LabeledContent {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(example.link, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy \(example.link)")
                    .accessibilityLabel("Copy \(example.link)")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.link)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(example.what)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingRowStyle()
            }
        }
    }
}
