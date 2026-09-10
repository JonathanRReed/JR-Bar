import JRBarCore
import SwiftUI

/// The Settings window's content: a System Settings-style sidebar and a
/// grouped form per page. Every control reads the daemon's document through
/// `SettingsStore` and writes through `set_setting`.
struct SettingsRootView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.page) {
                ForEach(SettingsStore.Page.allCases) { page in
                    Label {
                        Text(page.title)
                    } icon: {
                        SidebarIcon(symbol: page.symbol, tint: page.tint)
                    }
                    .tag(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            NavigationStack {
                SettingsPageContainer(store: store, page: store.page)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 420)
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
            Text("Every setting on that page goes back to the core's default. This cannot be undone.")
        }
    }
}

/// System Settings tints each sidebar glyph inside a small rounded square.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(tint.gradient)
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: 22, height: 22)
    }
}

/// One page: the form, an offline banner when the daemon has not sent its
/// document, and a transient error line for refused writes.
struct SettingsPageContainer: View {
    @Bindable var store: SettingsStore
    let page: SettingsStore.Page

    var body: some View {
        Form {
            if !store.hasDocument {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Core not connected").fontWeight(.semibold)
                            Text("Settings are shown with defaults and cannot be changed until the core sends its settings document.")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
                    }
                }
            }
            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            switch page {
            case .general: GeneralPage(store: store)
            case .agents: AgentsPage(store: store)
            case .usage: UsagePage(store: store)
            case .devices: DevicesPage(store: store)
            case .lighting: LightingPage(store: store)
            case .notifications: NotificationsPage(store: store)
            case .remote: RemotePage(store: store)
            case .advanced: AdvancedPage(store: store)
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.15), value: store.lastError == nil)
        .id(page)
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
        Text("Not provided by core")
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
                    .font(.callout)
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
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: binding, in: range)
                        .frame(width: 180)
                    ValueText(text: format(store.document.double(SettingsPath(path)) ?? fallback))
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
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
                picker.pickerStyle(.menu).fixedSize()
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
            .fixedSize()
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
                    ValueText(text: "\(store.document.int(SettingsPath(path)) ?? fallback) \(unit)", width: 44)
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

    private var current: String { store.document.string(SettingsPath(path)) ?? "" }

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

    private var current: Double { store.document.double(SettingsPath(path)) ?? fallback }
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
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsStore {
    static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }
    static let seconds: (Double) -> String = { $0 == $0.rounded() ? "\(Int($0)) s" : String(format: "%.1f s", $0) }
    static let minutes: (Double) -> String = { "\(Int($0.rounded())) min" }
    static let points: (Double) -> String = { "\(Int($0.rounded())) pt" }
}
