import AppKit
import JRBarCore
import Observation
import SwiftUI

/// What a command row does when Enter lands. Everything routes through
/// the delegate the maintainer wires to `MenuBarUtility` — the palette
/// itself never touches settings or the bar.
enum MenuBarCommandAction: Equatable, Sendable {
    /// Assign an item a section — the card picker's write, keyed by
    /// item id.
    case setSection(itemID: String, MenuBarItemSection)
    /// Press the item through (`AXPress`, the tile click's path).
    case openItem(itemID: String)
    /// Drop the hidden run's covers for a reveal window.
    case revealHidden
    /// Every listed unprotected item → `.hidden`.
    case hideAll
    /// Clear every assignment — the "None" profile's sections.
    case showAll
    /// The physical reorder flow — hands off the mouse.
    case arrange
}

/// One row in the palette.
struct MenuBarCommand: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// The right-hand hint — the item's current section, "⌘⏎"-style
    /// hints, the mechanism the action uses.
    let detail: String
    let action: MenuBarCommandAction
}

/// The palette's contents: commands built from the live list plus the
/// fuzzy matcher that ranks them. Both pure — the list is a function
/// of items + the section map, the score of two strings — so the row
/// the person picks is fully testable without a panel.
enum MenuBarCommands {
    /// The fuzzy score of `query` against `candidate`, or nil for no
    /// match. Subsequence match, case- and space-insensitive, with
    /// bonuses that make the ranking feel right: consecutive runs,
    /// word starts (after a space, `·`, `-` or `/`), and a candidate
    /// prefix for the query's first character. Longer candidates pay a
    /// small tax so a short exact word beats a long ramble.
    nonisolated static func score(_ query: String, _ candidate: String) -> Int? {
        let qs = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !qs.isEmpty else { return 0 }
        let cs = Array(candidate.lowercased())
        var qi = 0
        var total = 0
        var lastMatch = -2
        var streak = 0
        for (i, ch) in cs.enumerated() where qi < qs.count {
            guard ch == qs[qi] else { continue }
            var pts = 2
            if i == lastMatch + 1 {
                streak += 1
                pts += 4 * streak
            } else {
                streak = 0
            }
            if i == 0 || [" ", "·", "-", "/", ":"].contains(cs[i - 1]) {
                pts += 8
            }
            if qi == 0 && i == 0 { pts += 10 }
            total += pts
            lastMatch = i
            qi += 1
        }
        guard qi == qs.count else { return nil }
        return total - cs.count / 4
    }

