import AppKit
import JRBarCore
import SwiftUI

public struct SectionHeader: View {
    @Environment(\.jrbarInk) private var neutralInk
    private let title: String
    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title).jrbarType(.section).foregroundStyle(neutralInk.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct ProviderLogoTile: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let provider: String
    public var size: CGFloat
    public var accent: Color?
    public var dim: Bool
    public var surface: ProviderMarkInk.Surface?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(provider: String, size: CGFloat = 20, accent: Color? = nil, dim: Bool = false,
                surface: ProviderMarkInk.Surface? = nil) {
        self.provider = ProviderID.canonical(provider)
        self.size = size
        self.accent = accent
        self.dim = dim
        self.surface = surface
    }

    private var tint: Color {
        accent ?? (provider.lowercased() == "grok" ? JRBarTokens.Ink.grok : ProviderPalette.color(for: provider))
    }

    public var body: some View {
        let target = surface ?? (scheme == .dark ? .darkPlate : .lightPlate)
        let ink = ProviderMarkInk.ink(for: NSColor(tint), on: target == .black ? .blackPlate : target)
        let defaultGrok = provider.lowercased() == "grok" && accent == nil
        let grokInk = target == .black ? JRBarTokens.Ink.grokOnBlack : JRBarTokens.Ink.grok
        let markInk = dim ? neutralInk.secondary : defaultGrok ? grokInk : Color(nsColor: ink)
        let shape = RoundedRectangle(cornerRadius: JRBarTokens.Radius.providerTile(size: size))
        ZStack {
            shape.fill(dim ? neutralInk.tertiaryFill : tint.opacity(ProviderMarkInk.plateOpacity))
            if let logo = ProviderLogo.named(ProviderPalette.logoID(for: provider)) {
                ProviderTileMark(logo: logo)
                    .fill(markInk)
                    .padding(size * 0.20)
            } else {
                Image(systemName: "questionmark")
                    .resizable().scaledToFit()
                    .foregroundStyle(neutralInk.secondary)
                    .padding(size * 0.20)
            }
        }
        .overlay { if dim || contrast == .increased || neutralInk.increased { shape.strokeBorder(neutralInk.separator, lineWidth: 0.5) } }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProviderPalette.displayName(for: provider))
    }
}

private struct ProviderTileMark: Shape {
    let logo: ProviderLogo
    func path(in rect: CGRect) -> Path { Path(logo.path(in: rect)) }
}

/// Place once above a page's rows. The caller supplies the recovery action.
public struct StatusBanner<Action: View>: View {
    @Environment(\.jrbarInk) private var neutralInk
    public enum Kind { case information, attention, failure }
    public let message: String
    public let kind: Kind
    public let detail: String?
    private let action: Action

    public init(_ message: String, kind: Kind = .information, detail: String? = nil,
                @ViewBuilder action: () -> Action) {
        self.message = message
        self.kind = kind
        self.detail = detail
        self.action = action()
    }

    private var tint: Color {
        switch kind {
        case .information: neutralInk.secondary
        case .attention: Tone.ask.color
        case .failure: Tone.failure.color
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: JRBarTokens.Space.sm) {
            Image(systemName: kind == .information ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if !message.isEmpty { Text(message).jrbarType(.headline) }
                if let detail { Text(detail).jrbarType(.caption).foregroundStyle(neutralInk.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            action.buttonStyle(.bordered).controlSize(.small)
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .foregroundStyle(neutralInk.label)
        .padding(.vertical, 10).padding(.horizontal, JRBarTokens.Space.md)
        .background(neutralInk.fill, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
        .overlay { RoundedRectangle(cornerRadius: JRBarTokens.Radius.group).strokeBorder(neutralInk.groupEdge, lineWidth: 0.5) }
    }
}

public extension StatusBanner where Action == EmptyView {
    init(_ message: String, kind: Kind = .information, detail: String? = nil) {
        self.init(message, kind: kind, detail: detail) { EmptyView() }
    }

    init(detail: String, kind: Kind = .information) {
        self.init("", kind: kind, detail: detail) { EmptyView() }
    }
}

/// One title and control. Give the control its own accessible label.
public struct SettingsRow<Control: View>: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let title: String
    public let subtitle: String?
    private let control: Control

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: JRBarTokens.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).jrbarType(.body)
                if let subtitle { Text(subtitle).jrbarType(.caption).foregroundStyle(neutralInk.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.controlSize(.small)
        }
        .foregroundStyle(neutralInk.label)
        .settingsRowInsets()
    }
}

public struct SettingsNavigationRow: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let title: String
    public let subtitle: String?
    public let action: () -> Void
    @UIState private var hovering = false

    public init(_ title: String, subtitle: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SettingsRow(title, subtitle: subtitle) {
                Image(systemName: "chevron.right").jrbarType(.caption).foregroundStyle(neutralInk.tertiary)
            }
            .background(hovering ? neutralInk.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title.hasPrefix("Open ") ? title : "Open \(title)")
    }
}

public struct SettingsExpansionRow<Content: View>: View {
    @Environment(\.jrbarInk) private var neutralInk
    @Binding private var expanded: Bool
    @UIState private var hovering = false
    private let title: String
    private let subtitle: String?
    private let content: () -> Content

    public init(_ title: String, subtitle: String? = nil, isExpanded: Binding<Bool>,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self._expanded = isExpanded
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                SettingsRow(title, subtitle: subtitle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .jrbarType(.caption)
                        .foregroundStyle(neutralInk.tertiary)
                }
                .background(hovering ? neutralInk.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(expanded ? "Collapse" : "Expand") \(title)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content() }
        }
    }
}

private struct SettingsGroupOwnsInsetsKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var settingsGroupOwnsInsets: Bool {
        get { self[SettingsGroupOwnsInsetsKey.self] }
        set { self[SettingsGroupOwnsInsetsKey.self] = newValue }
    }
}

private struct SettingsRowInsets: ViewModifier {
    @Environment(\.settingsGroupOwnsInsets) private var grouped

    func body(content: Content) -> some View {
        if grouped {
            content
        } else {
            content
                .padding(.vertical, JRBarTokens.Space.sm)
                .padding(.horizontal, JRBarTokens.Space.md)
                .frame(minHeight: 40)
        }
    }
}

public extension View {
    /// Standalone rows keep the same insets as rows inside a settings group.
    func settingsRowInsets() -> some View { modifier(SettingsRowInsets()) }
}

/// The group owns row insets, including bare native controls and custom rows.
public struct SettingsGroup<Content: View>: View {
    @Environment(\.jrbarInk) private var neutralInk
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.jrbarReduceTransparency) private var transparencyOverride
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(neutralInk.separator).frame(height: 0.5).padding(.horizontal, JRBarTokens.Space.md)
                    }
                    row
                        .padding(.vertical, JRBarTokens.Space.sm)
                        .padding(.horizontal, JRBarTokens.Space.md)
                        .frame(minHeight: 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .environment(\.settingsGroupOwnsInsets, true)
        .background((transparencyOverride ?? systemReduceTransparency) ? JRBarTokens.Ink.content : JRBarTokens.Ink.group)
        .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
        .overlay { RoundedRectangle(cornerRadius: JRBarTokens.Radius.group).strokeBorder(neutralInk.groupEdge, lineWidth: 0.5) }
    }
}
