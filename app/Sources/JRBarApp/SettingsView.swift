import JRBarUI
import JRBarCore
import SwiftUI

/// The Settings window's content: a System Settings-style sidebar and a
/// grouped form per page. Every control reads the daemon's document through
/// `SettingsStore` and writes through `set_setting`.
struct SettingsRootView: View {
    @Bindable var store: SettingsStore
    @FocusState private var searchFocused: Bool
    /// A hold from whatever hosts the window's content, kept.
    @Environment(\.ledPreviewsHeld) private var heldAbove

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search settings", text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Search settings")
                    .padding(JRBarTokens.Space.md)
                SettingsSidebarList(store: store)
                Button { store.onOpenEffects?() } label: {
                    HStack(spacing: JRBarTokens.Space.sm) {
                        SidebarIcon(symbol: "paintpalette.fill", tint: JRBarTokens.Ink.accent)
                        Text("Studio")
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                    .padding(JRBarTokens.Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            // ⌘F lands in the search field from anywhere in the window.
            .background {
                Button("Search Settings") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
        } detail: {
            // No NavigationStack: no page pushes a destination, and the
            // stack measured the whole form once more on every pass.
            SettingsPageContainer(store: store, page: store.page)
        }
        .navigationSplitViewStyle(.balanced)
        .task { store.t3Integration.refresh(core: store.core) }
        .onChange(of: store.isLive) { _, live in
            if live { store.t3Integration.refresh(core: store.core) }
        }
        .frame(minWidth: 640, minHeight: 420)
        // A covered, minimised or far-Space window holds every preview.
        .environment(\.ledPreviewsHeld, heldAbove || store.windowCovered)
        .sheet(isPresented: WindowPresenter.presentation(Binding(get: { store.calibrating != nil }, set: { if !$0 { store.calibrating = nil } }))) {
            CalibrationSheet(store: store, deviceID: store.calibrating ?? "", dismiss: { store.calibrating = nil })
        }
        .sheet(isPresented: WindowPresenter.presentation(Binding(get: { store.firmware.sheetDeviceID != nil }, set: { if !$0 { store.firmware.closeSheet() } }))) {
            FirmwareSheet(store: store)
        }
        .sheet(isPresented: WindowPresenter.presentation(Binding(get: { store.doctorReport != nil }, set: { if !$0 { store.doctorReport = nil } }))) {
            DoctorSheet(report: store.doctorReport ?? .object([:]), dismiss: { store.doctorReport = nil })
        }
        .confirmationDialog(
            "Remove \(store.pendingIntegrationRemoval.map(ProviderPalette.displayName(for:)) ?? "") integration?",
            isPresented: WindowPresenter.presentation(Binding(
                get: { store.pendingIntegrationRemoval != nil },
                set: { if !$0 { store.cancelIntegrationRemoval() } })),
            titleVisibility: .visible
        ) {
            Button("Remove integration", role: .destructive) { store.confirmIntegrationRemoval() }
            Button("Cancel", role: .cancel) { store.cancelIntegrationRemoval() }
        } message: {
            Text("Removes JR-Bar's hooks from this provider's configuration. You can install them again from Providers.")
        }
        .confirmationDialog(
            "Reset \(store.resetTarget?.title ?? "") to defaults?",
            isPresented: WindowPresenter.presentation(Binding(get: { store.resetTarget != nil }, set: { if !$0 { store.resetTarget = nil } })),
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                if let page = store.resetTarget { store.resetPage(page) }
                store.resetTarget = nil
            }
            Button("Cancel", role: .cancel) { store.resetTarget = nil }
        } message: {
            Text(store.resetTarget.map(SettingsStore.resetMessage(for:)) ?? "")
        }
    }
}

struct SettingsSidebarList: View {
    @Bindable var store: SettingsStore

