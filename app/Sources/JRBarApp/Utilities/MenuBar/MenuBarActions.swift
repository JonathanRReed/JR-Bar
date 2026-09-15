import AppKit
import JRBarCore

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

    /// The utility's start/stop: hotkeys and the trigger feed only
    /// live while the utility does.
    func start() {
        hotkeys.start()
        triggerSource?.start()
    }

    func stop() {
        hotkeys.stop()
        triggerSource?.stop()
        commandBar.close()
        arrange.cancel()
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
        commandBar.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
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
        case .openItem(let itemID):
            delegate.menuBarActions(self, openItem: itemID)
        case .revealHidden:
            delegate.menuBarActionsRevealHidden(self)
        case .hideAll:
            delegate.menuBarActionsHideAll(self)
        case .showAll:
            delegate.menuBarActionsShowAll(self)
        case .arrange:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.arrangeMenuBar()
            }
        }
    }

    private func perform(_ action: MenuBarHotkeyAction) {
        guard let delegate else { return }
        switch action {
        case .toggleReveal:
            delegate.menuBarActionsRevealHidden(self)
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
        }
    }
}
