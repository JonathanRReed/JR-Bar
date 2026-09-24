import AppKit
import JRBarUI
import SwiftUI

/// The walkthrough's content: a five-step pager — Welcome, Agents,
/// Permissions, Menu bar & Screen Bar, Done — with the step's own header,
/// a progress read-out, and Back / Skip / the primary button.
struct SetupView: View {
    @Bindable var store: SetupStore

    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.step.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(store.step.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Group {
                switch store.step {
                case .welcome: SetupWelcomeStep()
                case .agents: SetupAgentsStep(store: store)
                case .permissions: SetupPermissionsStep(store: store)
                case .appearance: SetupAppearanceStep(store: store)
                case .done: SetupDoneStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(store.step)
            .transition(.opacity)
            .animation(PanelMotion.crossfade(reduced: reduced), value: store.step)

            footer
        }
        .frame(width: SetupWindowController.contentSize.width,
               height: SetupWindowController.contentSize.height)
    }

    /// Progress pips, Back, Skip and the primary button — Get Started,
    /// Next, or Finish on the last step (beside Open Toys).
    private var footer: some View {
        HStack(spacing: 12) {
            SetupProgress(step: store.step.index, count: store.stepCount)
            Text("Step \(store.stepNumber) of \(store.stepCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            if store.canGoBack {
                Button("Back") { store.goBack() }
            }
            if store.canSkip {
                Button("Skip") { store.skip() }
            }
            if store.step == .done {
                Button("Open Toys") { store.finishToToys() }
            }
            Button(store.nextTitle) { store.goNext() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

/// The progress read-out: one pip per step, the current one stretched.
struct SetupProgress: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == step ? Color.accentColor
                          : Color.primary.opacity(index < step ? 0.35 : 0.14))
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

// MARK: - Welcome

/// The mark and the one line it stands for, then the Screen Bar in
/// miniature: what the band at the top of the screen is saying, so the
/// first thing that lights up after setup already reads.
struct SetupWelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .accessibilityHidden(true)
                Text("Your agents, your menu bar, your notch — one app.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SetupScreenBarPrimer()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}

/// The Screen Bar's vocabulary: the band itself, playing a breathe in a
/// provider's colour and then the ask's amber beat, and one row per
/// thing its colour and motion mean. The words and the marks are the
/// retired first-run card's; the menu-bar icon's line is on the Done step.
struct SetupScreenBarPrimer: View {
    /// A slow breathe in Codex's accent (`#2B8FFF`) handing off to the
    /// ask's hard amber beat (`#FF3A00`, `ASK_AMBER`), then quiet —
    /// through the same safety-compiled renderer the band itself uses.
    /// Finite: `LEDStripPreview` loops it with a rest, which is the
    /// beat's "then quiet" for free.
    static let demoProgram = """
        #020204
        #2B8FFF 2200ms pulse
        #FF3A00 540ms pulse
        #020204 1400ms none
        """

    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("The Screen Bar")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                LEDStripPreview(program: Self.demoProgram, style: .band, dotSize: 5, showsBackground: false)
                    .frame(width: 120)
                    .accessibilityLabel("Screen Bar preview: a breathe, then an amber beat")
            }
            Text("The thin band at the top edge of the screen is your agents' status — the colour is who, the motion is what they're doing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            fact {
                HStack(spacing: 5) {
                    ProviderTile(style: ProviderStyle.style(for: "claude"), size: 16)
                    ProviderTile(style: ProviderStyle.style(for: "codex"), size: 16)
                    ProviderTile(style: ProviderStyle.style(for: "gemini"), size: 16)
                }
            } text: {
                Text("Colour names the provider — every agent keeps its own.")
            }
            fact {
                ActivityMark(activity: .waiting, accent: .orange, reduced: reduced)
            } text: {
                Text("A hard amber beat — one swell, then quiet — means it's waiting on you.")
            }
            fact {
                HStack(spacing: 8) {
                    ActivityMark(activity: .failed, accent: .red, reduced: reduced)
                    ActivityMark(activity: .working, accent: ProviderStyle.style(for: "codex").accent, reduced: reduced)
                    ActivityMark(activity: .done, accent: .green, reduced: reduced)
                }
            } text: {
                Text("Red means it broke — everything else is working or done.")
            }
            fact {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } text: {
                Text("Hover the band to see who's asking — click it to jump to that session.")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// One row: the marks in a fixed-width column, the sentence beside them.
    private func fact<Marks: View>(@ViewBuilder marks: () -> Marks, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .center, spacing: 12) {
            marks()
                .frame(width: 60, alignment: .leading)
                .accessibilityHidden(true)
            text()
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Agents

/// Detected providers with a per-row Install — the Agents page's rows
/// read down to detection, status and the reply's own note.
struct SetupAgentsStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.monitorLive {
                Label("The monitor is not connected yet — hooks can install from Settings › Agents once it is.",
                      systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            if store.agentRows.isEmpty {
                Text("No providers to show.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.agentRows) { agent in
                            SetupAgentRow(store: store, agent: agent)
                            if agent.id != store.agentRows.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

struct SetupAgentRow: View {
    @Bindable var store: SetupStore
    let agent: SetupAgent

    private var statusColor: Color {
        switch agent.hookStatus {
        case "ok": return .green
        case "stale": return .orange
        case "missing": return Color(nsColor: .tertiaryLabelColor)
        default: return Color(nsColor: .quaternaryLabelColor)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: agent.id), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(agent.statusWord(monitorLive: store.monitorLive))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if agent.detected == false {
                        Text("· CLI not found")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                // The reply's own words, where the click happened.
                if let note = store.hookNotes[agent.id] {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer()
            Button { store.installHooks(for: agent.id) } label: {
                if store.hookBusy.contains(agent.id) {
                    ProgressView().controlSize(.mini).frame(width: 58)
                } else {
                    Text(agent.hookStatus == "ok" ? "Reinstall" : "Install").frame(width: 58)
                }
            }
            .controlSize(.small)
            .disabled(!store.canInstall(agent))
            .help(agent.detected == false ? "No \(agent.name) CLI found on this Mac" : "Install \(agent.name)'s hooks")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Permissions

/// One row per permission — icon, what it enables, a live status dot,
/// and the Grant/Open Settings button. The dots keep polling while the
/// step is on screen, so a grant made in System Settings lands on its
/// own. Scrolls: the row count outgrew the window's fixed height.
struct SetupPermissionsStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(SetupPermission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider().opacity(0.5) }
                    SetupPermissionRow(store: store, permission: permission)
                }
            }
            .padding(.horizontal, 24)
        }
        .onAppear { store.startPermissionUpdates() }
        .onDisappear { store.stopPermissionUpdates() }
    }
}

struct SetupPermissionRow: View {
    @Bindable var store: SetupStore
    let permission: SetupPermission

    private var status: SetupPermissionStatus { store.status(of: permission) }

    private var dotColor: Color {
        switch status {
        case .granted: return .green
        case .needed, .denied: return .orange
        case .unavailable, .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(status.word)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(permission.enables)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = permission.action(for: status) {
                Button(action.title) { store.act(on: permission) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Menu bar & Screen Bar

/// The menu-bar icon picker and the band's own toggle. The style rows
/// are `MenuBarStyleRow` itself — the same component Settings › General
/// draws — fed `SetupIconPreview` in place of the Settings store's copy.
struct SetupAppearanceStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingLabel(title: "Menu bar icon",
                             subtitle: "What the status item shows at a glance.")
                VStack(spacing: 0) {
                    ForEach(Array(StatusIconStyle.allCases.enumerated()), id: \.element) { index, style in
                        if index > 0 { Divider().opacity(0.5) }
                        MenuBarStyleRow(style: style,
                                        selected: store.currentIconStyle == style,
                                        meters: store.iconPreview.meters,
                                        overflow: store.iconPreview.overflow,
                                        sessions: store.iconPreview.sessions,
                                        label: store.iconPreview.label) {
                            store.menuBarIconStyle = style.rawValue
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

                Toggle(isOn: $store.screenBarShown) {
                    SettingLabel(title: "Show the Screen Bar",
                                 subtitle: "The light strip along the top edge of the screen — toggle it and watch.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Done

/// What's set and what still needs the user; the buttons live in the
/// footer's usual place (Open Toys beside Finish).
struct SetupDoneStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.summaryRows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(row.ok ? Color.green : Color.secondary)
                        .frame(width: 22, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.text)
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("The menu-bar icon opens the panel; asks land there with Approve and Deny.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
    }
}