    var body: some View {
        List(selection: $store.page) {
            if store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsStore.Page.sidebarGroups.indices, id: \.self) { index in
                    if index > 0 {
                        Text(index == 1 ? "Hardware" : "More")
                            .jrbarType(.section)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, JRBarTokens.Space.sm)
                    }
                    ForEach(SettingsStore.Page.sidebarGroups[index]) { page in
                        sidebarRow(page)
                    }
                }
            } else { SettingsSearchResults(store: store) }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ page: SettingsStore.Page) -> some View {
        Label {
            Text(page.title)
                .foregroundStyle(store.page == page ? JRBarTokens.Ink.onAccent : JRBarTokens.Ink.label)
        } icon: {
            SidebarIcon(symbol: page.symbol, tint: page.tint)
        }
        .jrbarSidebarSelection(store.page == page)
        .listRowInsets(EdgeInsets())
        .tag(page)
    }
}

/// The sidebar while searching: the best-matching rows, each naming the
/// page and group it lives in. A click opens that page and names the
/// row at its top.
struct SettingsSearchResults: View {
    @Bindable var store: SettingsStore

    var body: some View {
        let results = store.searchHits
        if results.isEmpty {
            Text("No settings match.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(results) { entry in
                // A row inside a card wears that card's own tile.
                let toy = entry.card.flatMap(store.cardToy)
                Button {
                    store.reveal(entry)
                } label: {
                    HStack(spacing: 8) {
                        SidebarIcon(symbol: toy?.symbol ?? entry.chapter.symbol,
                                    tint: toy.map { ToyCard.tint(for: $0.id, page: entry.chapter.tint) } ?? entry.chapter.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .lineLimit(1)
                            Text(entry.chapter == .lighting ? "Studio" : (entry.group.isEmpty || entry.group == entry.title
                                 ? entry.page.title : "\(entry.page.title) › \(entry.group)"))
                                .jrbarType(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(entry.chapter == .lighting ? "Opens Studio" : "Opens \(entry.page.title)")
            }
        }
    }
}

/// System Settings tints each sidebar glyph inside a small rounded square.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        SettingsIconTile(symbol: symbol, tint: tint, size: SettingsMetrics.sidebarTile)
    }
}

extension SettingsStore {
    /// The toy or utility a search hit's card id names, so the hit can
    /// wear that card's tile.
    func cardToy(_ id: String) -> (any Toy)? {
        if id == "keepAwake" { return KeepAwakeUtility.shared }
        var cards: [any Toy] = []
        if let utilities {
            cards += [utilities.menuBar, utilities.dock, utilities.agents] as [any Toy]
        }
        if let toys {
            if let notch = toys.notch { cards.append(notch) }
            cards += toys.toys
        }
        return cards.first { $0.id == id }
    }
}

extension SettingsStore.Page {
    /// The sidebar's runs, System Settings-style: the app itself, then
    /// what it watches and does, then how you and other machines reach
    /// it. Every page sits in exactly one run.
    static let sidebarGroups: [[SettingsStore.Page]] = [
        [.general, .agents, .alerts, .shortcuts],
        [.devices, .notch],
        [.utilities, .remote, .privacy, .integrations, .advanced],
    ]
}

/// One page: the form, an offline banner when the daemon has not sent its
/// document, and a transient error line for refused writes.
struct SettingsPageContainer: View {
    @Bindable var store: SettingsStore
    let page: SettingsStore.Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The store rides the environment so a toy or utility card can
        // read its own disclosure and light from it; a search hit into a
        // card scrolls the page to that card.
        ScrollViewReader { proxy in
            form
                .task(id: store.revealRequest) { await scrollToHit(proxy) }
        }
        .environment(store)
        .id("\(page.rawValue)/\(store.subpage ?? "")/\(store.selectedProvider ?? "")")
    }

    /// Scroll to what a search hit or a link opened, once the new page has
    /// laid its rows out: its card (lit for a beat, unless a newer hit
    /// took it) or, for a row on a daemon page, the group it sits in; for
    /// a chapter, the place that chapter starts.
    private func scrollToHit(_ proxy: ScrollViewProxy) async {
        if let chapter = store.pendingChapter, chapter.page == page {
            store.pendingChapter = nil
            if let anchor = chapter.anchor {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : JRBarTokens.Motion.rowChange.animation(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            return
        }
        guard let hit = store.searchHit, hit.page == page else { return }
        let card = store.highlightedCard
        let target = card.map(SettingsStore.cardAnchor)
            ?? (hit.group.isEmpty ? hit.chapter.anchor : SettingsStore.groupAnchor(hit.group))
        guard let target else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : JRBarTokens.Motion.rowChange.animation(reduceMotion: reduceMotion)) {
            proxy.scrollTo(target, anchor: .top)
        }
        guard let card else { return }
        try? await Task.sleep(for: .seconds(2.4))
        guard !Task.isCancelled, store.highlightedCard == card else { return }
        store.highlightedCard = nil
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            Section {
                SettingsPageHeader(page: page)
            }
            if let seal = store.seal, seal.notice != nil || seal.resultLine != nil {
                Section {
                    SettingsSealBanner(seal: seal)
                }
            }
            SettingsPageNotice(store: store, page: page)
            if let provider = store.selectedProvider {
                SettingsProviderDetail(store: store, provider: provider)
            } else if let subpage = store.subpage, subpage != "advanced", let toy = store.cardToy(subpage) {
                SettingsBackRow(store: store)
                SettingsFeatureDetail(toy: toy)
            } else if store.subpage == "advanced" {
                SettingsBackRow(store: store)
                SettingsAdvancedBody(store: store, page: page)
            } else {
                SettingsPageBody(store: store, page: page)
            }
            }
            .padding(JRBarTokens.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(JRBarTokens.Ink.content)
        .disclosureGroupStyle(SettingsDisclosureStyle())
        .toggleStyle(CardToggleStyle())
        .controlSize(.small)
        .animation(JRBarTokens.Motion.rowChange.animation(reduceMotion: reduceMotion), value: store.lastError == nil)
        .animation(JRBarTokens.Motion.rowChange.animation(reduceMotion: reduceMotion), value: store.status == nil)
    }
}

// MARK: - Atoms

/// Disables its content and shows a subtle hint when the daemon's document
/// lacks every path listed (the control then shows its default).
struct Provided<Content: View>: View {
    let store: SettingsStore
    let paths: [String]
    let recordsControl: Bool
    @ViewBuilder var content: () -> Content

    init(_ store: SettingsStore, _ paths: String..., recordsControl: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.paths = paths
        self.recordsControl = recordsControl
        self.content = content
    }

    private var provided: Bool { store.hasDocument && paths.contains { store.isProvided($0) } }

    static func reason(live: Bool, hasDocument: Bool, provided: Bool) -> String? {
        if !live { return "Reconnect to change this setting." }
        if !hasDocument { return "Waiting for settings." }
        return provided ? nil : "Not in this version"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
                .settingControl(recordsControl ? paths : [])
                .disabled(!provided || !store.isLive)
            if let reason = Self.reason(live: store.isLive, hasDocument: store.hasDocument, provided: provided) {
                Text(reason).jrbarType(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingLabel: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .jrbarType(.body)
                .foregroundStyle(.primary)
                .environment(\.isEnabled, true)
            if let subtitle {
                Text(subtitle)
                    .jrbarType(.caption)
                    // A disabled row's line is often the reason it is disabled,
                    // so it stays readable, only dimmer.
                    .foregroundStyle(.secondary)
                    .environment(\.isEnabled, true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A value readout beside a control, dimmed with it.
struct ValueText: View {
    let text: String
    var width: CGFloat = 58
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .environment(\.isEnabled, true)
            .frame(width: width, alignment: .trailing)
    }
}

struct SettingToggle: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    var fallback = false

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, default fallback: Bool = false) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.fallback = fallback
    }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
                Toggle(title, isOn: store.bool(path, default: fallback))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

struct SettingSlider: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let range: ClosedRange<Double>
    var step: Double? = nil
    var fallback: Double
    var format: (Double) -> String

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, in range: ClosedRange<Double>,
         step: Double? = nil, default fallback: Double, format: @escaping (Double) -> String) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.range = range
        self.step = step
        self.fallback = fallback
        self.format = format
    }

    /// AppKit draws a tick per step; past a handful they smear into a
    /// line, so fine steps are applied by rounding rather than by the slider.
    private var binding: Binding<Double> {
        let raw = store.double(path, default: fallback)
        guard let step, step > 0 else { return raw }
        return Binding(get: { raw.wrappedValue }, set: { raw.wrappedValue = ($0 / step).rounded() * step })
    }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
                HStack(spacing: JRBarTokens.Space.sm) {
                    Slider(value: binding, in: range)
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel(title)
                        .accessibilityValue(format(store.values.double(SettingsPath(path)) ?? fallback))
                        .accessibilityIdentifier(path)
                    ValueText(text: format(store.values.double(SettingsPath(path)) ?? fallback))
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

struct SettingPicker: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let options: [(value: String, label: String)]
    var fallback: String
    var segmented = false

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String,
         options: [(value: String, label: String)], default fallback: String, segmented: Bool = false) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.options = options
        self.fallback = fallback
        self.segmented = segmented
    }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
            let picker = Picker(title, selection: store.string(path, default: fallback)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }.labelsHidden().accessibilityLabel(title)
            if segmented {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
            }
        }
    }
}

