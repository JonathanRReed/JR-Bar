import AppKit
import JRBarCore
import SwiftUI

/// The palette's SwiftUI half, Raycast's layout on JR-Bar's glass: a
/// search field, one list of sectioned rows (icon, title, a quiet
/// subtitle, state tags and the row's kind), and a footer that always
/// says what Return does and that ⌘K has more. The ⌘K action panel
/// floats over the list's bottom-right corner with its own filter.
///
/// Keys never land here: the controller's local monitor routes arrows,
/// Return, ⎋ and every chord through `PaletteKeys` before the text
/// field sees them, so this view only draws and forwards clicks.
struct PaletteView: View {
    let model: PaletteModel
    /// The field's placeholder.
    let prompt: String
    let onQueryChange: @MainActor () -> Void
    /// A click on a row: select it and run its first verb.
    let onActivate: @MainActor (String) -> Void
    /// A verb picked from the action panel, the context menu, or
    /// VoiceOver's actions rotor — row id, action id.
    let onRun: @MainActor (String, String) -> Void
    let onToggleActions: @MainActor () -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case search, actions }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            ZStack(alignment: .bottomTrailing) {
                list
                if model.actionsOpen, let item = model.selected {
                    PaletteActionPanel(model: model, item: item, focus: $focus,
                                       onRun: { onRun(item.id, $0) })
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: PalettePanel.width, height: PalettePanel.height)
        .onAppear { focus = .search }
        .onChange(of: model.actionsOpen) { _, open in focus = open ? .actions : .search }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: Binding(
                get: { model.query },
                set: { model.query = $0; onQueryChange() }),
                      prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focus, equals: .search)
                .accessibilityLabel("Search JR-Bar")
            if let selected = model.selected, model.actionsOpen {
                // Raycast's breadcrumb: the panel is about this row.
                Text(selected.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            Text(section.section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.items) { item in
                                PaletteRowView(item: item, selected: item.id == model.selectedID)
                                    .id(item.id)
                                    .onTapGesture { onActivate(item.id) }
                                    .contextMenu {
                                        ForEach(item.actions) { action in
                                            Button(action.title) { onRun(item.id, action.id) }
                                        }
                                    }
                                    .accessibilityActions {
                                        ForEach(item.actions) { action in
                                            Button(action.title) { onRun(item.id, action.id) }
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selectedID) { _, id in
                    // Minimal scroll: the selection stays wholly visible
                    // without re-centring the list on every arrow.
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.searching ? "archivebox" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.searching ? "Searching the archive…" : "No results")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if !model.searching {
                Text("Try an app, a session, or a verb — “hide”, “quiet”, “scene”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(model.selected?.section.title ?? "JR-Bar")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let item = model.selected, !model.actionsOpen {
                if let primary = item.primary {
                    PaletteFooterButton(title: primary.title, caps: PaletteShortcut.primary.keycaps) {
                        onRun(item.id, primary.id)
                    }
                } else if item.opensActions {
                    PaletteFooterButton(title: "Show Actions", caps: PaletteShortcut.primary.keycaps,
                                 action: onToggleActions)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 14)
            }
            PaletteFooterButton(title: model.actionsOpen ? "Close Actions" : "Actions",
                         caps: PaletteShortcut.actionPanel.keycaps,
                         action: onToggleActions)
                .disabled(model.selected?.actions.isEmpty ?? true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

/// One row: icon, title, subtitle, tags, kind — Raycast's list item.
struct PaletteRowView: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            PaletteIconView(icon: item.icon, size: 22)
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                }
            }
            Spacer(minLength: 12)
            ForEach(item.tags, id: \.self) { tag in
                PaletteTagView(tag: tag)
            }
            Text(item.kind)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.1) : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var parts = [item.title]
        if let subtitle = item.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        parts += item.tags.map(\.text)
        if let note = item.accessibilityNote { parts.append(note) }
        parts.append(item.kind)
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if let primary = item.primary {
            return "Return to \(primary.title.lowercased()). Command K for all actions."
        }
        return item.opensActions ? "Return for the actions." : ""
    }
}

/// A row's leading mark, 22 pt: an app's own icon, a provider's tile,
/// or an SF Symbol in white on a tinted tile — System Settings'
/// sidebar grammar, which is also Raycast's.
struct PaletteIconView: View {
    let icon: PaletteIcon
    var size: CGFloat = 22

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name, let tint):
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(tint.color.gradient)
                    Image(systemName: name)
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.white)
                }
            case .app(let pid, let bundleID):
                Image(nsImage: PaletteAppIcons.icon(pid: pid, bundleID: bundleID))
                    .resizable()
                    .interpolation(.high)
            case .provider(let id):
                ProviderTile(style: ProviderStyle.style(for: id), size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A state word on the right of a row.
struct PaletteTagView: View {
    let tag: PaletteTag

    var body: some View {
        Text(tag.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tag.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tag.tone.color))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tag.tone == .neutral
                                       ? Color.primary.opacity(0.07)
                                       : tag.tone.color.opacity(0.16)))
    }
}

/// The ⌘K panel: the row's verbs with their chords, filterable.
struct PaletteActionPanel: View {
    let model: PaletteModel
    let item: PaletteItem
    var focus: FocusState<PaletteView.Field?>.Binding
    let onRun: @MainActor (String) -> Void

    var body: some View {
        let actions = model.visibleActions
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if actions.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            actionRow(action, selected: index == model.actionSelection)
                                .onTapGesture { onRun(action.id) }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 250)
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            TextField("", text: Binding(get: { model.actionQuery }, set: { model.actionQuery = $0 }),
                      prompt: Text("Search for actions…"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus, equals: .actions)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .accessibilityLabel("Search actions for \(item.title)")
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(item.title)")
    }

    private func actionRow(_ action: PaletteAction, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let chord = item.shortcut(for: action) {
                PaletteKeycaps(caps: chord.keycaps)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.1) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityValue(item.shortcut(for: action)?.spoken ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// ⌘ K drawn as small key tops.
struct PaletteKeycaps: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, cap.count > 1 ? 4 : 0)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A footer verb: its title and its keycaps, clickable.
private struct PaletteFooterButton: View {
    let title: String
    let caps: [String]
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                PaletteKeycaps(caps: caps)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The HUD's face: a symbol and one line on glass, the confirmation a
/// verb leaves behind after the palette folds.
struct PaletteHUDView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: PaletteHUD.height)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension PaletteTint {
    var color: Color {
        switch self {
        case .gray: return Color(nsColor: .systemGray)
        case .blue: return Color(nsColor: .systemBlue)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        case .green: return Color(nsColor: .systemGreen)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .teal: return Color(nsColor: .systemTeal)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .yellow: return Color(nsColor: .systemYellow)
        case .mint: return Color(nsColor: .systemMint)
        case .brown: return Color(nsColor: .systemBrown)
        case .provider(let id): return ProviderStyle.style(for: id).accent
        }
    }
}

extension PaletteTag.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .attention: return .orange
        case .alert: return .red
        case .positive: return .green
        }
    }
}

/// App icons for the menu-bar rows, looked up once per palette open —
/// `NSRunningApplication` and LaunchServices are a lookup each, never
/// something to pay per frame.
@MainActor
enum PaletteAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(pid: Int32, bundleID: String?) -> NSImage {
        let key = bundleID ?? "pid:\(pid)"
        if let cached = cache[key] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
            ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[key] = image
        return image
    }

    /// Dropped on close — a relaunched app may have a new icon.
    static func reset() { cache = [:] }
}
