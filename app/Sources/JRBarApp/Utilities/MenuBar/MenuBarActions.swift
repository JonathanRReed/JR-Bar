import AppKit
import JRBarCore
import OSLog

/// The utility's side of the ACTIONS track — one protocol the
/// maintainer implements on `MenuBarUtility` (or a small adapter) and
/// every piece here routes through it. Nothing in the actions files
/// writes `MenuBarSettings` or touches the hider directly.
///
/// Wiring checklist (see MenuBarActions' doc comment for the flow):
///   * `menuBarItems` → `MenuBarItemLister.list()`
///   * `menuBarSections` → `settings().sections`
///   * `menuBarArrangeOrder` → the persisted arrange order (a new
///     `[String]` field on `MenuBarSettings`, e.g. `arrangeOrder`)
///   * `menuBarArrangeBoundary` →
///     `MenuBarArrangePlan.rightBoundary(items:regionMax:row:)`
///   * `setSection` → the existing `setSection(_:for:)`
///   * `openItem` → the Item Bar tile's `trigger(_:)`
///   * `revealHidden`/`revealFor` → `hider.reveal([.hidden])` +
///     `reveal.rearm()` (or a `rehideSeconds` override)
///   * `hideAll`/`showAll` → write `MenuBarCommands.hideAllSections` /
///     an empty map into `settings().sections`
///   * `applyProfile` → `MenuBarProfiles.apply(_:to:)` resolved by name
///   * `cycleProfile` → step through `settings().profiles` wrapping
@MainActor
protocol MenuBarActionsDelegate: AnyObject {
    /// The live listing, for the palette's commands and the arrange
    /// plan.
    func menuBarItems(for actions: MenuBarActions) -> [MenuBarItem]
    /// The persisted section map.
    func menuBarSections(for actions: MenuBarActions) -> [String: MenuBarItemSection]
    /// The desired left→right order the arrange button applies —
    /// item ids. Empty means "nothing asked for" and `arrange()` is
    /// a no-op.
    func menuBarArrangeOrder(for actions: MenuBarActions) -> [String]
    /// The x the movable run packs against — pass
    /// `MenuBarArrangePlan.rightBoundary(items:regionMax:row:)` so the
    /// plan packs against the real fixed items.
    func menuBarArrangeBoundary(for actions: MenuBarActions) -> CGFloat

    /// Assign one item a section (`.shown` clears the key — the
    /// utility's `updatedSections` already knows that rule).
    func menuBarActions(_ actions: MenuBarActions,
                        setSection section: MenuBarItemSection, for itemID: String)
    /// Press the item through — the Item Bar tile's path.
    func menuBarActions(_ actions: MenuBarActions, openItem itemID: String)
    /// The plain reveal — the utility's `rehideSeconds` clock.
    func menuBarActionsRevealHidden(_ actions: MenuBarActions)
    /// The hotkey's true toggle: the reveal surface up means hide,
    /// down means reveal — the chevron's click, fired from anywhere.
    func menuBarActionsToggleReveal(_ actions: MenuBarActions)
    /// The dedicated gesture for the deeper run: a temporary reveal
    /// of the always-hidden section on the `rehideSeconds` clock.
    func menuBarActionsRevealAlwaysHidden(_ actions: MenuBarActions)
    /// A reveal with an explicit clock (trigger rules carry one).
    func menuBarActions(_ actions: MenuBarActions, revealFor seconds: Double)
    /// Hide every listed unprotected item.
    func menuBarActionsHideAll(_ actions: MenuBarActions)
    /// Clear every hiding assignment.
    func menuBarActionsShowAll(_ actions: MenuBarActions)
    /// Apply a saved profile by name (`MenuBarProfiles.apply`); an
    /// unknown name should be a no-op, not an error.
    func menuBarActions(_ actions: MenuBarActions, applyProfile name: String)
    /// Step through `settings().profiles` — +1 next, -1 previous,
    /// wrapping through the built-in "None" state.
    func menuBarActions(_ actions: MenuBarActions, cycleProfile direction: Int)

    // The palette's reach past the item list. Defaults below keep a
    // delegate that predates them compiling; `MenuBarUtility` answers
    // each for real at the bottom of this file.