/// A picker over a numeric key (`usage_graph_days`), so the write stays a number.
struct SettingIntPicker: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let options: [(value: Int, label: String)]
    var fallback: Int

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, options: [(value: Int, label: String)], default fallback: Int) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.options = options
        self.fallback = fallback
    }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
            Picker(title, selection: store.int(path, default: fallback)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }.labelsHidden().accessibilityLabel(title)
            .pickerStyle(.menu)
            }
        }
    }
}

struct SettingStepper: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let range: ClosedRange<Int>
    var step = 1
    var fallback: Int
    var unit: String

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, in range: ClosedRange<Int>,
         step: Int = 1, default fallback: Int, unit: String) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.range = range
        self.step = step
        self.fallback = fallback
        self.unit = unit
    }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
                HStack(spacing: 6) {
                    ValueText(text: "\(store.values.int(SettingsPath(path)) ?? fallback) \(unit)", width: 44)
                    Stepper("", value: store.int(path, default: fallback), in: range, step: step)
                        .labelsHidden()
                        .accessibilityLabel(title)
                }
            }
        }
    }
}

/// A text field that writes on commit (Return or focus loss), not per keystroke.
struct SettingTextField: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    var prompt = ""
    var monospaced = false
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, prompt: String = "", monospaced: Bool = false) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.prompt = prompt
        self.monospaced = monospaced
    }

    private var current: String { store.values.string(SettingsPath(path)) ?? "" }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
                TextField("", text: Binding(get: { focused ? draft : current }, set: { draft = $0 }), prompt: Text(prompt))
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .focused($focused)
                    .onChange(of: focused) { _, now in
                        if now { draft = current } else { commit() }
                    }
                    .onSubmit { commit() }
                    .textFieldStyle(.roundedBorder)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .frame(minWidth: 220, maxWidth: 320)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func commit() {
        if draft != current { store.set(path, .string(draft)) }
    }
}

