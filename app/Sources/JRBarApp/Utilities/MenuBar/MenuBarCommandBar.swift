import AppKit
import JRBarCore

/// What a menu-bar verb does when it runs. Everything routes through
/// the delegate the utility implements (`MenuBarActions`) — the palette
/// itself never touches settings or the bar.
enum MenuBarCommandAction: Equatable, Sendable {
    /// Assign one item a section — the card picker's write, keyed by
    /// item id.
    case setSection(itemID: String, MenuBarItemSection)
    /// Assign an app's whole row a section: every item id the row
    /// stands for. Under the concealer the first write already hides
    /// the app; the rest keep an Apple extra's per-item cover in step.
    case setAppSection(itemIDs: [String], MenuBarItemSection)
    /// Press the item through (`AXPress`, the tile click's path).
    case openItem(itemID: String)
    /// Bring the hidden run back on the re-hide clock.
    case revealHidden
    /// The same for the always-hidden run.
    case revealAlwaysHidden
    /// The ‹'s own toggle: the Item Bar or the inline reveal, as set.
    case toggleHidden
    /// Every listed app hidden.
    case hideAll
    /// Every app shown, and kept that way.
    case showAll
    /// The physical reorder flow — drags the pointer. Offered only on
    /// the spacer engine; under the concealer macOS orders the bar.
    case arrange
    /// A saved profile, or `MenuBarProfiles.noneID`.
    case applyProfile(id: String)
    /// The live layout saved under a name — a same-named profile is
    /// updated in place, as the card's Save does. Built with an empty
    /// name; the typed words fill it (`filled(with:)`).
    case saveProfile(name: String)
    /// A saved profile renamed to the typed words.
    case renameProfile(id: String, name: String)
    /// A rule's action, now — Bartender's "run now".
    case runRule(id: String)
    case setRuleEnabled(id: String, Bool)
    /// The Utilities settings page — the parked palette's one menu-bar
    /// row, where the utility switches back on.
    case openSettings
}

extension MenuBarCommandAction {
    /// The action with the typed words as its name — the profile verbs
    /// that ask for one; every other action is returned as it is.
    func filled(with text: String) -> MenuBarCommandAction {
        switch self {
        case .saveProfile: return .saveProfile(name: text)
        case .renameProfile(let id, _): return .renameProfile(id: id, name: text)
        default: return self
        }
    }
}

/// The words a menu-bar verb waits for: a profile's name.
struct MenuBarCommandInput: Equatable, Sendable {
    let prompt: String
    let submitTitle: String
    var initial = ""
    /// The saved names, so the HUD can say "updated" for a name that
    /// already exists rather than "saved" for a profile that is new.
    var existingNames: [String] = []
}

/// One verb on a menu-bar row.
struct MenuBarCommandVerb: Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let action: MenuBarCommandAction
    var shortcut: PaletteShortcut?
    /// The HUD line after it runs; nil where the result shows itself.
    var confirmation: String?
    /// A verb that asks for words first; `action` is filled with them.
    var input: MenuBarCommandInput?
}

/// One menu-bar row: an app (every item it owns), a bar-wide command,
/// a profile or a rule.
struct MenuBarCommand: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case app, command, profile, rule }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    /// An app row's section — what its tag says and which verbs it
    /// gets. nil for everything else.
    var section: MenuBarItemSection?
    /// An app row's icon lookup.
    var ownerPID: Int32?
    var bundleID: String?
    /// A command row's symbol.
    var symbol = "menubar.rectangle"
    var tint: PaletteTint = .gray
    var keywords: [String] = []
    /// A tag beyond the section's — a rule's "Off", the live profile's
    /// "Current".
    var note: String?
    /// In order: the first runs on Return, the second on ⌘Return.
    var verbs: [MenuBarCommandVerb]
}