    /// The commands matching `query`, best score first. Ties keep
    /// build order — the list is already in bar order, so a tie reads
    /// left to right the way the bar does.
    nonisolated static func filter(_ commands: [MenuBarCommand],
                                   query: String) -> [MenuBarCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands
            .compactMap { command in
                (score(trimmed, command.title)
                 ?? score(trimmed, command.detail).map { $0 / 2 })
                    .map { (command, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// One item's display name — the card row's "Owner · Title".
    nonisolated static func name(of item: MenuBarItem) -> String {
        if let title = item.title, !title.isEmpty {
            return "\(item.ownerName) · \(title)"
        }
        return item.ownerName
    }

    /// The full command list for the live items and the persisted
    /// section map. Per-item rows come in bar order (left→right);
    /// protected items get none — the palette can no more hide the
    /// clock than the picker can.
    nonisolated static func build(items: [MenuBarItem],
                                  sections: [String: MenuBarItemSection]) -> [MenuBarCommand] {
        var out: [MenuBarCommand] = []
        for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        where !MenuBarItemLister.isProtected(item) {
            let name = name(of: item)
            let section = sections[item.id] ?? .shown
            out.append(MenuBarCommand(
                id: "open.\(item.id)", title: "Open \(name)",
                detail: "Press the item through Accessibility",
                action: .openItem(itemID: item.id)))
            if section == .shown {
                out.append(MenuBarCommand(
                    id: "hide.\(item.id)", title: "Hide \(name)",
                    detail: "Cover it behind the chevron",
                    action: .setSection(itemID: item.id, .hidden)))
            } else {
                out.append(MenuBarCommand(
                    id: "show.\(item.id)", title: "Show \(name)",
                    detail: "Back to the visible bar",
                    action: .setSection(itemID: item.id, .shown)))
            }
            if section != .alwaysHidden {
                out.append(MenuBarCommand(
                    id: "always.\(item.id)", title: "Always hide \(name)",
                    detail: "The deeper cover — the Item Bar alone reaches it",
                    action: .setSection(itemID: item.id, .alwaysHidden)))
            }
        }
        out.append(MenuBarCommand(
            id: "reveal", title: "Reveal hidden items",
            detail: "Drop the covers for a reveal window",
            action: .revealHidden))
        out.append(MenuBarCommand(
            id: "arrange", title: "Arrange menu bar items…",
            detail: "Physically reorder — keep hands off the mouse",
            action: .arrange))
        out.append(MenuBarCommand(
            id: "hideAll", title: "Hide all items",
            detail: "Every listed item behind the chevron",
            action: .hideAll))
        out.append(MenuBarCommand(
            id: "showAll", title: "Show all items",
            detail: "Clear every hiding assignment",
            action: .showAll))
        return out
    }

    /// The section map `hideAll` should write: every listed
    /// unprotected item → `.hidden`, no other keys. Protected owners
    /// are skipped — the file can never carry an assignment for the
    /// clock.
    nonisolated static func hideAllSections(items: [MenuBarItem]) -> [String: MenuBarItemSection] {
        var map: [String: MenuBarItemSection] = [:]
        for item in items where !MenuBarItemLister.isProtected(item) {
            map[item.id] = .hidden
        }
        return map
    }
}

/// The palette's mutable state — a plain model the panel hosts and the
/// coordinator drives. `query`'s didSet re-runs the pure filter and
/// drops the selection back on the top hit. `@Observable` (not
/// `@State`: the CLT toolchain lacks the SwiftUIMacros plugin, so the
/// model — not the view — owns the query).
@MainActor
@Observable
final class MenuBarCommandBarModel {
    var all: [MenuBarCommand] = []
    var query = "" { didSet { refilter() } }
    private(set) var filtered: [MenuBarCommand] = []
    private(set) var selection = 0

    func load(items: [MenuBarItem], sections: [String: MenuBarItemSection]) {
        all = MenuBarCommands.build(items: items, sections: sections)
        query = ""
        refilter()
    }

    func refilter() {
        filtered = MenuBarCommands.filter(all, query: query)
        selection = 0
    }

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { selection = 0; return }
        selection = (selection + delta + filtered.count) % filtered.count
    }

    var selected: MenuBarCommand? {
        filtered.indices.contains(selection) ? filtered[selection] : nil
    }
}

/// The palette panel: ⌘⇧K-style glass centered under the menu bar,
/// nonactivating but key-capable — the search field types without the
/// owning app stealing focus from whoever is frontmost.
@MainActor
final class MenuBarCommandPalettePanel: NSPanel {
    static let cornerRadius: CGFloat = 14
    static let width: CGFloat = 440

    init(model: MenuBarCommandBarModel,
         onSubmit: @escaping @MainActor () -> Void,
         onCancel: @escaping @MainActor () -> Void,
         onMove: @escaping @MainActor (Int) -> Void) {
        let hosting = NSHostingView(rootView: MenuBarCommandPaletteView(
            model: model, onSubmit: onSubmit, onCancel: onCancel, onMove: onMove))
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 60))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = glass
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .moveToActiveSpace]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    // The palette is the whole point of a nonactivating panel: key
    // events reach it while the frontmost app keeps focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The SwiftUI half: a plain field, a list of rows, and key handling
/// via `onKeyPress` — the hosting view is inside a key-capable panel,
/// so arrows/Enter/Esc arrive as key presses, not monitor gymnastics.
private struct MenuBarCommandPaletteView: View {
    let model: MenuBarCommandBarModel
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onMove: @MainActor (Int) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Menu Bar", text: Binding(
                get: { model.query },
                set: { model.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($fieldFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .onKeyPress(.upArrow) { onMove(-1); return .handled }
                .onKeyPress(.downArrow) { onMove(1); return .handled }
                .onKeyPress(.return) { onSubmit(); return .handled }
                .onKeyPress(.escape) { onCancel(); return .handled }
            if !model.filtered.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, command in
                                HStack {
                                    Text(command.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(command.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(index == model.selection
                                            ? Color.accentColor.opacity(0.25) : .clear)
                                .id(command.id)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selected?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: MenuBarCommandPalettePanel.width)
        .onAppear { fieldFocused = true }
    }
}

/// The coordinator the maintainer wires: providers for the items and
/// sections the palette lists, and the single `onAction` sink every
/// row lands in (via `MenuBarActions`, or the utility directly).
@MainActor
final class MenuBarCommandBar {
    /// The live item list the commands are built from.
    var items: @MainActor () -> [MenuBarItem] = { [] }
    /// The persisted section map — decides Hide vs Show, gates
    /// "Always hide".
    var sections: @MainActor () -> [String: MenuBarItemSection] = { [:] }
    /// Every Enter lands here.
    var onAction: @MainActor (MenuBarCommandAction) -> Void = { _ in }

    private let model = MenuBarCommandBarModel()
    private var panel: MenuBarCommandPalettePanel?
    private(set) var isOpen = false
    /// The system uptime at open — kept for parity with the Item Bar's
    /// dismiss rule if a click-outside monitor is later added.
    private var openedAtUptime: TimeInterval = 0

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Rebuilds the command list and presents the palette; an already
    /// open palette just re-reads the world.
    func open() {
        if isOpen { close() }
        model.load(items: items(), sections: sections())
        let panel = MenuBarCommandPalettePanel(
            model: model,
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.close() },
            onMove: { [weak self] delta in self?.model.move(delta) })
        if let screen = NSScreen.main {
            let depth = max(NSStatusBar.system.thickness,
                            ScreenBarGeometry.notchDepth(of: screen))
            let size = NSSize(width: MenuBarCommandPalettePanel.width, height: 60)
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                                  y: screen.frame.maxY - depth - 8 - size.height,
                                  width: size.width, height: size.height),
                           display: false)
            // Let the SwiftUI content settle the real height — the row
            // list can reach its 320-cap, an empty filter stays a field.
            let fitted = panel.contentView?.fittingSize ?? size
            panel.setContentSize(NSSize(width: size.width,
                                        height: max(48, fitted.height)))
            // Re-pin the top edge under the menu bar — sizing grew it.
            panel.setFrameTopLeftPoint(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - depth - 8))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isOpen = true
        openedAtUptime = ProcessInfo.processInfo.systemUptime
    }

    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
    }

    /// Enter: the selected row's action to the sink, then fold.
    private func submit() {
        guard let command = model.selected else { close(); return }
        close()
        onAction(command.action)
    }

    isolated deinit {
        panel?.orderOut(nil)
    }
}