/// A seconds value as a small numeric field with its unit.
struct SettingNumberField: View {
    let store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let range: ClosedRange<Double>
    var fallback: Double
    var unit: String
    @ViewState private var draft = ""
    @ViewState private var editing = false

    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String, in range: ClosedRange<Double>, default fallback: Double, unit: String) {
        self.store = store
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.range = range
        self.fallback = fallback
        self.unit = unit
    }

    private var current: Double { store.values.double(SettingsPath(path)) ?? fallback }
    private var currentText: String { current == current.rounded() ? String(Int(current)) : String(format: "%.1f", current) }

    var body: some View {
        Provided(store, path) {
            SettingsRow(title, subtitle: subtitle) {
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { editing ? draft : currentText }, set: { draft = $0 }), onEditingChanged: { began in
                        if began { draft = currentText; editing = true } else { commit() }
                    })
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .onSubmit { commit() }
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    ValueText(text: unit, width: max(16, CGFloat(unit.count) * 9))
                }
            }
        }
    }

    private func commit() {
        editing = false
        guard let value = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        if clamped != current { store.set(path, .number(clamped)) }
    }
}

/// A one-line explanatory footer under a section.
struct SectionNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        StatusBanner(detail: text)
    }
}

extension SettingsStore {
    static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    static let seconds: (Double) -> String = { $0 == $0.rounded() ? "\(Int($0)) s" : String(format: "%.1f s", $0) }
    static let minutes: (Double) -> String = UsageTime.settingMinutes
    static let points: (Double) -> String = { String(format: "%g pt", $0) }
}

