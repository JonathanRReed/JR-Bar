import SwiftUI

public struct ProviderLogoTile: View {
    public let provider: String
    public var size: CGFloat
    public var accent: Color
    @Environment(\.colorScheme) private var scheme

    public init(provider: String, size: CGFloat = 28, accent: Color? = nil) {
        self.provider = provider
        self.size = size
        self.accent = accent ?? ProviderPalette.color(for: provider)
    }

    public var body: some View {
        let ink = ProviderMarkInk.ink(for: NSColor(accent), on: scheme == .dark ? .darkPlate : .lightPlate)
        ZStack {
            RoundedRectangle(cornerRadius: JRBarTokens.Radius.tile).fill(accent.opacity(ProviderMarkInk.plateOpacity))
            if let logo = ProviderLogo.named(ProviderPalette.logoID(for: provider)) {
                ProviderTileMark(logo: logo)
                    .fill(Color(nsColor: ink))
                    .padding(JRBarTokens.Space.xs)
            } else {
                Image(systemName: provider == "factory" ? "shippingbox.fill" : "terminal.fill")
                    .font(JRBarTokens.TypeStyle.body.font)
                    .foregroundStyle(Color(nsColor: ink))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider)
    }
}

private struct ProviderTileMark: Shape {
    let logo: ProviderLogo
    func path(in rect: CGRect) -> Path { Path(logo.path(in: rect)) }
}

/// Place once above a page's rows. The caller supplies the one recovery action.
public struct StatusBanner<Action: View>: View {
    public enum Kind { case information, attention, failure }
    public let message: String
    public let kind: Kind
    private let action: Action

    public init(_ message: String, kind: Kind = .information, @ViewBuilder action: () -> Action) {
        self.message = message
        self.kind = kind
        self.action = action()
    }

    private var tint: Color {
        switch kind {
        case .information: JRBarTokens.Ink.secondary
        case .attention: JRBarTokens.Ink.attention
        case .failure: JRBarTokens.Ink.failure
        }
    }

    public var body: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            Image(systemName: kind == .information ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .foregroundStyle(JRBarTokens.Ink.label)
        .padding(JRBarTokens.Space.md)
        .background(JRBarTokens.Ink.fill, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
    }
}

/// One title and one control. Give the control its own accessible label.
public struct SettingsRow<Control: View>: View {
    public let title: String
    private let control: Control

    public init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: JRBarTokens.Space.md) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .foregroundStyle(JRBarTokens.Ink.label)
        .padding(JRBarTokens.Space.md)
        .frame(minHeight: 40)
    }
}

/// Only pass proven members. An unlinked worker stays dim and names that state.
public struct AgentGroupRow<Members: View>: View {
    public let provider: String
    public let name: String
    public let workerCount: Int
    public let unlinked: Bool
    @Binding private var expanded: Bool
    private let members: Members

    public init(provider: String, name: String, workerCount: Int, unlinked: Bool = false,
                expanded: Binding<Bool>, @ViewBuilder members: () -> Members) {
        self.provider = provider
        self.name = name
        self.workerCount = max(0, workerCount)
        self.unlinked = unlinked
        self._expanded = expanded
        self.members = members()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Button { expanded.toggle() } label: {
                HStack(spacing: JRBarTokens.Space.sm) {
                    ProviderLogoTile(provider: provider)
                    Text(unlinked ? "\(name) · unlinked worker" : "\(name) · \(workerCount) \(workerCount == 1 ? "worker" : "workers")")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(JRBarTokens.Ink.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { members.padding(.leading, JRBarTokens.Space.xxxl) }
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .foregroundStyle(unlinked ? JRBarTokens.Ink.stale : JRBarTokens.Ink.label)
        .opacity(unlinked ? 0.6 : 1)
        .padding(JRBarTokens.Space.md)
    }
}