    /// Whether the macOS 27 concealer drives hiding right now — the
    /// palette hides Arrange while it does.
    func menuBarConcealing(for actions: MenuBarActions) -> Bool
    /// The saved profiles, in the card's order.
    func menuBarProfiles(for actions: MenuBarActions) -> [MenuBarSettings.Profile]
    /// Apply a profile by id — names can repeat, ids cannot.
    /// `MenuBarProfiles.noneID` is the built-in "None".
    func menuBarActions(_ actions: MenuBarActions, applyProfileID id: String)
    /// Switch one rule on or off — the card's toggle.
    func menuBarActions(_ actions: MenuBarActions, setRule id: String, enabled: Bool)
}

extension MenuBarActionsDelegate {
    func menuBarConcealing(for _: MenuBarActions) -> Bool { false }
    func menuBarProfiles(for _: MenuBarActions) -> [MenuBarSettings.Profile] { [] }
    func menuBarActions(_: MenuBarActions, applyProfileID _: String) {}
    func menuBarActions(_: MenuBarActions, setRule _: String, enabled _: Bool) {}
}

/// The ACTIONS track's single owner: arrange mode, the ⌘⇧K command
/// bar, the Carbon hotkeys, and the trigger engine — bundled so the
/// maintainer holds one object on `MenuBarUtility` and implements one
/// delegate.
///
/// `init` wires the internal seams to the delegate automatically;
/// the maintainer still owns lifecycle (`start()`/`stop()` from the
/// utility's own) and persistence (bindings, rules, and the arrange
/// order are Codable values ready for `MenuBarSettings` fields).
///
/// ⚠️ `arrange` is the only member that posts events: it physically
/// drags the person's cursor. It runs only from `arrange(to:)` — the
/// card button, the palette's "Arrange…" row — never from
/// `applySettings`, a trigger, or a timer. Trigger rules therefore
/// have no arrange action, and that is deliberate.
@MainActor
final class MenuBarActions {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")
    /// The arrange run — user-initiated only, see the warning above.
    let arrange = MenuBarArrangeCoordinator()
    /// The palette.
    let commandBar = MenuBarCommandBar()
    /// The Carbon hotkeys (start/stop with the utility).
    let hotkeys: MenuBarHotkeys
    /// The rule evaluator — value type, keep it here and feed it
    /// events from `triggerSource`.
    var triggerEngine = MenuBarTriggerEngine()
    /// The persisted rules — read through `rules()`, written by the
    /// maintainer's settings.
    var rules: @MainActor () -> [MenuBarTriggerRule] = { [] }
    /// The event feed — set `MenuBarSystemTriggerSource()` when at
    /// least one rule is enabled; nil means no sources run at all.
    var triggerSource: (any MenuBarTriggerSource)? {
        didSet { wireTriggerSource() }
    }

    weak var delegate: (any MenuBarActionsDelegate)? {
        didSet { rewire() }
    }

    init(bindings: [MenuBarHotkeyBinding] = MenuBarHotkeys.standard) {
        hotkeys = MenuBarHotkeys(bindings: bindings)
        rewire()
        wireTriggerSource()
    }

    /// The arrange button and the palette's "Arrange…" row: pull the
    /// persisted order from the delegate and run once. An empty order
    /// is a no-op — arranging to nothing would move nothing anyway,
    /// but saying so beats a banner flash.
    @discardableResult
    func arrangeMenuBar() async -> MenuBarArrangeOutcome {
        guard let order = delegate?.menuBarArrangeOrder(for: self),
              !order.isEmpty else { return .alreadyInOrder }
        return await arrange.arrange(to: order)
    }

    /// The hotkey/palette route in.
    func openCommandBar() { commandBar.toggle() }

    /// The utility's start/stop: hotkeys live while the utility does.
    /// The trigger feed is the utility's call — `syncActions` starts it
    /// only while an enabled rule can fire, so an actions start with no
    /// rules leaves the source parked.
    func start() {
        parkedPaletteKey.stop()
        hotkeys.start()
    }

    func stop() {
        hotkeys.stop()
        triggerSource?.stop()
        commandBar.close()
        arrange.cancel()
        syncParkedPaletteKey()
    }

    // MARK: ⌘⇧K while the utility is parked