extension SettingsStore.Chapter {
    /// Where the chapter starts on its page: the anchor of its first
    /// titled group. nil for a chapter at the top of its page.
    var anchor: String? {
        switch self {
        case .usage: return SettingsStore.groupAnchor("Usage")
        case .sounds: return SettingsStore.groupAnchor("Event sounds")
        case .lighting: return SettingsStore.groupAnchor("Provider colours")
        case .toys: return SettingsStore.groupAnchor("Toys")
        case .advanced: return SettingsStore.groupAnchor("Advanced")
        default: return nil
        }
    }
}

/// What a page is made of: its chapters in order, each the view that
/// used to be a page of its own.
struct SettingsPageBody: View {
    @Bindable var store: SettingsStore
    let page: SettingsStore.Page

    var body: some View {
        switch page {
        case .general: GeneralPage(store: store)
        case .agents:
            SettingsProvidersPage(store: store)
            SettingsUsageOptions(store: store)
            advancedLink
        case .alerts:
            NotificationsPage(store: store)
            SoundsPage(store: store)
            PhoneAlertGroup(store: store)
            advancedLink
        case .devices:
            DevicesPage(store: store)
            SettingsGroup {
                SettingsNavigationRow("Calibration profiles") {
                    store.reveal(SettingsSearchEntry(.lighting, "Calibration profiles", "Calibration profiles"))
                }
            }
            SettingsStudioLink(store: store)
        case .notch:
            if let notch = store.toys?.notch {
                SettingsFeatureDetail(toy: notch)
            }
        case .utilities:
            UtilitiesPage(store: store)
            ToysPage(store: store)
        case .shortcuts:
            ShortcutsPage(store: store)
            advancedLink
        case .remote: RemotePage(store: store)
        case .privacy: SettingsPrivacyPage(store: store)
        case .integrations:
            IntegrationsPage(store: store)
        case .advanced: GeneralAdvanced(store: store)
        }
    }

    private var advancedLink: some View {
        SettingsGroup {
            SettingsNavigationRow("Advanced") { store.subpage = "advanced" }
        }
    }
}

struct SettingsAdvancedBody: View {
    let store: SettingsStore
    let page: SettingsStore.Page

    var body: some View {
        switch page {
        case .agents:
            AgentsAdvanced(store: store)
            UsageAdvanced(store: store)
        case .alerts:
            NotificationsAdvanced(store: store)
            SoundsAdvanced(store: store)
        case .shortcuts: ShortcutsAdvanced()
        default: EmptyView()
        }
    }
}
