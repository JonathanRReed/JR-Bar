import AppKit
import JRBarUI
import JRBarCore
import SwiftUI

/// The walkthrough's content: a five-step pager — Welcome, Agents,
/// Permissions, Menu bar & Screen Bar, Done — with the step's own header,
/// a progress read-out, and Back / Skip / the primary button.
struct SetupView: View {
    @Bindable var store: SetupStore

    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                ForEach(SetupStore.Step.allCases) { step in
                    HStack(spacing: JRBarTokens.Space.sm) {
                        ZStack {
                            Circle().fill(step == store.step ? JRBarTokens.Ink.accent : JRBarTokens.Ink.fill)
                                .frame(width: 24, height: 24)
                            if store.completedSteps.contains(step) {
                                Image(systemName: "checkmark").foregroundStyle(JRBarTokens.Ink.done)
                            } else {
                                Text("\(step.index + 1)").foregroundStyle(step == store.step ? Color.white : JRBarTokens.Ink.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.navigationTitle).font(JRBarTokens.TypeStyle.headline.font)
                            if step.optional { Text("Optional").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityLabel("\(step.navigationTitle), \(store.completedSteps.contains(step) ? "done" : step == store.step ? "current" : step.optional ? "optional" : "upcoming")")
                }
                Spacer()
            }
            .padding(JRBarTokens.Space.lg).frame(width: 176)
            .background(JRBarTokens.Ink.fill)
            Divider()
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.step.title)
                    .font(JRBarTokens.TypeStyle.title1.font)
                if !store.step.subtitle.isEmpty {
                    Text(store.step.subtitle)
                        .font(JRBarTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Group {
                switch store.step {
                case .welcome: SetupWelcomeStep()
                case .agents: SetupAgentsStep(store: store)
                case .asks: SetupAsksStep(store: store)
                case .permissions: SetupPermissionsStep(store: store)
                case .appearance: SetupAppearanceStep(store: store)
                case .done: SetupDoneStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(store.step)
            .transition(.opacity)
            .animation(PanelMotion.crossfade(reduced: reduced), value: store.step)

            if let failure = store.persistenceFailure {
                Label {
                    Text(failure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Tone.failure.color)
                }
                    .jrbarType(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                    .accessibilityElement(children: .combine)
            }
            footer
            }
        }
        .frame(width: SetupWindowController.contentSize.width,
               height: SetupWindowController.contentSize.height)
    }

    /// Progress pips, Back, Skip and the primary button — Get Started,
    /// Next, or Finish on the last step (beside Open Toys).
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            if store.canGoBack {
                Button("Back") { store.goBack() }.keyboardShortcut("[", modifiers: .command)
            }
            if store.canSkip {
                Button("Skip") { store.skip() }
            }
            if store.step == .done {
                Button("Open toys") { store.finishToToys() }
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

    /// The walkthrough's marks — the current pip, the mark's tile — in
    /// the calm blue What's New and the unseen dot wear, not the accent:
    /// on a Mac whose accent is red, a red first step read as an error.
    static let tint = JRBarTokens.Ink.accent

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == step ? Self.tint
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
                    .foregroundStyle(SetupProgress.tint)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [SetupProgress.tint.opacity(0.22), SetupProgress.tint.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SetupProgress.tint.opacity(0.18), lineWidth: 0.5)
                    )
                    .accessibilityHidden(true)
                Text("See which agents are working and which need you.")
                    .font(JRBarTokens.TypeStyle.title3.font)
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
                    .font(.system(size: JRBarTokens.TypeStyle.body.size, weight: .semibold))
                Spacer()
                LEDStripPreview(program: Self.demoProgram, style: .band, dotSize: 5, showsBackground: false)
                    .frame(width: 120)
                    .accessibilityLabel("Screen Bar preview: a breathe, then an amber beat")
            }
            Text("The thin band at the top edge of the screen is your agents' status — the colour is who, the motion is what they're doing.")
                .jrbarType(.callout)
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
                ActivityMark(activity: .waiting, accent: Tone.ask.color, reduced: reduced)
            } text: {
                Text("A hard amber beat — one swell, then quiet — means it's waiting on you.")
            }
            fact {
                HStack(spacing: 8) {
                    ActivityMark(activity: .failed, accent: Tone.failure.color, reduced: reduced)
                    ActivityMark(activity: .working, accent: ProviderStyle.style(for: "codex").accent, reduced: reduced)
                    ActivityMark(activity: .done, accent: Tone.done.color, reduced: reduced)
                }
            } text: {
                Text("Red means it broke — everything else is working or done.")
            }
            fact {
                Image(systemName: "cursorarrow.rays")
                    .font(JRBarTokens.TypeStyle.title3.font)
                    .foregroundStyle(.secondary)
            } text: {
                Text("Hover the band to see who's asking — click it to jump to that session.")
            }
        }
        .windowWell(padding: 14)
    }

