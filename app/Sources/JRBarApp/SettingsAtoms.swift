import JRBarUI
import JRBarCore
import SwiftUI

// MARK: - The visual system
//
// One scale for every Settings surface — the pages, the toy and utility
// cards, the sheets — so a card another lane builds sits in the same
// rhythm as a row on General without knowing the numbers.

/// The spacing scale and the few fixed sizes the Settings window uses.
enum SettingsMetrics {
    /// 4 · 8 · 12 · 16: the only gaps a Settings view should need.
    static let xs: CGFloat = JRBarTokens.Space.xs
    static let s: CGFloat = JRBarTokens.Space.sm
    static let m: CGFloat = JRBarTokens.Space.md
    static let l: CGFloat = JRBarTokens.Space.lg
    /// The air above and below one row inside a card body, where the
    /// form's own row padding does not reach.
    static let rowPadding: CGFloat = JRBarTokens.Space.xs
    /// Icon tiles: the sidebar's glyph, a card's mark, a page's header.
    static let sidebarTile: CGFloat = 22
    static let cardTile: CGFloat = 32
    static let headerTile: CGFloat = 44
    /// Corners of the inset panels a disclosure opens onto.
    static let panelRadius: CGFloat = JRBarTokens.Radius.group
}

/// An SF Symbol on a tinted, softly lit rounded square — System
/// Settings' sidebar glyph, grown to a card's mark or a page's header.
/// The gradient runs from a lighter top to the tint, a hairline catches
/// the light along the top edge, and the corner radius scales with the
/// tile so every size reads as the same family.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = SettingsMetrics.sidebarTile

    private var radius: CGFloat { size * 0.27 }
    private var glyph: CGFloat { size * 0.5 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(tint.gradient)
            shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.06)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(size > SettingsMetrics.sidebarTile ? 0.28 : 0), radius: size * 0.1, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

/// A short state in a capsule: a dot and a few words in its tint —
/// "Parked", "Needs Accessibility", "Live". It holds still (no clock
/// runs for it) and truncates rather than pushing a control out.
struct SettingsPageHeader: View {
    let page: SettingsStore.Page

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.m + 2) {
            SettingsIconTile(symbol: page.symbol, tint: page.tint, size: SettingsMetrics.headerTile)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .jrbarType(.title3).fontWeight(.semibold)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SettingsMetrics.xs)
        .accessibilityElement(children: .combine)
    }
}

extension SettingsStore.Page {
    /// The header's sentence: what the page is for, in a breath.
    var blurb: String {
        switch self {
        case .general: return "Startup, menu bar, power, updates and diagnostics."
        case .agents: return "Agent connections, usage and permission requests."
        case .alerts: return "Sounds, notifications and quiet periods."
        case .devices: return "SidePulse and Screen Bar hardware."
        case .notch: return "Notch and shelf."
        case .privacy: return "Local data and permissions."
        case .integrations: return "Automatic compatibility."
        case .advanced: return "Diagnostics, transfer and reset."
        case .utilities: return "Optional tools and toys for the menu bar, Dock, notch and agents."
        case .shortcuts: return "Keyboard shortcuts, links and commands."
        case .remote: return "Remote Macs, status endpoints and cloud agents."
        }
    }
}

/// A notice at the top of a page — not connected, a refused write, a
/// search hit — as a tinted glyph beside a line or two.
struct SettingsBanner: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String? = nil

    var body: some View {
        StatusBanner(title, kind: tint == Tone.failure.color ? .failure : .information, detail: detail)
    }
}

