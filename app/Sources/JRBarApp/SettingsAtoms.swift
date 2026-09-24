import JRBarCore
import SwiftUI

// MARK: - The visual system
//
// One scale for every Settings surface — the pages, the toy and utility
// cards, the sheets — so a card another lane builds sits in the same
// rhythm as a row on General without knowing the numbers.

/// The spacing scale and the few fixed sizes the Settings window uses.
enum SettingsMetrics {
    /// 4 · 8 · 12 · 16 · 24: the only gaps a Settings view should need.
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    /// The air above and below one row inside a card body, where the
    /// form's own row padding does not reach.
    static let rowPadding: CGFloat = 5
    /// Icon tiles: the sidebar's glyph, a card's mark, a page's header.
    static let sidebarTile: CGFloat = 22
    static let cardTile: CGFloat = 32
    static let headerTile: CGFloat = 44
    /// Corners of the inset panels a disclosure opens onto.
    static let panelRadius: CGFloat = 10
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
struct StatusPill: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint.mix(with: .primary, by: 0.3))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The head of every page: its glyph grown to a header tile, the page's
/// name and one sentence on what lives there — System Settings' pane
/// header, first thing on the form.
struct SettingsPageHeader: View {
    let page: SettingsStore.Page

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.m + 2) {
            SettingsIconTile(symbol: page.symbol, tint: page.tint, size: SettingsMetrics.headerTile)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.title3.weight(.semibold))
                Text(page.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        case .general: return "Startup, the menu bar icon, brightness and updates."
        case .agents: return "Which agents report in, what JR-Bar reads from them and when they may ask."
        case .usage: return "Meters, graphs, plan limits and the alerts that watch your quota."
        case .devices: return "SidePulse hardware, the Creator Micro and the light band under the notch."
        case .utilities: return "Tools that replace other apps — the menu bar, the Dock, the notch — and keep the agent roster organized."
        case .lighting: return "Colours, pulses, dimming and the moments the lights can play."
        case .toys: return "Stuff that's just fun. None of it touches your agents or your usage, & every bit of it can be turned off."
        case .notifications: return "When JR-Bar speaks up, how loudly, and when it keeps quiet."
        case .sounds: return "A sound for each moment, one volume, and where they play."
        case .shortcuts: return "Every key JR-Bar holds, and the links that do the same things."
        case .remote: return "Other Macs, the local endpoint, cloud ingest and webhooks."
        case .advanced: return "Diagnostics, resets, reports and moving settings to another Mac."
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(detail == nil ? .regular : .semibold)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
                .font(.headline)
            if let pill {
                StatusPill(pill, tint: pillTint)
            }
            Spacer(minLength: SettingsMetrics.s)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
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
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
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
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 3)
    }
}

/// A card-body toggle: the system switch, trailing, with a row's air.
struct CardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// A card-body labelled row: the form's own layout, with a row's air.
struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent(configuration)
            .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// Every disclosure in Settings: the whole row is the button, the
/// chevron turns in the trailing control column so titles stay on one
/// edge, and what it opens sits on an inset panel below.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsDisclosure(configuration: configuration)
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
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(hovering ? .primary : .secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            .animation(.easeOut(duration: 0.12), value: hovering)
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
                    .font(.system(size: 9, weight: .bold))
                configuration.label
            }
            .font(.subheadline.weight(.medium))
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
    func cardBodyStyle() -> some View {
        self
            .toggleStyle(CardToggleStyle())
            .labeledContentStyle(CardLabeledContentStyle())
            .disclosureGroupStyle(SettingsDisclosureStyle())
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
struct SettingGroup<Header: View, Content: View>: View {
    var note: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    init(note: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder header: @escaping () -> Header) {
        self.note = note
        self.content = content
        self.header = header
    }

    var body: some View {
        Section {
            content()
        } header: {
            header()
        } footer: {
            if let note { SectionNote(note) }
        }
    }
}

extension SettingGroup where Header == Text {
    /// A group with the standard bold title, e.g. `SettingGroup("Dimming")`.
    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(note: note, content: content) { Text(title).font(.headline) }
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
            .padding(.vertical, 2)
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
        LabeledContent {
            control()
        } label: {
            SettingLabel(title: title, subtitle: subtitle)
        }
        .settingRowStyle()
    }
}

/// A collapsed row for the controls a page rarely needs — resets,
/// fine-tuning, developer flags — so they stop crowding the everyday
/// ones. Tap the title to unfold them.
struct DisclosureRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewState private var expanded = false

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
        } label: {
            SettingLabel(title: title, subtitle: subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                  document: store.document) { store.listMember(path, $0) }
    }

    /// One bool per option under a key prefix (`transcript_monitoring.claude`, …).
    /// Items whose key the document does not carry stay dimmed in the menu.
    init(_ store: SettingsStore, _ title: String, subtitle: String? = nil, keyPrefix: String,
         options: [(value: String, label: String)], providerTiles: Bool = false, default fallback: Bool = false) {
        self.init(title, subtitle: subtitle, options: options, providerTiles: providerTiles,
                  document: store.document,
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