    /// One row: the marks in a fixed-width column, the sentence beside them.
    private func fact<Marks: View>(@ViewBuilder marks: () -> Marks, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .center, spacing: 12) {
            marks()
                .frame(width: 60, alignment: .leading)
                .accessibilityHidden(true)
            text()
                .jrbarType(.callout)
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
                Label("Waiting for the monitor. Once it connects, you can install hooks and choose which providers show usage.",
                      systemImage: "bolt.horizontal.circle")
                    .jrbarType(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            if store.monitorLive, store.loadingUsageOffers {
                Text("Reading usage choices…")
                    .jrbarType(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            if store.monitorLive, let failure = store.usageOffersFailure {
                HStack(alignment: .top, spacing: 10) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .jrbarType(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { _ = Task { await store.refreshUsageOffers() } }
                        .controlSize(.small)
                        .disabled(store.loadingUsageOffers)
                }
                .padding(.bottom, 10)
            }
            Text("Other providers are available in Settings › Providers.")
                .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            if store.installedAgentRows.isEmpty {
                Text("No providers found on this Mac.")
                    .jrbarType(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                SnapshotScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.installedAgentRows) { agent in
                            SetupAgentRow(store: store, agent: agent)
                            if agent.id != store.installedAgentRows.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .onChange(of: store.usageOfferRefreshKey) { _, key in
            if key != nil { _ = Task { await store.refreshUsageOffers() } }
        }
    }
}

struct SetupAgentRow: View {
    @Bindable var store: SetupStore
    let agent: SetupAgent

    private var statusColor: Color {
        store.monitorLive ? HookStatus(agent.hookStatus).tone.color : Tone.neutral.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            hookRow
            if let offer = store.usageOffer(for: agent.id) {
                SetupUsageOfferView(store: store, offer: offer)
            }
        }
        .padding(.vertical, 6)
    }

    private var hookRow: some View {
        HStack(spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: agent.id), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(agent.statusWord(monitorLive: store.monitorLive))
                        .jrbarType(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if agent.detected == false {
                        Text("· CLI not found")
                            .jrbarType(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                // The reply's own words, where the click happened.
                if let note = store.hookNotes[agent.id] {
                    Text(note.text)
                        .jrbarType(.caption)
                        .foregroundStyle(note.isError ? Tone.failure.color : Color.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer()
            Button { store.installHooks(for: agent.id) } label: {
                if store.hookBusy.contains(agent.id) {
                    DelayedWait(size: 12) { Text(agent.hookStatus == "ok" ? "Reinstall" : "Install") }
                        .frame(width: 58)
                } else {
                    Text(agent.hookStatus == "ok" ? "Reinstall" : "Install").frame(width: 58)
                }
            }
            .controlSize(.small)
            .disabled(!store.canInstall(agent))
            .help(agent.detected == false ? "No \(agent.name) CLI found on this Mac" : "Install \(agent.name)'s hooks")
        }
    }
}

/// "Show Claude usage?" with the daemon's sentence about exactly what is
/// asked, of whom, with whose sign-in — and one answer per provider, never
/// an all-or-nothing. "Not now" asks nothing and sends nothing.
struct SetupUsageOfferView: View {
    @Bindable var store: SetupStore
    let offer: SetupUsageOffer

    private var busy: Bool { store.usageBusy.contains(offer.id) }
    private var declined: Bool { store.usageChoices[offer.id] == .notNow }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(offer.question)
                .jrbarType(.callout).fontWeight(.medium)
            Text(offer.summary)
                .jrbarType(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if offer.isOn {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .jrbarType(.caption).fontWeight(.semibold)
                        .foregroundStyle(Tone.done.color)
                    Button("Turn off") { store.turnOffUsage(for: offer.id) }
                        .buttonStyle(.link)
                        .jrbarType(.caption)
                        .disabled(busy || !store.monitorLive)
                        .accessibilityLabel("Turn off \(offer.name) usage")
                } else {
                    Button("Turn on") { store.turnOnUsage(for: offer.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(busy || !store.monitorLive)
                        .accessibilityLabel("Turn on \(offer.name) usage")
                    Button("Not now") { store.declineUsage(for: offer.id) }
                        .controlSize(.small)
                        .disabled(busy)
                    if declined {
                        Text("Off. Settings › Providers turns it on any time.")
                            .jrbarType(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if busy { DelayedWait(size: 12) }
            }
            if let note = store.usageNotes[offer.id] {
                Text(note.text)
                    .jrbarType(.caption)
                    .foregroundStyle(note.isError ? Tone.failure.color : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 34)
        .accessibilityElement(children: .contain)
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
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Used by features that are on")
                        .font(.system(size: JRBarTokens.TypeStyle.body.size, weight: .semibold))
                        .padding(.vertical, 12)
                    if store.activePermissions.isEmpty {
                        Text("The panel works without these grants. Enable optional features when you need them.")
                            .jrbarType(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(store.activePermissions.enumerated()), id: \.element) { index, permission in
                        if index > 0 { Divider().opacity(0.5) }
                        SetupPermissionRow(store: store, permission: permission)
                    }
                }
                DisclosureGroup("Other permissions") {
                    VStack(spacing: 0) {
                        ForEach(Array(store.optionalPermissions.enumerated()), id: \.element) { index, permission in
                            if index > 0 { Divider().opacity(0.5) }
                            SetupPermissionRow(store: store, permission: permission)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .onAppear { _ = store.startPermissionUpdates() }
        .onDisappear { store.stopPermissionUpdates() }
    }
}

struct SetupPermissionRow: View {
    @Bindable var store: SetupStore
    let permission: SetupPermission

    private var status: SetupPermissionStatus { store.status(of: permission) }

    private var dotColor: Color {
        switch status {
        case .granted: return Tone.done.color
        case .needed, .denied: return Tone.neutral.color
        case .unavailable, .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(JRBarTokens.TypeStyle.title3.font)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(status.word)
                        .jrbarType(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(permission.enables)
                    .jrbarType(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = permission.action(for: status) {
                Button(store.permissionBusy.contains(permission) ? "Waiting…" : action.title) {
                    store.act(on: permission)
                }
                    .controlSize(.small)
                    .disabled(store.permissionBusy.contains(permission))
                    .accessibilityLabel("\(action.title) \(permission.title)")
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Menu bar & Screen Bar

/// Optional light setup, with the Screen Bar switch and a route to Studio.
struct SetupAppearanceStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            SettingsGroup {
                SettingsRow("Screen Bar") {
                    Toggle("Screen Bar", isOn: $store.screenBarShown).labelsHidden().toggleStyle(.switch)
                }
                SettingsNavigationRow("Studio") {
                    _ = Task { await AppCommandRouter.shared.perform(.window(.effects)) }
                }
            }
            if store.monitorLive {
                let devices = store.model.connectedLights()
                Text(devices.isEmpty ? "No light devices connected" : devices.joined(separator: ", "))
                    .font(JRBarTokens.TypeStyle.body.font).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, JRBarTokens.Space.xxl)
    }
}

// MARK: - Done

/// What's set and what still needs the user, as a list in a well: a
/// tile per row, green where it is done, and the word for what is left;
/// the buttons live in the footer's usual place (Open Toys beside
/// Finish).
struct SetupDoneStep: View {
    @Bindable var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                ForEach(Array(store.summaryRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 54) }
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.system(size: JRBarTokens.TypeStyle.body.size, weight: .medium))
                            .foregroundStyle(row.ok ? Tone.done.color : Tone.neutral.color)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((row.ok ? Tone.done.color : Tone.neutral.color).opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.text).font(.system(size: JRBarTokens.TypeStyle.body.size, weight: .medium))
                            Text(row.detail)
                                .jrbarType(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: row.ok ? "checkmark.circle.fill" : "circle.dashed")
                            .font(JRBarTokens.TypeStyle.title3.font)
                            .foregroundStyle(row.ok ? Tone.done.color : Color.secondary)
                            .accessibilityLabel(row.ok ? "Done" : "Still to do")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .windowWell(padding: 0)
            SetupTryItRow(store: store)
            Spacer(minLength: 0)
            Label("The menu-bar icon opens the panel; asks land there with Approve and Deny.",
                  systemImage: "menubar.arrow.up.rectangle")
                .jrbarType(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

/// "Try it" on the Done step: a made-up ask on the real surfaces, so the
/// first real one is not the first time Approve and Deny are seen.
struct SetupTryItRow: View {
    @Bindable var store: SetupStore

    var body: some View {
        DemoAskTryRow { store.tryDemoAsk() }
            .windowWell(padding: 12)
    }
}

struct SetupAsksStep: View {
    @Bindable var store: SetupStore
    @ViewState private var preview = Self.makePreview()

    static func makePreview() -> NotchCardModel {
        let previewID = "jrbar-setup-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: previewID)!
        let power = AlcovePowerState(hasBattery: true, onAC: true, charging: false, percent: 100, fullyCharged: true)
        let utility = ShelfUtilityModel(power: power)
        let model = NotchCardModel(timers: ShelfTimerModel.scratch(),
            tray: ShelfTrayModel(defaults: defaults), utility: utility, runtimeEnabled: false)
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "Sample project",
            word: "Needs you", clickSession: nil, explanation: nil)
        model.rows = [NotchIslandRow(id: DemoAsk.sessionID, label: "Sample project", provider: "claude", activity: .waiting,
            ask: CoreAsk(session: DemoAsk.sessionID, summary: "Run the tests?", answerable: false))]
        return model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            NotchCardView(model: preview, style: .island, width: 420, pinnedLayout: true, stillTurn: 1, stillReduced: true)
                .background(.black, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
                .allowsHitTesting(false)
            Text("No hook, link or rule answers for you.")
                .jrbarType(.body)
            Button("Try an ask") { store.onTryDemoAsk() }
            Spacer()
        }.padding(.horizontal, JRBarTokens.Space.xxl)
    }
}