/// A group's title with a glyph and a state beside it — a device's name
/// and whether it is connected — for the groups that stand for a thing
/// rather than an idea.
struct SettingsGroupHeader: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .gray
    var pill: String? = nil
    var pillTint: Color = .secondary
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: SettingsMetrics.s) {
            if let symbol {
                SettingsIconTile(symbol: symbol, tint: tint, size: 20)
            }
            Text(title)
                .jrbarType(.heading)
            if let pill {
                StatusBadge(pill, tint: pillTint)
            }
            Spacer(minLength: SettingsMetrics.s)
            if let trailing {
                Text(trailing)
                    .jrbarType(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Card bodies
//
// A toy or utility card's controls arrive as one view from the lane that
// owns the toy. These styles give every row inside it the same beat —
// switches on the trailing edge, a little air above and below, the same
// inset panel under every disclosure — without the card knowing them.

/// A small heading that splits a long card body into named runs:
/// "Island", "Capsules", "Media".
struct CardSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        SectionHeader(title)
            .padding(.top, SettingsMetrics.m)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet explanatory line inside a card, with a glyph — how a thing
/// works, or what a pick hands over — never a control.
struct CardNote: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    init(_ text: String, symbol: String = "info.circle", tint: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        StatusBanner(detail: text, kind: tint == Tone.failure.color ? .failure : .information)
    }
}

/// A card-body toggle: the system switch, trailing, with a row's air.
struct CardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsMetrics.m) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(configuration).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// A card-body labelled row: the form's own layout, with a row's air.
struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsMetrics.m) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// Every disclosure in Settings: the whole row is the button, the
/// chevron turns in the trailing control column so titles stay on one
/// edge, and what it opens sits on an inset panel below.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    var flattened = false

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if flattened {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                configuration.label
                    .accessibilityAddTraits(.isHeader)
                configuration.content
            }
            .padding(.vertical, JRBarTokens.Space.sm)
        } else {
            SettingsDisclosure(configuration: configuration)
        }
    }
}

private struct SettingsDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
        let open = configuration.isExpanded
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: SettingsMetrics.m) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureChevron(open: open, hovering: hovering)
                }
                .padding(.vertical, SettingsMetrics.rowPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "Collapses" : "Expands")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    configuration.content
                }
                .toggleStyle(CardToggleStyle())
                .labeledContentStyle(CardLabeledContentStyle())
                .padding(.horizontal, SettingsMetrics.m)
                .padding(.vertical, SettingsMetrics.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(InsetPanel())
                .padding(.top, 2)
                .padding(.bottom, SettingsMetrics.s)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// The chevron every disclosure turns: right when shut, down when open,
/// its well a shade deeper under the pointer.
struct DisclosureChevron: View {
    let open: Bool
    var hovering = false

    var body: some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(JRBarTokens.TypeStyle.caption.font)
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
    }

/// The recessed panel a disclosure opens onto: a hair darker than the
/// group it sits in, with a hairline edge, in either appearance.
struct InsetPanel: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
        shape
            .fill(Color.primary.opacity(0.035))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// The rows that only matter while the row above them is on — a
/// capsule's kinds under "Event capsules" — on the same inset panel a
/// disclosure opens onto, so they read as that row's own.
struct CardSubrows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, SettingsMetrics.m)
        .padding(.vertical, SettingsMetrics.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InsetPanel())
        .padding(.bottom, SettingsMetrics.xs)
    }
}

/// A many-of-many switch as a capsule that fills with the accent when
/// on — five event kinds in one line instead of five rows.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark" : "plus")
                    .jrbarType(.caption).fontWeight(.bold)
                configuration.label
            }
            .jrbarType(.callout).fontWeight(.medium)
            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1),
                                            lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Lays its children out left to right and wraps to a new line when the
/// next one would not fit — a row of chips at any window width.
struct FlowLayout: Layout {
    var spacing: CGFloat = SettingsMetrics.s
    var lineSpacing: CGFloat = SettingsMetrics.s - 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.last.map { $0.y + $0.height } ?? 0
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.members {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + line.y),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Line {
        var members: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.members.isEmpty ? size.width : line.width + spacing + size.width
            if !line.members.isEmpty, needed > width {
                lines.append(line)
                line = Line(y: line.y + line.height + lineSpacing)
            }
            line.width = line.members.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.members.append(index)
        }
        if !line.members.isEmpty { lines.append(line) }
        return lines
    }
}

extension View {
    /// Starts a new run inside a card or a disclosure panel: a hairline
    /// above and a breath of room, for a run whose heading is a titled
    /// `SettingLabel` rather than a `CardSectionHeader`.
    func cardHeading() -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            Divider()
            self
        }
        .padding(.top, SettingsMetrics.s)
    }

    /// The styles a card body's rows share (`CardToggleStyle`,
    /// `CardLabeledContentStyle`, `SettingsDisclosureStyle`).
    func cardBodyStyle(flattenDisclosures: Bool = false) -> some View {
        self
            .toggleStyle(CardToggleStyle())
            .labeledContentStyle(CardLabeledContentStyle())
            .disclosureGroupStyle(SettingsDisclosureStyle(flattened: flattenDisclosures))
    }
}

