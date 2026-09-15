import JRBarCore
import SwiftUI

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
                .padding(.top, 4)
        } label: {
            SettingLabel(title: title, subtitle: subtitle)
        }
        .settingRowStyle()
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
