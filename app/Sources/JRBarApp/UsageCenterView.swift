import AppKit
import Charts
import JRBarCore
import JRBarUI
import SwiftUI

/// Provider selection survives closing the window; facts stay in the daemon.
struct UsageCenterView: View {
    @Bindable var store: UsageCenterStore
    @AppStorage("usageCenter.provider") private var selection = "overview"
    @AppStorage("usageCenter.showCost") private var showCost = true

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { visibleSelection }, set: { selection = $0 })) {
                Label {
                    Text("Overview")
                        .foregroundStyle(visibleSelection == "overview" ? JRBarTokens.Ink.onAccent : JRBarTokens.Ink.label)
                } icon: { Image(systemName: "tablecells") }
                    .jrbarSidebarSelection(visibleSelection == "overview")
                    .listRowBackground(Color.clear)
                    .tag("overview")
                Section("Providers") {
                    ForEach(store.providers, id: \.identity) { provider in
                        HStack(spacing: JRBarTokens.Space.sm) {
                            ProviderLogoTile(provider: provider.id)
                            Text(store.providerTitle(provider))
                                .foregroundStyle(visibleSelection == provider.identity ? JRBarTokens.Ink.onAccent : JRBarTokens.Ink.label)
                        }
                        .jrbarSidebarSelection(visibleSelection == provider.identity)
                        .listRowBackground(Color.clear)
                        .tag(provider.identity)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            SnapshotScrollView {
                VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
                    if store.providers.isEmpty {
                        WindowEmptyState(symbol: store.isLive ? "chart.xyaxis.line" : "bolt.horizontal.circle",
                            title: store.isLive ? "No usage yet" : MonitorWords.label,
                            text: store.isLive ? "Installed providers appear when the monitor reports them." : "Your usage will appear when JR-Bar reconnects.",
                            actionTitle: "Open Providers", action: store.openUsageSettings)
                    } else {
                        if !store.isLive { StatusBanner(MonitorWords.label, detail: "Showing the last readings.") }
                        if store.resetSaveFailure != nil { ResetSaveNotice { store.loadResetStatus(retry: true) } }
                        if visibleSelection == "overview" {
                            UsageOverviewTable(store: store, showCost: showCost) { selection = $0 }
                        } else if let provider = store.providers.first(where: { $0.identity == visibleSelection }) {
                            UsageProviderDetail(provider: provider, store: store, showCost: showCost)
                        }
                    }
                }
                .padding(JRBarTokens.Space.xxl)
            }
            .id(visibleSelection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .frame(minWidth: 800, minHeight: 480)
        .toolbar {
            if visibleSelection != "overview" {
                ToolbarItem(placement: .principal) {
                    Picker("Range", selection: $store.range) {
                        ForEach(UsageHistoryRange.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(!store.isLive)
                }
            }
            ToolbarItem {
                Toggle("Estimated cost", isOn: $showCost)
            }
            if visibleSelection != "overview" {
                ToolbarItem {
                    Picker("Chart", selection: Binding(get: { showCost ? store.metric : .tokens }, set: { store.metric = $0 })) {
                        ForEach(UsageCenterStore.Metric.allCases.filter { showCost || $0 == .tokens }) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    if store.refreshing { DelayedWait { Label("Refresh", systemImage: "arrow.clockwise") } }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(!store.isLive || store.refreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .background(UsageCenterShortcutReader { $0.handle(on: store) })
        .safeAreaInset(edge: .bottom) {
            if let notice = store.notice {
                UsageCenterNoticeView(notice: notice, copy: store.copyNotice, dismiss: store.dismissNotice)
                    .padding(JRBarTokens.Space.md)
            }
        }
        .onAppear { consumeFocus() }
        .onChange(of: store.focusPulses) { consumeFocus() }
        .onChange(of: store.providers.map(\.identity)) { consumeFocus() }
    }

    private var visibleSelection: String {
        guard selection != "overview" else { return selection }
        let identity = UsageCenterStore.identity(for: selection, in: store.providers)
        return store.providers.contains(where: { $0.identity == identity }) ? identity : "overview"
    }

    private func consumeFocus() {
        guard let target = store.focusProvider else { return }
        let identity = UsageCenterStore.identity(for: target, in: store.providers)
        guard store.providers.contains(where: { $0.identity == identity }) else { return }
        selection = identity
        store.focusProvider = nil
    }
}

struct UsageCenterNoticeView: View {
    let notice: UsageCenterStore.Notice
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        StatusBanner(notice.text, kind: notice.isFailure ? .failure : .information) {
            HStack {
                Button("Copy", action: copy).help("Copy this message")
                Button("Dismiss", action: dismiss).help("Dismiss this message")
            }
        }.textSelection(.enabled)
    }
}

// MARK: - Connection

struct UsageProviderConnection: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore
    let row: ProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let consent = row.usageConsent {
                UsageConsentSwitch(row: row, consent: consent, store: store)
            }
            if ["factory", "devin", "kimi", "kilo"].contains(row.id) {
                ProviderCredentialControls(row: row, core: store.core,
                                           connectRequest: store.browserConnectRequests[provider.identity] ?? 0,
                                           onConnectPresented: { store.didPresentBrowserConnection(provider.identity) }) {
                    _ = store.loadProviderRows()
                }
                    .id(row.identity)
            }
            HStack(spacing: 10) {
                Toggle(
                    "Metering",
                    isOn: Binding(
                        get: { row.enabled },
                        set: { store.setProviderEnabled(row, $0) }
                    )
                )
                .controlSize(.small)
                .toggleStyle(.checkbox)
                .help("Enable or disable this provider's quota collection")
                ProviderFixControls(provider: provider, store: store)
                Spacer()
                if row.supportsInstances {
                    AddAccountButton(providerID: provider.id, row: row, store: store)
                }
                if row.importedCredential {
                    Text("imported session")
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(.tertiary)
                        .help("This credential came from a consented browser import; revoking the consent removes it while it is still the imported value.")
                }
            }
            if let note = store.signInNotes[provider.identity] {
                SignInNoteLine(note: note)
            }
            if !row.consents.isEmpty && row.id != "factory" {
                ForEach(Array(row.consents.enumerated()), id: \.offset) { _, consent in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                        Text("\(consent.browser) · \(consent.profile)")
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                        Text(consent.fields.joined(separator: ", "))
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Revoke") { store.revokeConsent(providerID: provider.id, consent: consent) }
                            .controlSize(.mini)
                            .help("Stop every future read of \(consent.browser) \(consent.profile); imported data is removed only while it is still the imported value")
                    }
                }
            }
        }
    }
}

enum UsageCardCopy {
    nonisolated static func readingAgeText(_ provider: CoreProviderUsage, now: Date) -> String? {
        guard let readingAt = provider.readingAt else { return nil }
        let seconds = now.timeIntervalSince1970 - readingAt
        return "Read \(UsageTime.ago(seconds >= 60 ? floor(seconds / 60) * 60 : seconds))"
    }

    static func pricingDisclosure(_ history: UsageHistory) -> String {
        guard let pricing = history.pricing else { return "Approximate: the monitor reported no price table for this provider." }
        var text: String
        if pricing.estimated {
            text = "Approximate: list prices"
            if let input = pricing.inputPerMillion, let output = pricing.outputPerMillion {
                text += " (\(UsageFormat.price(perMillion: input, currency: pricing.currency)) in / \(UsageFormat.price(perMillion: output, currency: pricing.currency)) out per M tokens"
                if let cache = pricing.cacheReadPerMillion { text += ", \(UsageFormat.price(perMillion: cache, currency: pricing.currency)) cache" }
                text += ")"
            }
            if let model = pricing.model { text += " for \(model)" }
            if let asOf = pricing.asOf { text += ", as of \(asOf)" }
            text += "."
            text += " This model has no table row — priced at the provider's reference rate."
        } else {
            text = "List price"
            if let model = pricing.model { text += " for \(model)" }
            if let input = pricing.inputPerMillion, let output = pricing.outputPerMillion {
                text += ": \(UsageFormat.price(perMillion: input, currency: pricing.currency)) in / \(UsageFormat.price(perMillion: output, currency: pricing.currency)) out"
                if let cache = pricing.cacheReadPerMillion { text += " / \(UsageFormat.price(perMillion: cache, currency: pricing.currency)) cache" }
                text += " per M tokens"
            }
            if let asOf = pricing.asOf { text += ", as of \(asOf)" }
            text += "."
        }
        if history.unpricedRecords > 0 {
            let models = history.unpricedModels.isEmpty ? "" : " (\(history.unpricedModels.joined(separator: ", ")))"
            text += " \(history.unpricedRecords) record\(history.unpricedRecords == 1 ? "" : "s")\(models) ha\(history.unpricedRecords == 1 ? "s" : "ve") no price — their tokens are counted but add no dollars."
        }
        return text + " Subscription plans are not billed per token."
    }
    static func verdictTint(_ forecast: UsageForecast) -> Color {
        forecast.status.tone.color
    }
}


// MARK: - Combined view

/// The per-provider "Re-sign in" / "Update provider" button (T3 Code's
/// pattern): asks the daemon to re-pull whatever sign-in the provider's
/// own tooling holds and forces a refresh. The daemon's reply — shown in
/// the window's banner — says what actually happened, including the
/// provider's own remedy when only its CLI or a page can sign in.
struct ResignInButton: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore

    var body: some View {
        Button {
            store.resignIn(provider)
        } label: {
            if store.isResigningIn(provider) {
                DelayedWait { Label("Re-sign in", systemImage: "arrow.clockwise") }
            } else {
                Label("Re-sign in", systemImage: "arrow.clockwise")
            }
        }
        .controlSize(.small)
        .disabled(store.isResigningIn(provider) || !store.isLive)
        .help(Self.help(for: provider.id))
    }

    /// What the click actually does for this provider — honest about who
    /// owns the sign-in, so a CLI-owned one never pretends JR-Bar can
    /// re-auth it.
    static func help(for providerID: String) -> String {
        switch providerID {
        case "claude":
            return "Re-read Claude Code's sign-in from the Keychain, then refresh"
        case "codex":
            return "Rescan the Codex CLI's sign-in and sessions, then refresh"
        case "grok":
            return "Re-read the grok CLI's sign-in, then refresh"
        case "devin":
            return "Re-import the consented browser session, then refresh"
        case "openai-api":
            return "Store a copied OpenAI Admin key (read only when you click), then refresh"
        case "gemini", "antigravity", "opencode", "cursor":
            return "Re-check and refresh — the sign-in itself belongs to this provider's own app or CLI"
        default:
            return "Re-check this provider's sign-in and refresh its usage"
        }
    }
}

/// The manage row's fix controls. A card whose problem is a sign-in leads
/// with the one **Fix sign-in** button, and the daemon's own fix-it
/// ("Reconnect Claude", "Run grok login") stays beside it as the explanation,
/// not as the action. Any other card keeps the daemon's staged action and the
/// plain re-read.
struct ProviderFixControls: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore

    var body: some View {
        if provider.actionKind == "manage" {
            // The browser, credential and consent controls are directly above this row.
            EmptyView()
        } else if provider.usageIsOff {
            // Nothing to fix: the card's own "Turn on" is the one button.
            EmptyView()
        } else if provider.offersSignInFix || provider.actionKind == "sign_in" {
            FixSignInButton(provider: provider, store: store)
            if let action = provider.action, !action.isEmpty {
                Text(action)
                    .jrbarType(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(provider.reason?.replacingOccurrences(of: "_", with: " ") ?? action)
            }
        } else if ["factory", "kimi", "kilo"].contains(provider.id) {
            if provider.state != "disabled" {
                Button("Refresh usage") { store.runProviderAction(provider) }
                    .controlSize(.small)
            }
        } else {
            if let action = provider.action, !action.isEmpty {
                Button(action) { store.runProviderAction(provider) }
                    .controlSize(.small)
                    .help(provider.reason?.replacingOccurrences(of: "_", with: " ") ?? action)
            }
            ResignInButton(provider: provider, store: store)
        }
    }
}

/// The per-provider usage switch on a card's manage row, with the one line
/// that says what the request is, to which host and with which sign-in.
struct UsageConsentSwitch: View {
    let row: ProviderRow
    let consent: ProviderUsageConsent
    @Bindable var store: UsageCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                "Show usage",
                isOn: Binding(
                    get: { consent.granted },
                    set: { store.setUsageConsent(row, $0) }
                )
            )
            .controlSize(.small)
            .toggleStyle(.checkbox)
            .help(consent.detail)
            Text(consent.detail)
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Fix sign-in": the one button for a card whose problem is a sign-in. It
/// asks the daemon to do the best automatic thing for this provider and shows
/// the sentence the daemon answers with. Nothing runs until it is clicked.
struct FixSignInButton: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore

    private var name: String { ProviderStyle.style(for: provider.id).name }

    var body: some View {
        Button {
            store.fixSignIn(provider)
        } label: {
            if store.isFixingSignIn(provider) {
                DelayedWait { Label("Fix sign-in", systemImage: "wrench.and.screwdriver") }
            } else {
                Label("Fix sign-in", systemImage: "wrench.and.screwdriver")
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(store.isFixingSignIn(provider) || !store.isLive)
        .help(Self.help(for: provider.id))
        .accessibilityLabel(store.isFixingSignIn(provider) ? "Fixing \(name) sign-in" : "Fix \(name) sign-in")
        .accessibilityHint(Self.help(for: provider.id))
    }

    /// What the click does for this provider, in the words the daemon's
    /// own table backs: nothing here promises more than that.
    static func help(for providerID: String) -> String {
        switch providerID {
        case "claude":
            return "Asks Claude Code to renew its own sign-in, or opens your terminal on `claude auth login`"
        case "grok":
            return "Opens your terminal on `grok login`; JR-Bar notices when you finish"
        case "codex":
            return "Opens your terminal on `codex login` when the card says signed out"
        case "opencode":
            return "Opens your terminal on `opencode providers login` when the card says signed out"
        case "devin":
            return "Clears the rejected session, imports your browser session again, or opens the token page"
        case "cursor":
            return "Clears the rejected token and opens Cursor's settings page"
        default:
            return "Re-checks this provider's sign-in and says what to do next"
        }
    }
}

/// What the last Fix sign-in click said, under the card it was clicked on.
struct SignInNoteLine: View {
    let note: UsageCenterStore.SignInNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(note.tone))
                .jrbarType(.caption)
                .foregroundStyle(Self.tint(note.tone))
                .accessibilityHidden(true)
            Text(note.text)
                .jrbarType(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ tone: UsageCenterStore.SignInNote.Tone) -> String {
        switch tone {
        case .done: return "checkmark.circle"
        case .todo: return "arrow.up.forward.app"
        case .info: return "info.circle"
        }
    }

    static func tint(_ tone: UsageCenterStore.SignInNote.Tone) -> Color {
        switch tone {
        case .done: return Tone.done.color
        case .todo: return Tone.neutral.color
        case .info: return .secondary
        }
    }
}

/// The "Add account" affordance — only offered where the daemon says a
/// second configured instance could read a *different* account (a stored
/// credential or a consented browser session). A popover keeps it light:
/// an instance slug plus an optional display label.
struct AddAccountButton: View {
    let providerID: String
    let row: ProviderRow
    @Bindable var store: UsageCenterStore
    // `ViewState`, not `@State` — the Command Line Tools ship no
    // SwiftUIMacros plugin; the alias names the wrapper directly.
    @ViewState private var open = false
    @ViewState private var instance = ""
    @ViewState private var label = ""

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Label("Add account", systemImage: "plus")
        }
        .controlSize(.small)
        .disabled(!store.isLive)
        .help("Meter a second \(providerID) account — its credential or browser consent is what keeps it from mirroring this one")
        .popover(isPresented: WindowPresenter.presentation($open), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a \(providerID) account")
                    .jrbarType(.headline)
                Text("The instance id distinguishes the account — \"work\", \"personal\". The account's own credential or consented browser session is set up next, from its card's manage row.")
                    .jrbarType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260)
                TextField("Instance id (e.g. work)", text: $instance)
                    .textFieldStyle(.roundedBorder)
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { open = false }
                        .controlSize(.small)
                    Button("Add") {
                        let slug = Self.slug(instance)
                        guard !slug.isEmpty else { return }
                        store.addProviderInstance(row, instance: slug,
                                                  label: label.isEmpty ? nil : label)
                        open = false
                        instance = ""
                        label = ""
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Self.slug(instance).isEmpty)
                }
            }
            .padding(14)
        }
    }

    /// The instance id as the daemon expects it — lowercase slug.
    static func slug(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}




struct ResetSaveNotice: View {
    let retry: () -> Void

    var body: some View {
        StatusBanner("Reset feedback not saved", kind: .failure) {
            Button("Retry", action: retry)
        }
    }
}
