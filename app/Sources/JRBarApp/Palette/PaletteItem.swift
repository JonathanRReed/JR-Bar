import Foundation
import JRBarCore

/// The ⌘⇧K palette's grammar, Raycast's: every row is one *thing* (an
/// app in the menu bar, a session, a quiet preset, a scene) with an
/// ordered list of verbs. Return runs the first verb, ⌘Return the
/// second, ⌘K lists them all, and a verb may carry its own shortcut.
/// The palette itself never knows what a verb does — sources build
/// rows from live state and hand over closures, so the menu bar, the
/// daemon and the toys each keep their own write paths.

/// A group of rows. `order` places the section in the empty-query list;
/// with a query the palette ranks one flat list and sections only
/// label a row's kind.
struct PaletteSection: Hashable, Sendable {
    let id: String
    let title: String
    let order: Int

    /// Open asks — always first, because they are costing you time.
    static let needsYou = PaletteSection(id: "needsYou", title: "Needs You", order: 0)
    /// The rows you pinned, in the order you pinned them.
    static let favorites = PaletteSection(id: "favorites", title: "Favorites", order: 1)
    /// The frecency pick: what you run most, lately.
    static let suggestions = PaletteSection(id: "suggestions", title: "Suggestions", order: 1)
    /// A query's ranked matches.
    static let results = PaletteSection(id: "results", title: "Results", order: 2)
    static let sessions = PaletteSection(id: "sessions", title: "Sessions", order: 10)
    static let menuBar = PaletteSection(id: "menuBar", title: "Menu Bar", order: 20)
    static let quiet = PaletteSection(id: "quiet", title: "Quiet", order: 30)
    static let lights = PaletteSection(id: "lights", title: "Lights", order: 40)
    static let controlCenter = PaletteSection(id: "controlCenter", title: "Control Center", order: 50)
    static let usage = PaletteSection(id: "usage", title: "Usage", order: 55)
    static let automation = PaletteSection(id: "automation", title: "Profiles & Rules", order: 60)
    /// Feed the Tank, the tank itself, Confetti.
    static let toys = PaletteSection(id: "toys", title: "Toys", order: 70)
    static let open = PaletteSection(id: "open", title: "Open", order: 80)
    static let settings = PaletteSection(id: "settings", title: "Settings", order: 90)
    /// Data Hoarder's full-text hits — searched only once you type,
    /// listed after everything the palette already knew.
    static let archive = PaletteSection(id: "archive", title: "Archive", order: 100)
}

/// The colour a row's icon tile takes. System palette names rather than
/// hexes, so the tiles follow the accent and contrast settings the way
/// System Settings' sidebar does.
enum PaletteTint: Hashable, Sendable {
    case gray, blue, orange, red, green, purple, pink, teal, indigo, yellow, mint, brown
    /// A provider's own accent, through `ProviderStyle`.
    case provider(String)
}

/// A row's leading mark.
enum PaletteIcon: Hashable, Sendable {
    /// An SF Symbol on a tinted tile.
    case symbol(String, PaletteTint)
    /// A running app's own icon — the menu-bar rows. The pid is the
    /// cheap lookup; the bundle id answers once the app has relaunched.
    case app(pid: Int32, bundleID: String?)
    /// A provider's tile, the one the panel's session rows wear.
    case provider(String)
}

/// A small word on the right of a row — a state, never a sentence.
struct PaletteTag: Hashable, Sendable {
    enum Tone: Hashable, Sendable {
        case neutral
        /// The app's accent: the live scene, the current mode.
        case accent
        /// Amber — waiting on you.
        case attention
        /// Red — failed.
        case alert
        /// Green — on, done.
        case positive
    }

    let text: String
    var tone: Tone = .neutral
}