/// The palette's menu-bar rows, built from the live listing and the
/// persisted maps, plus the fuzzy matcher every JR-Bar list shares.
/// Pure: the rows are a function of items, sections, the engine and
/// the saved profiles and rules — so the row the person picks is fully
/// testable without a panel.
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

    /// One item's display name — the card row's "Owner · Title".
    nonisolated static func name(of item: MenuBarItem) -> String {
        if let title = item.title, !title.isEmpty {
            return "\(item.ownerName) · \(title)"
        }
        return item.ownerName
    }

    /// The key an app's items share: its bundle, or — for a bare helper
    /// with none — its process name.
    nonisolated static func appKey(of item: MenuBarItem) -> String {
        item.bundleID ?? "owner:\(item.ownerName)"
    }

    /// Every row, in list order: one per app (left→right, the bar's
    /// order), then the bar-wide commands, then profiles and rules.
    ///
    /// An app is one row however many items it owns — the concealer
    /// hides whole apps, so a row per item promised a choice the
    /// engine cannot make. Items of one app in different sections (the
    /// spacer engine's per-item covers) split into one row per
    /// section, so a row's Hide or Show is always true of everything
    /// it stands for. Protected items (clock, Control Center) and our
    /// own family get no row: the palette can no more hide the clock
    /// than the picker can.
    nonisolated static func build(items: [MenuBarItem],
                                  sections: [String: MenuBarItemSection],
                                  concealing: Bool = false,
                                  profiles: [MenuBarSettings.Profile] = [],
                                  activeProfileID: String? = nil,
                                  rules: [MenuBarTriggerRule] = [],
                                  ownBundleID: String? = Bundle.main.bundleIdentifier) -> [MenuBarCommand] {
        var groups: [(key: String, section: MenuBarItemSection, items: [MenuBarItem])] = []
        for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        where !MenuBarItemLister.isProtected(item) && !item.ownerName.isEmpty
            && !isOwn(item.bundleID, own: ownBundleID) {
            let key = appKey(of: item)
            let section = sections[item.id] ?? .shown
            if let index = groups.firstIndex(where: { $0.key == key && $0.section == section }) {
                groups[index].items.append(item)
            } else {
                groups.append((key, section, [item]))
            }
        }
        let splitKeys = Set(Dictionary(grouping: groups, by: \.key).filter { $0.value.count > 1 }.keys)
        var out = groups.map { group in
            appRow(key: group.key, section: group.section, items: group.items,
                   split: splitKeys.contains(group.key))
        }
        out += commandRows(concealing: concealing)
        out += profileRows(profiles, active: activeProfileID)
        out += rules.map(ruleRow)
        return out
    }

    nonisolated static func isOwn(_ bundleID: String?, own: String?) -> Bool {
        guard let bundleID, let own else { return false }
        return bundleID == own || bundleID.hasPrefix(own + ".")
    }

    /// One app's row. Return opens its (first) item's menu; ⌘Return
    /// flips it between shown and hidden; ⌘⇧H hides it for good.
    nonisolated static func appRow(key: String, section: MenuBarItemSection,
                                   items: [MenuBarItem], split: Bool = false) -> MenuBarCommand {
        let first = items[0]
        let name = first.ownerName
        let ids = items.map(\.id)
        let titles = items.compactMap { $0.title?.isEmpty == false ? $0.title : nil }
        var subtitle: String?
        if titles.count == items.count, !titles.isEmpty {
            subtitle = titles.joined(separator: " · ")
        } else if items.count > 1 {
            subtitle = "\(items.count) items"
        }
        var verbs: [MenuBarCommandVerb] = [
            MenuBarCommandVerb(id: "open", title: items.count > 1 ? "Open \(titles.first ?? "Menu")" : "Open",
                               symbol: "filemenu.and.selection", action: .openItem(itemID: first.id)),
        ]
        switch section {
        case .shown:
            verbs.append(MenuBarCommandVerb(
                id: "hide", title: "Hide", symbol: "eye.slash",
                action: .setAppSection(itemIDs: ids, .hidden), confirmation: "\(name) hidden"))
            verbs.append(MenuBarCommandVerb(
                id: "always", title: "Always Hide", symbol: "eye.slash.circle",
                action: .setAppSection(itemIDs: ids, .alwaysHidden),
                shortcut: .commandShift("h"), confirmation: "\(name) always hidden"))
        case .hidden:
            verbs.append(MenuBarCommandVerb(
                id: "show", title: "Show", symbol: "eye",
                action: .setAppSection(itemIDs: ids, .shown), confirmation: "\(name) shown"))
            verbs.append(MenuBarCommandVerb(
                id: "always", title: "Always Hide", symbol: "eye.slash.circle",
                action: .setAppSection(itemIDs: ids, .alwaysHidden),
                shortcut: .commandShift("h"), confirmation: "\(name) always hidden"))
        case .alwaysHidden:
            verbs.append(MenuBarCommandVerb(
                id: "show", title: "Show", symbol: "eye",
                action: .setAppSection(itemIDs: ids, .shown), confirmation: "\(name) shown"))
            verbs.append(MenuBarCommandVerb(
                id: "hide", title: "Move to Hidden", symbol: "eye.slash",
                action: .setAppSection(itemIDs: ids, .hidden),
                confirmation: "\(name) hidden, back on reveal"))
        }
        // An app with several items: each one's own menu, by name.
        for (index, item) in items.enumerated().dropFirst() {
            let label = item.title?.isEmpty == false ? item.title! : "Item \(index + 1)"
            verbs.append(MenuBarCommandVerb(id: "open.\(item.id)", title: "Open \(label)",
                                            symbol: "filemenu.and.selection",
                                            action: .openItem(itemID: item.id)))
        }
        return MenuBarCommand(
            id: "menubar.app.\(key)" + (split ? ".\(section.rawValue)" : ""),
            kind: .app, title: name, subtitle: subtitle, section: section,
            ownerPID: first.ownerPID, bundleID: first.bundleID,
            keywords: first.bundleID.map { [$0] } ?? [], verbs: verbs)
    }

    /// The bar-wide commands. Arrange is the app's only synthetic
    /// pointer input and cannot deliver under the concealer — macOS
    /// orders the bar itself on 27 — so it is offered only while the
    /// spacer engine runs.
    nonisolated static func commandRows(concealing: Bool) -> [MenuBarCommand] {
        var rows = [
            MenuBarCommand(
                id: "menubar.reveal", kind: .command, title: "Reveal Hidden Items",
                subtitle: "The hidden apps, back until the re-hide clock runs out",
                symbol: "eye", tint: .blue, keywords: ["peek", "show hidden"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Reveal", symbol: "eye",
                                           action: .revealHidden)]),
            MenuBarCommand(
                id: "menubar.revealAlways", kind: .command, title: "Reveal Always-Hidden Items",
                subtitle: "The deeper set, on the same clock",
                symbol: "eye.circle", tint: .indigo, keywords: ["peek", "always hidden"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Reveal", symbol: "eye.circle",
                                           action: .revealAlwaysHidden)]),
            MenuBarCommand(
                id: "menubar.toggle", kind: .command, title: "Toggle Hidden Items",
                subtitle: "What the ‹ does — the Item Bar, or the inline reveal",
                symbol: "chevron.left.2", tint: .blue, keywords: ["item bar", "chevron"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Toggle", symbol: "chevron.left.2",
                                           action: .toggleHidden)]),
            MenuBarCommand(
                id: "menubar.hideAll", kind: .command, title: "Hide All Apps",
                subtitle: "Everything but the clock and Control Center",
                symbol: "eye.slash", tint: .gray, keywords: ["declutter", "tidy"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Hide All", symbol: "eye.slash",
                                           action: .hideAll, confirmation: "All apps hidden")]),
            MenuBarCommand(
                id: "menubar.showAll", kind: .command, title: "Show All Apps",
                subtitle: "Every app back on the bar, and kept there",
                symbol: "eye", tint: .gray, keywords: ["unhide", "restore"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Show All", symbol: "eye",
                                           action: .showAll, confirmation: "All apps shown")]),
        ]
        if !concealing {
            rows.append(MenuBarCommand(
                id: "menubar.arrange", kind: .command, title: "Arrange Menu Bar Items…",
                subtitle: "⌘-drags items into your saved order — the pointer moves",
                symbol: "arrow.left.arrow.right", tint: .gray, keywords: ["reorder", "sort"],
                verbs: [MenuBarCommandVerb(id: "run", title: "Arrange", symbol: "arrow.left.arrow.right",
                                           action: .arrange)]))
        }
        return rows
    }

    /// The parked utility's one row. ⌘⇧K still opens the palette with
    /// the Menu Bar utility off or handed to Bartender, Ice or Hidden
    /// Bar, but nothing on the bar answers JR-Bar then: a Hide would
    /// write maps no engine reads while the HUD said it worked, a
    /// reveal would poke a stopped clock, and Arrange would drag the
    /// pointer for nobody. So the verbs wait, and the row says where
    /// the utility switches back on.
    nonisolated static func parkedRows() -> [MenuBarCommand] {
        [MenuBarCommand(
            id: "menubar.off", kind: .command, title: "Menu Bar Utility Is Off",
            subtitle: "Off or handed to another app — hiding, profiles and rules wait for it",
            symbol: "menubar.rectangle", tint: .gray,
            keywords: ["hide", "reveal", "show", "profile", "rule", "arrange",
                       "bartender", "ice", "hidden bar"],
            verbs: [MenuBarCommandVerb(id: "settings", title: "Open Utilities Settings",
                                       symbol: "gearshape", action: .openSettings)])]
    }

    /// The built-in "None" first, then the saved profiles in the card's
    /// order — each renameable by name — and last, saving the live
    /// layout as one. The subtitle says what a profile hides; the one
    /// the bar is wearing now is tagged Current.
    nonisolated static func profileRows(_ profiles: [MenuBarSettings.Profile],
                                        active: String? = nil) -> [MenuBarCommand] {
        var rows = [MenuBarCommand(
            id: "menubar.profile.\(MenuBarProfiles.noneID)", kind: .profile,
            title: MenuBarProfiles.noneName, subtitle: "Built in — every app shown, the default look",
            symbol: "rectangle.dashed", tint: .gray, keywords: ["no profile", "reset layout"],
            note: active == MenuBarProfiles.noneID ? "Current" : nil,
            verbs: [MenuBarCommandVerb(id: "apply", title: "Apply Profile", symbol: "checkmark.circle",
                                       action: .applyProfile(id: MenuBarProfiles.noneID),
                                       confirmation: "No profile — every app shown")])]
        for profile in profiles {
            let hidden = profile.concealedApps.values.filter { $0 != .shown }.count
                + profile.sections.values.filter { $0 != .shown }.count
            rows.append(MenuBarCommand(
                id: "menubar.profile.\(profile.id)", kind: .profile, title: profile.name,
                subtitle: hidden == 0 ? "Hides nothing" : "Hides \(hidden) \(hidden == 1 ? "app" : "apps")",
                symbol: "rectangle.3.group", tint: .purple, keywords: ["menu bar profile", "layout"],
                note: active == profile.id ? "Current" : nil,
                verbs: [
                    MenuBarCommandVerb(id: "apply", title: "Apply Profile", symbol: "checkmark.circle",
                                       action: .applyProfile(id: profile.id),
                                       confirmation: "Profile “\(profile.name)” applied"),
                    MenuBarCommandVerb(id: "rename", title: "Rename…", symbol: "pencil",
                                       action: .renameProfile(id: profile.id, name: ""),
                                       input: MenuBarCommandInput(prompt: "Rename “\(profile.name)”…",
                                                                  submitTitle: "Rename",
                                                                  initial: profile.name)),
                ]))
        }
        rows.append(MenuBarCommand(
            id: "menubar.profile.save", kind: .profile, title: "Save Layout as Profile…",
            subtitle: "What hides and how the bar looks, kept under a name",
            symbol: "square.and.arrow.down", tint: .purple,
            keywords: ["new profile", "save profile", "preset", "menu bar profile"],
            verbs: [MenuBarCommandVerb(
                id: "save", title: "Save as Profile…", symbol: "square.and.arrow.down",
                action: .saveProfile(name: ""),
                input: MenuBarCommandInput(prompt: "Name this layout…", submitTitle: "Save Profile",
                                           existingNames: profiles.map(\.name)))]))
        return rows
    }

    /// Whether `text` works as what the action asks for — a profile's
    /// name, by the card's own rule.
    nonisolated static func accepts(_ text: String, for action: MenuBarCommandAction) -> Bool {
        switch action {
        case .saveProfile, .renameProfile: return MenuBarProfiles.validName(text) != nil
        default: return true
        }
    }

    /// The HUD line once typed words have filled an action.
    nonisolated static func confirmation(for action: MenuBarCommandAction,
                                         existingNames: [String] = []) -> String? {
        switch action {
        case .saveProfile(let name):
            let updates = existingNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            return updates ? "Profile “\(name)” updated" : "Profile “\(name)” saved"
        case .renameProfile(_, let name):
            return "Renamed to “\(name)”"
        default:
            return nil
        }
    }

    /// A rule reads as its own sentence. Return runs its action now;
    /// ⌘Return switches it on or off.
    nonisolated static func ruleRow(_ rule: MenuBarTriggerRule) -> MenuBarCommand {
        let summary = rule.summary
        let title = summary.prefix(1).uppercased() + summary.dropFirst()
        return MenuBarCommand(
            id: "menubar.rule.\(rule.id)", kind: .rule, title: title,
            symbol: "bolt.fill", tint: rule.enabled ? .orange : .gray,
            keywords: ["rule", "trigger", "automation"],
            note: rule.enabled ? nil : "Off",
            verbs: [
                MenuBarCommandVerb(id: "run", title: "Run Now", symbol: "play.fill",
                                   action: .runRule(id: rule.id), confirmation: "Rule ran"),
                rule.enabled
                    ? MenuBarCommandVerb(id: "toggle", title: "Turn Off", symbol: "pause.circle",
                                         action: .setRuleEnabled(id: rule.id, false),
                                         confirmation: "Rule off")
                    : MenuBarCommandVerb(id: "toggle", title: "Turn On", symbol: "bolt.circle",
                                         action: .setRuleEnabled(id: rule.id, true),
                                         confirmation: "Rule on"),
            ])
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

extension MenuBarCommand {
    /// The row as the palette draws it: menu-bar apps and commands under
    /// Menu Bar, profiles and rules under Profiles & Rules. Every verb
    /// lands in `perform`.
    @MainActor
    func paletteItem(perform: @escaping @MainActor (MenuBarCommandAction) -> Void) -> PaletteItem {
        var tags: [PaletteTag] = []
        switch section {
        case .hidden: tags.append(PaletteTag(text: "Hidden"))
        case .alwaysHidden: tags.append(PaletteTag(text: "Always Hidden"))
        case .shown, nil: break
        }
        if let note { tags.append(PaletteTag(text: note, tone: note == "Current" ? .accent : .neutral)) }
        let icon: PaletteIcon = kind == .app
            ? .app(pid: ownerPID ?? 0, bundleID: bundleID)
            : .symbol(symbol, tint)
        let kindWord: String
        switch kind {
        case .app: kindWord = "Menu Bar App"
        case .command: kindWord = "Menu Bar"
        case .profile: kindWord = "Profile"
        case .rule: kindWord = "Rule"
        }
        return PaletteItem(
            id: id, title: title, subtitle: subtitle, keywords: keywords, icon: icon,
            tags: tags, kind: kindWord,
            section: kind == .profile || kind == .rule ? .automation : .menuBar,
            actions: verbs.map { verb in
                guard let input = verb.input else {
                    return PaletteAction(id: verb.id, title: verb.title, symbol: verb.symbol,
                                         shortcut: verb.shortcut) {
                        perform(verb.action)
                        return verb.confirmation
                    }
                }
                return PaletteAction(
                    id: verb.id, title: verb.title, symbol: verb.symbol, shortcut: verb.shortcut,
                    input: PaletteInput(
                        prompt: input.prompt, submitTitle: input.submitTitle,
                        initial: { input.initial },
                        accepts: { MenuBarCommands.accepts($0, for: verb.action) },
                        submit: { words in
                            let filled = verb.action.filled(with: words)
                            perform(filled)
                            return MenuBarCommands.confirmation(for: filled, existingNames: input.existingNames)
                        }))
            })
    }
}

/// The ⌘⇧K entry point: the hotkey and the utility card's button both
/// toggle this, and it opens JR-Bar's one palette —
/// the menu bar's own rows plus every source the app delegate
/// registers (sessions, asks, quiet, lights, Control Center, the
/// archive…). The inputs are closures the actions facade wires to the
/// utility, so the rows are always the utility's truth at the
/// keystroke.
@MainActor
final class MenuBarCommandBar {
    /// The live item list the app rows are built from.
    var items: @MainActor () -> [MenuBarItem] = { [] }
    /// The effective section map — decides each app's Hide or Show.
    var sections: @MainActor () -> [String: MenuBarItemSection] = { [:] }
    /// Whether the utility runs. Parked, the listing and maps are the
    /// card's leftovers, so the rows built from them would lie.
    var running: @MainActor () -> Bool = { true }
    /// Whether the concealer runs — Arrange's row hides while it does.
    var concealing: @MainActor () -> Bool = { false }
    var profiles: @MainActor () -> [MenuBarSettings.Profile] = { [] }
    /// The profile the bar wears now — its row is tagged Current.
    var activeProfileID: @MainActor () -> String? = { nil }
    var rules: @MainActor () -> [MenuBarTriggerRule] = { [] }
    /// Every menu-bar verb lands here.
    var onAction: @MainActor (MenuBarCommandAction) -> Void = { _ in }
    /// The Utilities settings page, as the app delegate opens it.
    var openSettings: @MainActor () -> Void = {}
    /// The rest of JR-Bar's rows, registered once by the app delegate.
    var sources: [any PaletteSource] = []

    let palette = PaletteController()

    var isOpen: Bool { palette.isOpen }

    init() {
        palette.sources = { [weak self] in
            guard let self else { return [] }
            return [PaletteClosureSource { [weak self] in self?.menuBarItems() ?? [] }] + self.sources
        }
    }

    /// The menu bar's rows at this moment.
    func menuBarItems() -> [PaletteItem] {
        let commands = running()
            ? MenuBarCommands.build(items: items(), sections: sections(), concealing: concealing(),
                                    profiles: profiles(), activeProfileID: activeProfileID(), rules: rules())
            : MenuBarCommands.parkedRows()
        return commands
            .map { command in
                command.paletteItem { [weak self] action in self?.onAction(action) }
            }
    }

    func toggle() { palette.toggle() }
    func open() { palette.open() }
    func close() { palette.close() }
}