// MARK: - Row atoms
//
// The shared shapes every Settings page is built from, so a toggle on one
// page reads exactly like a toggle on another. The leaf atoms (Provided,
// SettingLabel, SettingToggle, …) live in SettingsView.swift; these are
// the row- and group-level pieces layered on top of them.

/// A titled group of settings rows: the bold header, inset dividers and
/// optional footer note of a macOS grouped form, one idea per group.
///
/// Inside a page's Advanced disclosure (`PageAdvanced`) the same group
/// draws as a quiet sub-heading and its rows, since a form section cannot
/// sit inside a row.
struct SettingGroup<Header: View, Content: View>: View {
    var note: String? = nil
    /// The title a search hit scrolls to (`SettingsStore.groupAnchor`).
    var anchor: String? = nil
    /// The group's title as plain text, for the inline look.
    var plainTitle: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @Environment(\.settingGroupsInline) private var inline

    init(note: String? = nil, anchor: String? = nil, plainTitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder header: @escaping () -> Header) {
        self.note = note
        self.anchor = anchor
        self.plainTitle = plainTitle
        self.content = content
        self.header = header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            if let anchor {
                header().jrbarType(.section).id(SettingsStore.groupAnchor(anchor))
            } else {
                header().jrbarType(.section)
            }
            SettingsGroup { content() }
            if let note { SectionNote(note) }
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let plainTitle {
                CardSectionHeader(plainTitle)
                    .id(SettingsStore.groupAnchor(anchor ?? plainTitle))
            } else {
                header()
                    .jrbarType(.callout).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, SettingsMetrics.m)
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
            if let note {
                SectionNote(note)
                    .padding(.top, SettingsMetrics.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SettingsMetrics.s)
    }
}

extension SettingGroup where Header == SectionHeader {
    /// A group with the standard bold title, e.g. `SettingGroup("Dimming")`.
    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(note: note, anchor: title, plainTitle: title, content: content) { SectionHeader(title) }
    }
}

private struct SettingGroupsInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a page's Advanced disclosure, where a `SettingGroup`
    /// draws inline instead of as a form section.
    var settingGroupsInline: Bool {
        get { self[SettingGroupsInlineKey.self] }
        set { self[SettingGroupsInlineKey.self] = newValue }
    }
}

/// The one "Advanced" disclosure a page ends with: the settings most
/// people never change, folded away. Each group inside keeps its own
/// name, so search can still land on a row and open the fold.
struct PageAdvanced<Content: View>: View {
    let store: SettingsStore
    let page: SettingsStore.Page
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Section {
            DisclosureRow("Advanced", subtitle: subtitle, fold: SettingsFold.advanced(page)) {
                content()
                    .environment(\.settingGroupsInline, true)
            }
            .id(SettingsStore.groupAnchor("Advanced"))
        }
    }
}

extension SettingGroup where Header == EmptyView {
    /// A group with no title, for a page's lead cluster of rows.
    init(note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(note: note, content: content) { EmptyView() }
    }
}

/// The one row rhythm every page shares: a little vertical air and a
/// full-width, leading layout, so a toggle row and a slider row sit on
/// the same beat inside a group.
struct SettingRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .settingsRowInsets()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The standard settings-row chrome (`SettingRowStyle`).
    func settingRowStyle() -> some View { modifier(SettingRowStyle()) }
}

/// A labelled row with a single trailing control — the System Settings
/// shape: a title of a few words, a one-sentence description, the control
/// on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: () -> Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) { control() }
    }
}

