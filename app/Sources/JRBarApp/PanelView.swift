import JRBarCore
import SwiftUI

/// The Raycast-style panel under the status item. 360 pt wide, 13 pt type,
/// sections separated by hairlines rather than boxes, colour only where it
/// carries meaning (provider tiles, state dots, quota bars).
struct PanelView: View {
    @Bindable var store: PanelStore

    static let width: CGFloat = 360
    static let sessionsMaxHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store)
            Hairline()
            SessionsSection(store: store)
            Hairline()
            UsageSection(store: store)
            Hairline()
            DevicesSection(store: store)
            Hairline()
            PanelFooter(store: store)
        }
        .font(.system(size: 13))
        .frame(width: Self.width)
        .overlay(alignment: .bottom) { ToastView(text: store.toast, reduced: store.reduceMotion) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { store.contentSize = $0 }
    }
}

// MARK: - Shared atoms

struct Hairline: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    /// An optional "Details ›" affordance on the right (the Usage Center).
    var detailTitle: String? = nil
    var onDetail: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.2)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            if let detailTitle, let onDetail {
                Button(action: onDetail) {
                    HStack(spacing: 2) {
                        Text(detailTitle)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(detailTitle) (⌘U)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 4)
    }
}

/// A provider's tile: 22 pt rounded square in the accent with its glyph.
struct ProviderTile: View {
    let style: ProviderStyle
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(style.accent.opacity(0.18))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(style.accent.opacity(0.35), lineWidth: 0.5)
            switch style.glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(style.accent)
            case .text(let text):
                Text(text)
                    .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                    .foregroundStyle(style.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(style.name)
    }
}

/// The activity mark: breathing dot (working), amber pulse (waiting),
/// check (done), cross (failed), still dot (idle).
struct ActivityMark: View {
    let activity: SessionActivity
    let accent: Color
    let reduced: Bool
    @ViewState private var phase = false

    var body: some View {
        Group {
            switch activity {
            case .working:
                Circle().fill(accent)
                    .opacity(reduced ? 0.9 : (phase ? 1.0 : 0.35))
                    .scaleEffect(reduced ? 1 : (phase ? 1.0 : 0.85))
            case .waiting:
                ZStack {
                    Circle().fill(Color.orange.opacity(0.35))
                        .scaleEffect(reduced ? 1.4 : (phase ? 2.1 : 1.0))
                        .opacity(reduced ? 0.6 : (phase ? 0 : 0.8))
                    Circle().fill(Color.orange)
                }
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.9))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
            case .idle:
                Circle().fill(.quaternary)
            }
        }
        .frame(width: 8, height: 8)
        .onAppear { animate() }
        .onChange(of: activity) { animate() }
        .onChange(of: reduced) { animate() }
    }

    private func animate() {
        guard !reduced else { phase = false; return }
        switch activity {
        case .working:
            phase = false
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { phase = true }
        case .waiting:
            phase = false
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = true }
        default:
            phase = false
        }
    }
}

struct CountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.primary.opacity(0.08)))
    }
}

/// A hover-highlighting, selectable row container.
struct RowChrome<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

// MARK: - Header

struct PanelHeader: View {
    @Bindable var store: PanelStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.headerWord)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.opacity)
                .id("word-\(store.headerWord)")
                .transition(.opacity)
            if store.coreCrashed {
                Text(store.coreCrashDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                Button("Restart") { store.restartCore() }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Launch the core again")
            } else {
                Text(store.headerCounts)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            ConnectionDot(state: store.coreCrashed ? .crashed : store.connectionDot, reduced: store.reduceMotion)
                .help(store.connectionDescription)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: store.headerWord)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: store.headerCounts)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: store.coreCrashed)
    }
}

struct ConnectionDot: View {
    let state: PanelStore.ConnectionDot
    let reduced: Bool
    @ViewState private var phase = false

