import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Owns the utility objects and `UtilitiesState`, the persisted half of
/// the Utilities page (docs/UTILITIES.md) — the same seat `ToysStore`
/// keeps on the Toys side. Created once in `AppDelegate` next to
/// `SettingsStore`; the page reaches it through `SettingsStore.utilities`.
///
/// Persistence rides `app-state.json` exactly the way the toys' does:
/// the delegate hands back a single `onPersist` that drops `state` into
/// the `AppState` it already owns, so there is exactly one writer of
/// the file and a utilities save can never clobber the delegate's
/// fields (or the other way around). Writes are debounced 300 ms — a
/// dragged rehide slider would otherwise stream a write per tick.
@MainActor
@Observable
final class UtilitiesStore {
    let core: CoreModel
    /// The daemon-document store, kept for the utilities whose rows
    /// write a real setting the way Alcove's follow toggle does.
    let settings: SettingsStore

    /// Everything the utilities persist; mirrors `AppState.utilities`.
    /// A settings write re-applies the utility whose settings changed —
    /// only that one: re-applying all three on every keystroke meant a
    /// dragged Agents slider reconciled the menu bar and rewrote the
    /// Dock's defaults a dozen times over.
    var state: UtilitiesState {
        didSet {
            scheduleSave()
            if state.menuBar.requiresReapply(comparedTo: oldValue.menuBar) {
                menuBar.applySettings()
            } else if state.menuBar.curation.searchNames != oldValue.menuBar.curation.searchNames {
                menuBar.bar.syncItems()
            }
            if state.menuBar.itemHotkeyBindings != oldValue.menuBar.itemHotkeyBindings {
                menuBar.reconcileItemHotkeys()
            }
            if state.dock != oldValue.dock { dock.applySettings() }
            if state.agents != oldValue.agents { agents.applySettings() }
        }
    }

    /// The Menu Bar utility: the spacers, the reveal gestures, the
    /// chevron status item and the glass Item Bar.
    let menuBar: MenuBarUtility
    /// The Dock utility: the hover-preview watcher over Apple's Dock.
    let dock: DockUtility
    /// The Agent Overview utility: each provider's alert rules, "quiet
    /// while you watch", and the way into the Overview window. The roster
    /// and its session verbs (`open_session`, `answer_ask`,
    /// `dismiss_session`, `clear_completed`, `snooze`) live in the panel
    /// and the Overview, not on the card.
    let agents: AgentUtility

    /// Drops `state` into the delegate's `AppState` and writes the file.
    var onPersist: (@MainActor (UtilitiesState) -> Void)?

    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(core: CoreModel, settings: SettingsStore, state: UtilitiesState) {
        self.core = core
        self.settings = settings
        self.state = state
        let menuBar = MenuBarUtility()
        self.menuBar = menuBar
        let dock = DockUtility()
        self.dock = dock
        let agents = AgentUtility(core: core)
        self.agents = agents
        // The utility reads and writes the persisted blob through these;
        // the store stays the single owner of `state`.
        menuBar.onOpenShortcuts = { [weak settings] in settings?.revealHome(.hotkeys) }
        menuBar.settings = { [weak self] in self?.state.menuBar ?? MenuBarSettings() }
        menuBar.onSettingsChange = { [weak self] updated in
            self?.state.menuBar = updated
        }
        dock.settings = { [weak self] in self?.state.dock ?? DockSettings() }
        dock.onSettingsChange = { [weak self] updated in
            self?.state.dock = updated
        }
        // The Dock and the switcher mark the windows agents run in from
        // the same live `state.sessions` the panel reads.
        dock.sessions = { [weak self] in self?.core.state?.sessions ?? [] }
        dock.asks = { [weak self] in self?.core.state?.asks ?? [] }
        agents.settings = { [weak self] in self?.state.agents ?? AgentOverviewSettings() }
        agents.onSettingsChange = { [weak self] updated in
            self?.state.agents = updated
        }
    }

    /// Called once after launch: turns on whatever the persisted state
    /// has on. A parked utility owns nothing until this runs.
    /// The one path every settings change takes — the `didSet` and the
    /// delegate's post-launch call both land here, so a card toggle can
    /// never diverge from what a restart would apply. `DockUtility`
    /// distinguishes start/stop/re-apply itself.
    func applySettings() {
        menuBar.applySettings()
        dock.applySettings()
        agents.applySettings()
    }

    /// Raise the exact window a live agent session runs in, if one
    /// window exclusively hosts it (`SessionWindowLocator`). True when
    /// that window is now in front; false leaves the caller's fallback
    /// (`open_session`) to act — it resumes, it doesn't raise. The
    /// window lists and the walk for another Space's window run on
    /// `DockAXWorker`, so a hung host app never holds the main thread;
    /// the activation and the answer come back to it.
    @discardableResult
    func raiseSessionWindow(_ sessionID: String) async -> Bool {
        await dock.raiseSessionWindow(sessionID) == .raised
    }

    /// `applicationWillTerminate`'s stop: collapses the menu bar's
    /// spacers before they vanish with the process, and hands Apple's
    /// Dock its autohide value back if an old build's bar hid it.
    func stop() {
        menuBar.stop()
        dock.stop()
        dock.appleDock.restore()
    }

    // MARK: Persistence

    /// A burst of slider/toggle edits becomes one write, last wins.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes `state` now; also the debounce's target. Never throws —
    /// the delegate logs a failed write the way `persistAppState` does.
    func save() {
        saveWork?.cancel()
        saveWork = nil
        onPersist?(state)
    }
}
