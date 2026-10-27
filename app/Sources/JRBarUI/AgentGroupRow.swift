import SwiftUI

/// Only pass proven members. The caller owns expansion and the elapsed clock.
public struct AgentGroupRow<Members: View>: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let provider: String
    public let name: String
    public let project: String?
    public let subtitle: String?
    public let elapsed: String?
    public let state: StateDot.State
    public let memberMarks: [String]
    public let workerCount: Int
    public let askingCount: Int
    public let unlinked: Bool
    @Binding private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.jrbarReduceMotion) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @UIState private var hovering = false
    @FocusState private var focused: Bool
    private var proofFocused = false
    private let members: Members

    public init(provider: String, name: String, project: String? = nil, subtitle: String? = nil,
                elapsed: String? = nil, state: StateDot.State = .working, memberMarks: [String] = [],
                workerCount: Int, askingCount: Int = 0, unlinked: Bool = false, expanded: Binding<Bool>,
                @ViewBuilder members: () -> Members) {
        self.provider = provider
        self.name = name
        self.project = project
        self.subtitle = subtitle
        self.elapsed = elapsed
        self.state = state
        self.memberMarks = memberMarks
        self.workerCount = max(0, workerCount)
        self.askingCount = max(0, askingCount)
        self.unlinked = unlinked
        self._expanded = expanded
        self.members = members()
    }

    /// Render interaction styling without posting input.
    func proofInteraction(hovered: Bool = false, focused: Bool = false) -> Self {
        var row = self
        row._hovering = UIState(initialValue: hovered)
        row.proofFocused = focused
        return row
    }

    public var body: some View {
        VStack(spacing: 0) {
            if unlinked { header } else {
                Button {
                    if reduceMotion { expanded.toggle() }
                    else { withAnimation(JRBarTokens.Motion.panelEntrance.animation) { expanded.toggle() } }
                } label: { header }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            if expanded && !unlinked {
                members.transition(.opacity.animation(JRBarTokens.Motion.panelEntrance.animation(reduceMotion: reduceMotion)))
            }
        }
        .foregroundStyle(neutralInk.label)
        .opacity(unlinked ? 0.55 : 1)
    }

    private var taskSubtitle: String? {
        if unlinked { return "No parent found · no share of the strip" }
        let attention = askingCount > 0 ? "\(askingCount) needs you" : nil
        let parts = [subtitle, attention].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: unlinked ? "info.circle" : "chevron.right")
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(neutralInk.tertiary)
                .rotationEffect(.degrees(!unlinked && expanded ? 90 : 0))
                .animation(reduceMotion ? nil : JRBarTokens.Motion.panelEntrance.animation, value: expanded)
                .frame(width: 14)
            ProviderLogoTile(provider: provider, dim: unlinked)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(unlinked ? name : "\(name) · \(workerCount) \(workerCount == 1 ? "worker" : "workers")")
                        .font(JRBarTokens.TypeStyle.headline.font).lineLimit(1).layoutPriority(1)
                    if let context = unlinked ? ProviderPalette.displayName(for: provider) : project {
                        Text(context).font(JRBarTokens.TypeStyle.body.font)
                            .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                if let task = taskSubtitle {
                    Text(task).font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !unlinked { trailing }
        }
        .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 8)
        .frame(minHeight: 40)
        .background(hovering ? neutralInk.hover : .clear, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .overlay { if focused || proofFocused { RoundedRectangle(cornerRadius: JRBarTokens.Radius.control).strokeBorder(JRBarTokens.Ink.accent, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if !memberMarks.isEmpty {
                HStack(spacing: -4) {
                    ForEach(Array(memberMarks.enumerated()), id: \.offset) { _, provider in
                        ProviderLogoTile(provider: provider, size: 16)
                    }
                }
            }
            if let elapsed { Text(elapsed).monospacedDigit().font(JRBarTokens.TypeStyle.callout.font).foregroundStyle(neutralInk.secondary) }
            StateDot(state)
        }
    }
}

/// Use inside AgentGroupRow's member builder, one row per proven worker.
public struct AgentMemberRow: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let provider: String
    public let name: String
    public let role: String?
    public let elapsed: String?
    public let state: StateDot.State
    public let isLast: Bool

    public init(provider: String, name: String, role: String? = nil, elapsed: String? = nil,
                state: StateDot.State = .working, isLast: Bool = false) {
        self.provider = provider
        self.name = name
        self.role = role
        self.elapsed = elapsed
        self.state = state
        self.isLast = isLast
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProviderLogoTile(provider: provider, size: 16)
            Text(name).lineLimit(1)
            if let role { Text(role).foregroundStyle(neutralInk.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            if state == .done { Text("Done").foregroundStyle(JRBarTokens.Ink.done) }
            if let elapsed { Text(elapsed).foregroundStyle(neutralInk.secondary).monospacedDigit() }
            StateDot(state)
        }
        .font(JRBarTokens.TypeStyle.callout.font)
        .foregroundStyle(neutralInk.label)
        .padding(.trailing, 8)
        .frame(minHeight: 28)
        .overlay(alignment: .leading) {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: -12, y: 0))
                    path.addLine(to: CGPoint(x: -12, y: isLast ? geometry.size.height / 2 : geometry.size.height))
                    path.move(to: CGPoint(x: -12, y: geometry.size.height / 2))
                    path.addLine(to: CGPoint(x: -4, y: geometry.size.height / 2))
                }.stroke(neutralInk.strongSeparator, lineWidth: 1)
            }
        }
        .padding(.leading, 34)
    }
}