    private var color: Color {
        switch state {
        case .live: return .green
        case .connecting: return .orange
        case .fileFeeds: return Color.secondary.opacity(0.5)
        case .crashed: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(state == .connecting && !reduced ? (phase ? 1 : 0.3) : 1)
            .onAppear { pulse() }
            .onChange(of: state) { pulse() }
            .accessibilityLabel(state == .live ? "Core connected" : (state == .connecting ? "Connecting to core" : (state == .crashed ? "Core crashed" : "Using file feeds")))
    }

    private func pulse() {
        phase = false
        guard state == .connecting, !reduced else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
    }
}

// MARK: - Sessions

struct SessionsSection: View {
    @Bindable var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Sessions", trailing: store.rows.isEmpty ? nil : "\(store.rows.count)")
            if store.rows.isEmpty {
                SessionsEmptyState(store: store)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 1) {
                        ForEach(store.askRows) { row in
                            AskRow(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                        ForEach(store.plainRows) { row in
                            SessionRowView(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                    }
                    .padding(.bottom, 6)
                    .animation(PanelMotion.contents(reduced: store.reduceMotion), value: store.rows.map(\.id))
                }
                .frame(maxHeight: PanelView.sessionsMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let explanation = store.lightExplanation {
                WhyLightRow(explanation: explanation, store: store)
                    .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
            }
        }
        .padding(.bottom, 4)
        .animation(PanelMotion.contents(reduced: store.reduceMotion), value: store.lightExplanation == nil)
    }
}

/// "Why this light": one line under the sessions explaining what the strip
/// and the Screen Bar are doing; hover for the programs and the settings.
struct WhyLightRow: View {
    let explanation: LightExplanation
    @Bindable var store: PanelStore
    @ViewState private var hovering = false
    @ViewState private var frame: CGRect = .zero
    @ViewState private var pending: DispatchWorkItem?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "light.max")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .frame(width: 12)
            HStack(spacing: 0) {
                Text("\(explanation.motion): ")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize()
                Text(explanation.reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11.5))
            .id(explanation.headline)
            .transition(.opacity)
            Spacer(minLength: 4)
            if explanation.session != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            frame = newFrame
            store.whyRowFrame = newFrame
            // Rows above may have come or gone: keep the popover under the row.
            if hovering, pending == nil { store.whyHover(true, frame: newFrame) }
        }
        .onChange(of: explanation.headline) {
            if hovering, pending == nil { store.whyHover(true, frame: frame) }
        }
        .onHover { inside in
            hovering = inside
            pending?.cancel()
            if inside {
                let work = DispatchWorkItem { MainActor.assumeIsolated { pending = nil; if hovering { store.whyHover(true, frame: frame) } } }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            } else {
                pending = nil
                store.whyHover(false, frame: frame)
            }
        }
        .onDisappear { pending?.cancel(); store.whyHover(false, frame: frame) }
        .onTapGesture { store.openExplainedSession() }
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: explanation.headline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Why this light: \(explanation.headline)")
        .help("Why this light · hover for the programs and brightness settings")
    }
}