/// A collapsed row for the controls a page rarely needs — resets,
/// fine-tuning, developer flags — so they stop crowding the everyday
/// ones. Tap the title to unfold them.
struct DisclosureRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// The store's fold this row opens with, so a search hit on a row
    /// inside it can unfold it (`SettingsFold`). nil keeps its own state.
    var fold: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewState private var local = false
    @Environment(SettingsStore.self) private var store: SettingsStore?

    init(_ title: String, subtitle: String? = nil, fold: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.fold = fold
        self.content = content
    }

    private var expanded: Binding<Bool> {
        guard let fold, let store else { return $local }
        return Binding(get: { store.isFoldOpen(fold) }, set: { store.setFold(fold, open: $0) })
    }

    var body: some View {
        SettingsExpansionRow(title, subtitle: subtitle, isExpanded: expanded) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A long run of rows folded under one row of its own: the title, a line
/// on what it holds and the disclosure chevron. Folded, the rows are
/// neither built nor measured, which is what keeps a heavy page quick to
/// open; unfolded, they are ordinary rows of the group, as before. The
/// store keeps each fold as the person left it while the app runs, and a
/// search hit unfolds the one that holds its row (`SettingsFold`).
struct SettingsFoldRow<Content: View>: View {
    @Bindable var store: SettingsStore
    let id: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    init(_ store: SettingsStore, id: String, title: String, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    private var expanded: Binding<Bool> {
        Binding(get: { store.isFoldOpen(id) }, set: { open in
            withAnimation(reduceMotion ? nil : JRBarTokens.Motion.quick.animation) { store.setFold(id, open: open) }
        })
    }

    var body: some View {
        SettingsExpansionRow(title, subtitle: subtitle, isExpanded: expanded) { content() }
    }
}

/// A many-of-many picker as one compact row: the menu's items carry
/// checkmarks and the button reads "Claude, Codex, +2" — the wall of
/// per-provider checkboxes, collapsed.
///
/// Wrap it in `Provided` exactly as the checkboxes it replaces were:
/// the atom itself does no gating.
struct MultiSelectMenu: View {
    let title: String
    var subtitle: String? = nil
    let options: [(value: String, label: String)]
    var providerTiles = false
    var document: SettingsDocument? = nil
    /// Membership of each option's `value`, toggled from the menu.
    let membership: (String) -> Binding<Bool>
    /// Per-item enablement (`nil` = every item enabled); keeps a provider
    /// whose key is absent from the document dimmed inside the menu.
    var itemEnabled: ((String) -> Bool)? = nil

    init(_ title: String, subtitle: String? = nil,
         options: [(value: String, label: String)], providerTiles: Bool = false,
         document: SettingsDocument? = nil,
         itemEnabled: ((String) -> Bool)? = nil,
         membership: @escaping (String) -> Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self.providerTiles = providerTiles
        self.document = document
        self.itemEnabled = itemEnabled
        self.membership = membership
    }

    /// A string-list setting (`usage_graph_providers`, `webhook_events`).
    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, path: String,
         options: [(value: String, label: String)], providerTiles: Bool = false) {
        self.init(title, subtitle: subtitle, options: options, providerTiles: providerTiles,
                  document: store.values.document(["colors.agent_colors"])) { store.listMember(path, $0) }
    }

    /// One bool per option under a key prefix (`transcript_monitoring.claude`, …).
    /// Items whose key the document does not carry stay dimmed in the menu.
    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, keyPrefix: String,
         options: [(value: String, label: String)], providerTiles: Bool = false, default fallback: Bool = false) {
        self.init(title, subtitle: subtitle, options: options, providerTiles: providerTiles,
                  document: store.values.document(["colors.agent_colors"]),
                  itemEnabled: { store.isProvided("\(keyPrefix).\($0)") }) {
            store.bool("\(keyPrefix).\($0)", default: fallback)
        }
    }

    /// The button's summary: "None" when empty, "All" when every option is
    /// in, else the first `maxNames` labels and "+N" for the rest —
    /// "Claude, Codex, +2". Order follows `options`, not selection order;
    /// selected values with no option are not named.
    nonisolated static func summary(selected: Set<String>, options: [(value: String, label: String)], maxNames: Int = 2) -> String {
        let labels = options.filter { selected.contains($0.value) }.map(\.label)
        guard !labels.isEmpty else { return "None" }
        if labels.count == options.count { return "All" }
        if labels.count <= maxNames { return labels.joined(separator: ", ") }
        return labels.prefix(maxNames).joined(separator: ", ") + ", +\(labels.count - maxNames)"
    }

    private var selected: Set<String> {
        Set(options.filter { membership($0.value).wrappedValue }.map(\.value))
    }

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            Menu {
                ForEach(options, id: \.value) { option in
                    Toggle(isOn: membership(option.value)) {
                        if providerTiles {
                            Label {
                                Text(option.label)
                            } icon: {
                                ProviderTile(style: ProviderStyle.style(for: option.value, document: document), size: 16)
                            }
                        } else {
                            Text(option.label)
                        }
                    }
                    .disabled(itemEnabled.map { !$0(option.value) } ?? false)
                }
            } label: {
                Text(Self.summary(selected: selected, options: options))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityLabel(title)
        }
    }
}