/// A key chord a verb answers to while the palette is up. Only what a
/// palette needs: a character or Return/Delete plus the four modifiers.
struct PaletteShortcut: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        /// A character key, stored lowercased — the chord is matched on
        /// `charactersIgnoringModifiers`, so ⇧ never changes the letter.
        case character(Character)
        case returnKey
        case delete
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let key: Key
    let modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers = []) {
        if case .character(let c) = key {
            self.key = .character(Character(c.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    static func command(_ c: Character) -> PaletteShortcut { PaletteShortcut(.character(c), .command) }
    static func commandShift(_ c: Character) -> PaletteShortcut {
        PaletteShortcut(.character(c), [.command, .shift])
    }

    /// Return — the row's first verb.
    static let primary = PaletteShortcut(.returnKey)
    /// ⌘Return — the row's second verb.
    static let secondary = PaletteShortcut(.returnKey, .command)
    /// ⌘K — the action panel.
    static let actionPanel = PaletteShortcut.command("k")

    /// The keycaps the footer and the action panel draw, menu order:
    /// ⌃ ⌥ ⇧ ⌘ then the key.
    var keycaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        switch key {
        case .character(let c): caps.append(String(c).uppercased())
        case .returnKey: caps.append("↩")
        case .delete: caps.append("⌫")
        }
        return caps
    }

    /// "⌘⇧H" — the one-string form, for VoiceOver and tests.
    var display: String { keycaps.joined() }

    /// The words VoiceOver reads: "Command Shift H".
    var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        switch key {
        case .character(let c): words.append(String(c).uppercased())
        case .returnKey: words.append("Return")
        case .delete: words.append("Delete")
        }
        return words.joined(separator: " ")
    }
}

/// The words a verb waits for before it runs — Raycast's argument. The
/// palette's field turns into this verb's field (the row stays in view
/// as the context), Return hands the words over, ⎋ backs out to the
/// list with the query as it was.
struct PaletteInput {
    /// The field's placeholder while it waits: "Reply to fix-ci…".
    let prompt: String
    /// Return's name in the footer: "Send Reply".
    let submitTitle: String
    /// What the field starts with, read when the verb opens — a draft
    /// some other surface kept — so a builder never reads it under the
    /// palette's observation.
    var initial: @MainActor () -> String = { "" }
    /// Every edit, so a half-typed line outlives a fold.
    var onChange: (@MainActor (String) -> Void)?
    /// Whether the trimmed words can be sent — a name the store would
    /// refuse keeps the field open and Send dimmed, rather than folding
    /// on a claim that did not land.
    var accepts: @MainActor (String) -> Bool = { _ in true }
    /// Runs with the trimmed, non-empty, accepted words. The returned
    /// line is the HUD's, as `PaletteAction.run`'s is.
    let submit: @MainActor (String) -> String?
}

/// One verb on a row.
struct PaletteAction: Identifiable {
    let id: String
    let title: String
    /// The action panel's leading symbol.
    let symbol: String
    /// Its own chord, beyond the ↩ / ⌘↩ the row's order gives the first
    /// two verbs.
    var shortcut: PaletteShortcut?
    /// Drawn in red in the action panel — a verb that throws something
    /// away or says no.
    var isDestructive = false
    /// A verb about the palette itself (pin a favorite): it runs with
    /// the palette still up, and the list redraws around it.
    var keepsOpen = false
    /// A verb that needs words first. Picking it opens its field rather
    /// than running; `input.submit` is the run.
    var input: PaletteInput?
    /// Runs the verb. The returned line, if any, is the confirmation the
    /// palette's HUD shows after it folds ("1Password hidden"); nil for
    /// a verb whose result is its own proof (a menu opening, a window
    /// raising).
    let run: @MainActor () -> String?

    init(id: String, title: String, symbol: String, shortcut: PaletteShortcut? = nil,
         isDestructive: Bool = false, keepsOpen: Bool = false,
         run: @escaping @MainActor () -> String?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.keepsOpen = keepsOpen
        self.run = run
    }

    /// A verb that asks for a line of words before it runs.
    init(id: String, title: String, symbol: String, shortcut: PaletteShortcut? = nil,
         input: PaletteInput) {
        self.init(id: id, title: title, symbol: symbol, shortcut: shortcut) { nil }
        self.input = input
    }
}

/// One row.
struct PaletteItem: Identifiable {
    /// Stable across opens and launches — the frecency key. Built from
    /// what the row is (`menubar.app.<bundle>`, `quiet.1h`), never its
    /// title.
    let id: String
    var title: String
    var subtitle: String?
    /// Words the fuzzy match also reads ("caffeinate" finds Keep Awake).
    var keywords: [String] = []
    var icon: PaletteIcon
    var tags: [PaletteTag] = []
    /// The row's kind, drawn quietly on the right ("Menu Bar App",
    /// "Session", "Command").
    var kind: String
    var section: PaletteSection
    /// In order: the first is Return, the second ⌘Return.
    var actions: [PaletteAction]
    /// An open ask: listed under Needs You, ahead of the suggestions.
    var urgent = false
    /// A row that is only a menu (Brightness): Return opens the action
    /// panel instead of running a verb nobody chose.
    var opensActions = false
    /// The line VoiceOver adds after the title, when the row's tags and
    /// subtitle do not already say what matters.
    var accessibilityNote: String?

    /// The verb Return runs; nil when Return opens the action panel.
    var primary: PaletteAction? { opensActions ? nil : actions.first }
    /// The verb ⌘Return runs.
    var secondary: PaletteAction? { action(for: .secondary) }

    /// The chord a verb answers to on this row: Return and ⌘Return for
    /// the first two (unless a verb names its own), the verb's own
    /// otherwise. A position never hands out a chord some verb claims
    /// by name — an ask's Approve keeps ⌘Return even after a typed
    /// "deny" moved Deny to the front.
    func shortcut(for action: PaletteAction) -> PaletteShortcut? {
        if let own = action.shortcut { return own }
        guard !opensActions, let index = actions.firstIndex(where: { $0.id == action.id }) else { return nil }
        let positional: PaletteShortcut
        switch index {
        case 0: positional = .primary
        case 1: positional = .secondary
        default: return nil
        }
        return actions.contains { $0.shortcut == positional } ? nil : positional
    }

    /// The verb a chord runs on this row, if any — how a shortcut works
    /// straight from the list without opening the action panel.
    func action(for chord: PaletteShortcut) -> PaletteAction? {
        actions.first { shortcut(for: $0) == chord }
    }
}

/// A provider of rows. The palette asks every source on open (so rows
/// reflect the world at the keystroke) and, for sources that search
/// something slower, once per settled query.
@MainActor
protocol PaletteSource {
    /// Once per open, before the first `items()` — the moment to ask a
    /// store to re-read the system (the Control Center strip's truth).
    /// `items()` itself must only read: the palette re-asks it whenever
    /// something it read changes, so a write there would loop.
    func prepare()
    /// The rows known without a query.
    func items() -> [PaletteItem]
    /// Rows that only exist for a query — a full-text hit, a "search
    /// for …" row. Async so a slow store can never stall typing; the
    /// palette drops an answer whose query has moved on.
    func results(for query: String) async -> [PaletteItem]
    /// Rows the query itself spells — a command with its argument typed
    /// inline ("quiet 45m", "brightness 40"). Asked on every keystroke,
    /// so it is pure over the text and cheap; what it returns leads the
    /// results, since the query was written for it, and replaces any
    /// row of the same id.
    func typedItems(for query: String) -> [PaletteItem]
}

extension PaletteSource {
    func prepare() {}
    func results(for query: String) async -> [PaletteItem] { [] }
    func typedItems(for query: String) -> [PaletteItem] { [] }
}

/// A source made of a closure — the wiring's shape for sources whose
/// rows are one pure builder over live state.
@MainActor
struct PaletteClosureSource: PaletteSource {
    let build: @MainActor () -> [PaletteItem]
    var search: (@MainActor (String) async -> [PaletteItem])?
    var onPrepare: (@MainActor () -> Void)?
    var typed: (@MainActor (String) -> [PaletteItem])?

    init(prepare: (@MainActor () -> Void)? = nil,
         build: @escaping @MainActor () -> [PaletteItem],
         search: (@MainActor (String) async -> [PaletteItem])? = nil,
         typed: (@MainActor (String) -> [PaletteItem])? = nil) {
        self.onPrepare = prepare
        self.build = build
        self.search = search
        self.typed = typed
    }

    func prepare() { onPrepare?() }

    func items() -> [PaletteItem] { build() }

    func results(for query: String) async -> [PaletteItem] {
        await search?(query) ?? []
    }

    func typedItems(for query: String) -> [PaletteItem] {
        typed?(query) ?? []
    }
}
