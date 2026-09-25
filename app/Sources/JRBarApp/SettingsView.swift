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
            List(selection: $store.page) {
                if store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(Array(SettingsStore.Page.sidebarGroups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { page in
                                Label {
                                    Text(page.title)
                                } icon: {
                                    SidebarIcon(symbol: page.symbol, tint: page.tint)
                                }
                                .tag(page)
                            }
                        }
                    }
                } else {
                    SettingsSearchResults(store: store)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.searchQuery, placement: .sidebar, prompt: "Search settings")
            .searchFocused($searchFocused)
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
        .frame(minWidth: 640, minHeight: 420)
        // A covered, minimised or far-Space window holds every preview.
        .environment(\.ledPreviewsHeld, heldAbove || store.windowCovered)
        .sheet(isPresented: Binding(get: { store.calibrating != nil }, set: { if !$0 { store.calibrating = nil } })) {
            CalibrationSheet(store: store, deviceID: store.calibrating ?? "", dismiss: { store.calibrating = nil })
        }
        .sheet(isPresented: Binding(get: { store.doctorReport != nil }, set: { if !$0 { store.doctorReport = nil } })) {
            DoctorSheet(report: store.doctorReport ?? .object([:]), dismiss: { store.doctorReport = nil })
        }
        .confirmationDialog(
            "Reset \(store.resetTarget?.title ?? "") to defaults?",
            isPresented: Binding(get: { store.resetTarget != nil }, set: { if !$0 { store.resetTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                if let page = store.resetTarget { store.resetPage(page) }
                store.resetTarget = nil
            }
            Button("Cancel", role: .cancel) { store.resetTarget = nil }
        } message: {
            Text("Every setting on that page goes back to the monitor's default. This cannot be undone.")
        }
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
                        SidebarIcon(symbol: toy?.symbol ?? entry.page.symbol,
                                    tint: toy.map { ToyCard.tint(for: $0.id, page: entry.page.tint) } ?? entry.page.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .lineLimit(1)
                            Text(entry.group.isEmpty || entry.group == entry.title
                                 ? entry.page.title : "\(entry.page.title) › \(entry.group)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(entry.page.title)")
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
        var cards: [any Toy] = []
        if let utilities {
            cards += [utilities.menuBar, utilities.dock, utilities.agents, utilities.dataHoarder] as [any Toy]
        }
        if let toys {
            if let notch = toys.notch { cards.append(notch) }
            cards += toys.toys
        }
        return cards.first { $0.id == id }
    }
}

extension SettingsStore.Page {
    /// The sidebar's runs, System Settings-style: the app itself, the
    /// agents and what they cost, the tools, the hardware and how it
    /// looks and sounds, then the plumbing. Every page sits in exactly
    /// one run.
    static let sidebarGroups: [[SettingsStore.Page]] = [
        [.general],
        [.agents, .usage, .notifications],
        [.utilities, .toys],
        [.devices, .lighting, .sounds],
        [.shortcuts, .remote, .advanced],
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
        .id(page)
    }

    /// Scroll to the card a search hit opened, once the new page has
    /// laid its rows out, and let its light go after a beat — unless a
    /// newer hit took it.
    private func scrollToHit(_ proxy: ScrollViewProxy) async {
        guard let card = store.highlightedCard, store.searchHit?.page == page else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            proxy.scrollTo(SettingsStore.cardAnchor(card), anchor: .top)
        }
        try? await Task.sleep(for: .seconds(2.4))
        guard !Task.isCancelled, store.highlightedCard == card else { return }
        store.highlightedCard = nil
    }

    private var form: some View {
        Form {
            Section {
                SettingsPageHeader(page: page)
            }
            if !store.hasDocument {
                Section {
                    SettingsBanner(symbol: "bolt.horizontal.circle.fill", tint: .orange,
                                   title: "Not connected",
                                   detail: "Settings are shown with defaults and cannot be changed until the monitor connects.")
                }
            }
            if let schema = store.settingsSchema, schema > CoreProtocol.knownSettingsSchema {
                Section {
                    SettingsBanner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                   title: "Newer settings schema",
                                   detail: "The monitor speaks schema \(schema); this app knows \(CoreProtocol.knownSettingsSchema). Newer settings may not appear — update the app.")
                }
            }
            if let error = store.lastError {
                Section {
                    SettingsBanner(symbol: "exclamationmark.triangle.fill", tint: .red, title: error)
                }
            }
            if store.lastError == nil, let status = store.status {
                Section {
                    SettingsBanner(symbol: "checkmark.circle.fill", tint: .green, title: status)
                }
            }
            if let hit = store.searchHit, hit.page == page, hit.title != page.title {
                Section {
                    SettingsBanner(symbol: "magnifyingglass", tint: page.tint,
                                   title: hit.group.isEmpty || hit.group == hit.title
                                       ? "“\(hit.title)” is on this page."
                                       : "“\(hit.title)” is under \(hit.group).")
                }
            }
            switch page {
            case .general: GeneralPage(store: store)
            case .agents: AgentsPage(store: store)
            case .usage: UsagePage(store: store)
            case .devices: DevicesPage(store: store)
            case .utilities: UtilitiesPage(store: store)
            case .lighting: LightingPage(store: store)
            case .toys: ToysPage(store: store)
            case .notifications: NotificationsPage(store: store)
            case .sounds: SoundsPage(store: store)
            case .shortcuts: ShortcutsPage(store: store)
            case .remote: RemotePage(store: store)
            case .advanced:
                AdvancedPage(store: store)
                DiagnosticsCopyGroup(store: store)
                SettingsTransferGroup(store: store)
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(SettingsDisclosureStyle())
        .animation(.easeInOut(duration: 0.15), value: store.lastError == nil)
        .animation(.easeInOut(duration: 0.15), value: store.status == nil)
    }
}

// MARK: - Atoms

/// Disables its content and shows a subtle hint when the daemon's document
/// lacks every path listed (the control then shows its default).
struct Provided<Content: View>: View {
    let store: SettingsStore
    let paths: [String]
    @ViewBuilder var content: () -> Content

    init(_ store: SettingsStore, _ paths: String..., @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.paths = paths
        self.content = content
    }

    private var provided: Bool { store.hasDocument && paths.contains { store.isProvided($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
                .disabled(!provided)
            if store.hasDocument, !provided {
                NotProvidedHint()
            }
        }
    }
}

struct NotProvidedHint: View {
    var body: some View {
        Text("Not in this version")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// A title with an optional explanatory line below it, the way System
/// Settings labels a toggle.
struct SettingLabel: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
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
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
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
            Toggle(isOn: store.bool(path, default: fallback)) {
                SettingLabel(title: title, subtitle: subtitle)
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
            HStack(spacing: 12) {
                SettingLabel(title: title, subtitle: subtitle)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
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
            let picker = Picker(selection: store.string(path, default: fallback)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
            }
            if segmented {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
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
            Picker(selection: store.int(path, default: fallback)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
            }
            .pickerStyle(.menu)
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
            LabeledContent {
                HStack(spacing: 6) {
                    ValueText(text: "\(store.values.int(SettingsPath(path)) ?? fallback) \(unit)", width: 44)
                    Stepper("", value: store.int(path, default: fallback), in: range, step: step)
                        .labelsHidden()
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
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
            LabeledContent {
                TextField("", text: Binding(get: { focused ? draft : current }, set: { draft = $0 }), prompt: Text(prompt))
                    .labelsHidden()
                    .focused($focused)
                    .onChange(of: focused) { _, now in
                        if now { draft = current } else { commit() }
                    }
                    .onSubmit { commit() }
                    .textFieldStyle(.roundedBorder)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .frame(minWidth: 220, maxWidth: 320)
                    .multilineTextAlignment(.leading)
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
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
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { editing ? draft : currentText }, set: { draft = $0 }), onEditingChanged: { began in
                        if began { draft = currentText; editing = true } else { commit() }
                    })
                    .labelsHidden()
                    .onSubmit { commit() }
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    ValueText(text: unit, width: max(16, CGFloat(unit.count) * 9))
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
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
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsStore {
    static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    static let seconds: (Double) -> String = { $0 == $0.rounded() ? "\(Int($0)) s" : String(format: "%.1f s", $0) }
    static let minutes: (Double) -> String = { "\(Int($0.rounded())) min" }
    static let points: (Double) -> String = { String(format: "%g pt", $0) }
}