struct SessionsEmptyState: View {
    @Bindable var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if store.isLive {
                Label("No agents right now", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
                Text("Sessions from Claude, Codex, Gemini and friends appear here the moment they start.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Label(store.coreMayBeStarting ? "Core is starting" : "Core not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                Text("Showing the file feeds: \(store.fallbackDetail.lowercased()).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }
}

struct SessionRowView: View {
    let row: SessionRow
    @Bindable var store: PanelStore

    var body: some View {
        RowChrome(selected: store.selectedID == row.id, action: { store.open(row) }) {
            HStack(spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.label).fontWeight(.medium).lineLimit(1)
                        if row.workers > 0 { CountBadge(text: "\(row.workers)").help("\(row.workers) workers") }
                        if row.stale { Text("stale").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }
                    HStack(spacing: 4) {
                        Text(row.style.name).foregroundStyle(.secondary)
                        if let tail = row.cwdTail {
                            Text("·").foregroundStyle(.quaternary)
                            Text(tail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(row.activity.word)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.activity == .waiting ? Color.orange : Color.secondary)
                            .contentTransition(.opacity)
                        ActivityMark(activity: row.activity, accent: row.style.accent, reduced: store.reduceMotion)
                    }
                    if let elapsed = PanelStore.elapsed(since: row.since, now: store.now) {
                        Text(elapsed).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: row.activity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.style.name), \(row.activity.word)")
        .accessibilityAddTraits(.isButton)
    }
}

struct AskRow: View {
    let row: SessionRow
    @Bindable var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.label).fontWeight(.medium).lineLimit(1)
                        Text(row.ask?.kind?.capitalized ?? "Ask")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                    Text(row.ask?.summary ?? "Needs your answer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    ActivityMark(activity: .waiting, accent: row.style.accent, reduced: store.reduceMotion)
                        .padding(.top, 3)
                    if let elapsed = PanelStore.elapsed(since: row.ask?.openedAt.map { Date(timeIntervalSince1970: $0) } ?? row.since, now: store.now) {
                        Text(elapsed).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Deny") { if let ask = row.ask { store.deny(ask) } }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .keyboardShortcut("d", modifiers: .command)
                Button("Approve") { if let ask = row.ask { store.approve(ask) } }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(store.selectedID == row.id ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 0.5)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.open(row) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.label) asks: \(row.ask?.summary ?? "")")
    }
}

struct PillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(prominent ? Color.orange.opacity(configuration.isPressed ? 0.75 : 0.95)
                                         : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.10), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

// MARK: - Usage

struct UsageSection: View {
    @Bindable var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Usage", trailing: refreshed, detailTitle: store.isLive ? "Details" : nil, onDetail: { store.openUsageCenter() })
            if store.usage.isEmpty {
                Text(store.isLive ? "No usage reported yet." : "Usage comes from the core.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.usage) { usage in
                        UsageRow(usage: usage, store: store)
                            .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .animation(PanelMotion.contents(reduced: store.reduceMotion), value: store.usage.map(\.id))
            }
        }
    }

    private var refreshed: String? {
        guard let at = store.core.state?.usage?.refreshedAt else { return nil }
        guard let elapsed = PanelStore.elapsed(since: Date(timeIntervalSince1970: at), now: store.now) else { return nil }
        return "\(elapsed) ago"
    }
}

struct UsageRow: View {
    let usage: CoreProviderUsage
    @Bindable var store: PanelStore

    private var style: ProviderStyle { ProviderStyle.style(for: usage.id) }
    private var primary: CoreUsageWindow? { usage.windows.first { $0.name.lowercased() == "5h" } ?? usage.windows.first }
    private var secondary: CoreUsageWindow? { usage.windows.first { $0.name.lowercased() == "7d" } ?? (usage.windows.count > 1 ? usage.windows[1] : nil) }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ProviderTile(style: style, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(style.name).fontWeight(.medium)
                    if let hint = PanelStore.paceHint(usage.forecast?.pace) {
                        Text(hint).font(.system(size: 10)).foregroundStyle(paceColor(usage.forecast?.pace))
                    }
                    Spacer()
                    if let primary {
                        Text((usage.isDerived ? "~" : "") + "\(Int(primary.usedPct.rounded()))%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(barColor(primary.usedPct))
                            .contentTransition(.numericText())
                            .help(usage.isDerived ? "Derived estimate (\(usage.fidelity ?? "derived"))" : "Official figure")
                    }
                }
                HStack(spacing: 8) {
                    if let primary { QuotaBar(window: primary, accent: style.accent, reduced: store.reduceMotion) }
                    if let secondary { QuotaBar(window: secondary, accent: style.accent, reduced: store.reduceMotion) }
                }
                HStack(spacing: 8) {
                    if let text = PanelStore.countdown(to: primary?.resetsAt, now: store.now) {
                        Text("\(primary?.name ?? "") \(text)")
                    }
                    if let text = PanelStore.countdown(to: secondary?.resetsAt, now: store.now) {
                        Text("·").foregroundStyle(.quaternary)
                        Text("\(secondary?.name ?? "") \(text)")
                    }
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: primary?.usedPct)
        .accessibilityElement(children: .combine)
    }

    private func barColor(_ pct: Double) -> Color {
        if pct >= 95 { return .red }
        if pct >= 80 { return .orange }
        return .primary
    }

    private func paceColor(_ pace: String?) -> Color {
        switch pace?.lowercased() {
        case "ahead": return .orange
        case "behind": return .secondary
        default: return Color.secondary.opacity(0.7)
        }
    }
}

struct QuotaBar: View {
    let window: CoreUsageWindow
    let accent: Color
    let reduced: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(window.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, proxy.size.width * CGFloat(min(100, max(0, window.usedPct)) / 100)))
                        .animation(PanelMotion.contents(reduced: reduced), value: window.usedPct)
                }
            }
            .frame(height: 4)
        }
        .accessibilityLabel("\(window.name) \(Int(window.usedPct.rounded())) percent used")
    }

    private var fill: Color {
        if window.usedPct >= 95 { return .red }
        if window.usedPct >= 80 { return .orange }
        return accent
    }
}