    /// The palette is JR-Bar's, not only the menu bar's: with the Menu
    /// Bar utility off (or handed to Bartender), its hotkey still opens
    /// the palette for sessions, asks, quiet and the rest. The binding
    /// is the utility's own `commandBar` entry — same key, same on/off
    /// — registered alone here only while the full set is down, so the
    /// two registrations never hold the key at once.
    var paletteBinding: @MainActor () -> MenuBarHotkeyBinding? = { nil } {
        didSet { watchPaletteBinding() }
    }
    /// The one-binding registry for the parked key.
    let parkedPaletteKey = MenuBarHotkeys(bindings: [])
    /// Set at quit: nothing re-registers on the way out.
    private var shutDown = false

    /// Register the parked key if it should be up, drop it otherwise.
    func syncParkedPaletteKey() {
        let wanted = !shutDown && !hotkeys.started
            ? paletteBinding().flatMap { $0.enabled ? $0 : nil } : nil
        guard let wanted else {
            parkedPaletteKey.stop()
            return
        }
        guard parkedPaletteKey.bindings != [wanted] || !parkedPaletteKey.started else { return }
        parkedPaletteKey.stop()
        parkedPaletteKey.bindings = [wanted]
        parkedPaletteKey.start()
    }

    /// `applicationWillTerminate`: fold the palette, drop the parked key.
    func shutDownPalette() {
        shutDown = true
        commandBar.close()
        parkedPaletteKey.stop()
    }

    /// The binding lives in the persisted settings, which the card can
    /// change while the utility is parked (and `syncActions` is not
    /// running). Observation re-syncs on each change.
    private func watchPaletteBinding() {
        withObservationTracking {
            _ = paletteBinding()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.shutDown else { return }
                self.syncParkedPaletteKey()
                self.watchPaletteBinding()
            }
        }
        syncParkedPaletteKey()
    }

    // MARK: Internal routing — everything lands on the delegate

    private func rewire() {
        arrange.listItems = { [weak self] in
            guard let self, let delegate = self.delegate else { return [] }
            return delegate.menuBarItems(for: self)
        }
        arrange.rightBoundary = { [weak self] in
            guard let self, let delegate = self.delegate else {
                return CGDisplayBounds(CGMainDisplayID()).maxX
            }
            return delegate.menuBarArrangeBoundary(for: self)
        }
        commandBar.items = { [weak self] in
            guard let self, let delegate = self.delegate else { return [] }
            return delegate.menuBarItems(for: self)
        }
        commandBar.sections = { [weak self] in
            guard let self, let delegate = self.delegate else { return [:] }
            return delegate.menuBarSections(for: self)
        }
        commandBar.concealing = { [weak self] in
            guard let self, let delegate = self.delegate else { return false }
            return delegate.menuBarConcealing(for: self)
        }
        commandBar.profiles = { [weak self] in
            guard let self, let delegate = self.delegate else { return [] }
            return delegate.menuBarProfiles(for: self)
        }
        commandBar.rules = { [weak self] in self?.rules() ?? [] }
        commandBar.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        // The parked key has one binding, the palette's.
        parkedPaletteKey.onAction = { [weak self] action in
            guard action == .commandBar else { return }
            self?.commandBar.toggle()
        }
    }

    private func wireTriggerSource() {
        triggerSource?.onEvent = { [weak self] event in
            self?.handleTriggerEvent(event)
        }
    }

    /// One event → engine → actions → delegate. The engine is pure;
    /// the side effects are all on the delegate's side.
    private func handleTriggerEvent(_ event: MenuBarTriggerEvent) {
        let dayStamp = MenuBarSystemTriggerSource.dayStamp()
        for action in triggerEngine.actions(for: event, rules: rules(),
                                            dayStamp: dayStamp) {
            perform(action)
        }
    }

    private func perform(_ action: MenuBarCommandAction) {
        guard let delegate else { return }
        switch action {
        case .setSection(let itemID, let section):
            delegate.menuBarActions(self, setSection: section, for: itemID)
        case .setAppSection(let itemIDs, let section):
            for itemID in itemIDs {
                delegate.menuBarActions(self, setSection: section, for: itemID)
            }
        case .openItem(let itemID):
            delegate.menuBarActions(self, openItem: itemID)
        case .revealHidden:
            delegate.menuBarActionsRevealHidden(self)
        case .revealAlwaysHidden:
            delegate.menuBarActionsRevealAlwaysHidden(self)
        case .toggleHidden:
            delegate.menuBarActionsToggleReveal(self)
        case .hideAll:
            delegate.menuBarActionsHideAll(self)
        case .showAll:
            delegate.menuBarActionsShowAll(self)
        case .arrange:
            // The palette never lists Arrange under the concealer; a
            // stale row that lands here anyway is refused rather than
            // dragging a pointer that cannot reorder anything.
            guard !delegate.menuBarConcealing(for: self) else { return }
            Task { [weak self] in
                guard let self else { return }
                _ = await self.arrangeMenuBar()
            }
        case .applyProfile(let id):
            delegate.menuBarActions(self, applyProfileID: id)
        case .runRule(let id):
            // The rule's own action, through the trigger path's router —
            // the card's rule and "run now" can never disagree.
            guard let rule = rules().first(where: { $0.id == id }) else { return }
            perform(rule.action)
        case .setRuleEnabled(let id, let enabled):
            delegate.menuBarActions(self, setRule: id, enabled: enabled)
        }
    }

    private func perform(_ action: MenuBarHotkeyAction) {
        guard let delegate else { return }
        switch action {
        case .toggleReveal:
            delegate.menuBarActionsToggleReveal(self)
        case .revealAlwaysHidden:
            delegate.menuBarActionsRevealAlwaysHidden(self)
        case .hideAll:
            delegate.menuBarActionsHideAll(self)
        case .showAll:
            delegate.menuBarActionsShowAll(self)
        case .commandBar:
            commandBar.toggle()
        case .nextProfile:
            delegate.menuBarActions(self, cycleProfile: 1)
        case .previousProfile:
            delegate.menuBarActions(self, cycleProfile: -1)
        }
    }

    private func perform(_ action: MenuBarTriggerAction) {
        guard let delegate else { return }
        switch action {
        case .applyProfile(let name):
            delegate.menuBarActions(self, applyProfile: name)
        case .hideAll:
            delegate.menuBarActionsHideAll(self)
        case .showAll:
            delegate.menuBarActionsShowAll(self)
        case .reveal(let seconds):
            delegate.menuBarActions(self, revealFor: seconds)
        case .runScript(let command):
            Self.runScript(command)
        }
    }

    /// The script trigger's side effect: `/bin/sh -c` detached so a
    /// hanging script never stalls the trigger pump — and output rides
    /// the menubar log either way it exits.
    private static func runScript(_ command: String) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                // Drain to EOF *before* waiting — a script that out-writes
                // the pipe buffer blocks on write() and never exits if the
                // reader isn't already reading.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus != 0 {
                    MenuBarActions.log.notice("trigger script exited \(process.terminationStatus): \(out, privacy: .public)")
                } else if !out.isEmpty {
                    MenuBarActions.log.debug("trigger script: \(out, privacy: .public)")
                }
            } catch {
                MenuBarActions.log.notice("trigger script failed to launch: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - The utility's palette answers

/// `MenuBarUtility`'s side of the palette's newer delegate calls — the
/// same writes the card's own controls make: `applyProfile(id:)` keeps
/// the hotkey cycle's cursor honest, and a rule's switch lands through
/// the utility's settings write so the trigger feed re-arms.
extension MenuBarUtility {
    func menuBarConcealing(for _: MenuBarActions) -> Bool { concealing }

    func menuBarProfiles(for _: MenuBarActions) -> [MenuBarSettings.Profile] {
        settings().profiles
    }

    func menuBarActions(_: MenuBarActions, applyProfileID id: String) {
        guard id == MenuBarProfiles.noneID || settings().profiles.contains(where: { $0.id == id })
        else { return }
        applyProfile(id: id)
    }

    func menuBarActions(_: MenuBarActions, setRule id: String, enabled: Bool) {
        var draft = settings()
        guard let index = draft.triggerRules.firstIndex(where: { $0.id == id }),
              draft.triggerRules[index].enabled != enabled else { return }
        draft.triggerRules[index].enabled = enabled
        onSettingsChange?(draft)
    }
}