// MARK: - Devices

struct DevicesSection: View {
    @Bindable var store: PanelStore

    private var chips: [(id: String, name: String, present: Bool, help: String)] {
        var result: [(String, String, Bool, String)] = []
        let pro = store.devices.first { $0.kind == "pro" }
        let dot = store.devices.first { $0.kind == "dot" }
        let bar = store.devices.first { $0.kind == "screen_bar" }
        result.append(("pro", "Pro", pro?.isPresent ?? false, pro.map { deviceHelp($0) } ?? "SidePulse Pro: not reported"))
        result.append(("dot", "Dot", dot?.isPresent ?? false, dot.map { deviceHelp($0) } ?? "PulseDot: not reported"))
        let barShown = store.screenBarShown && (bar?.isPresent ?? true)
        result.append(("screen_bar", "Screen Bar", barShown, barShown ? "Screen Bar shown under the notch · click to hide" : "Screen Bar hidden · click to show"))
        return result.map { (id: $0.0, name: $0.1, present: $0.2, help: $0.3) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Devices", trailing: store.isLive ? nil : "from files")
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    DeviceChip(name: chip.name, present: chip.present, dimmed: !store.isLive && chip.id != "screen_bar")
                        .help(chip.help)
                        .onTapGesture { if chip.id == "screen_bar" { store.toggleScreenBar() } }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { store.brightness },
                    set: { store.setBrightness($0, final: false) }
                ), in: 0...1) { editing in
                    if !editing { store.setBrightness(store.brightness, final: true) }
                }
                .controlSize(.mini)
                .disabled(!store.isLive || !store.hasHardware)
                Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("\(Int((store.brightness * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .help(store.isLive ? "Strip brightness (sends set_brightness)" : "Brightness needs the core")
        }
    }

    private func deviceHelp(_ device: CoreDevice) -> String {
        var parts: [String] = [device.name ?? device.kind]
        parts.append(device.isPresent ? "connected" : "disconnected")
        if let leds = device.leds { parts.append("\(leds) LEDs") }
        if let error = device.error, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}

struct DeviceChip: View {
    let name: String
    let present: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(present ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(present ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Capsule())
        .accessibilityLabel("\(name) \(present ? "connected" : "not connected")")
    }
}

// MARK: - Footer

struct PanelFooter: View {
    @Bindable var store: PanelStore

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Clear done", dimmed: store.completedCount == 0) { store.clearCompleted() }
                .help("Acknowledge finished sessions (undo within 5 minutes from History)")
            Menu {
                Button("30 minutes") { store.quiet(minutes: 30) }
                Button("1 hour") { store.quiet(minutes: 60) }
                Button("4 hours") { store.quiet(minutes: 240) }
                Button("Until tomorrow") { store.quiet(minutes: 12 * 60) }
            } label: {
                Text("Quiet…")
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive))
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            FooterButton(title: "History", dimmed: !store.isLive, shortcut: "⌘Y") { store.openHistory() }
                .help("Activity history")
            Menu {
                Button { store.openUsageCenter() } label: { Text("Usage Center…") }
                    .keyboardShortcut("u", modifiers: .command)
                Button { store.openEffects() } label: { Text("Effect Studio…") }
                Button { store.openControlCenter() } label: { Text("Control Center…") }
                    .keyboardShortcut("k", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: Usage Center (⌘U), Effect Studio, Control Center (⌘K)")
            .accessibilityLabel("More")
            Button { store.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(FooterButtonStyle(dimmed: false))
            .help("Settings… (⌘,)")
            .accessibilityLabel("Settings")
            FooterButton(title: "Quit", dimmed: false, shortcut: "⌘Q") { store.quit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct FooterButton: View {
    let title: String
    let dimmed: Bool
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let shortcut {
                    Text(shortcut).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(FooterButtonStyle(dimmed: dimmed))
    }
}

struct FooterButtonStyle: ButtonStyle {
    let dimmed: Bool
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(dimmed ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String?
    let reduced: Bool

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                    .padding(.bottom, 40)
                    .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    .id(text)
            }
        }
        .animation(PanelMotion.contents(reduced: reduced), value: text)
        .allowsHitTesting(false)
    }
}
