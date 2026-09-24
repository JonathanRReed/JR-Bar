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
            if state.menuBar != oldValue.menuBar { menuBar.applySettings() }
            if state.dock != oldValue.dock { dock.applySettings() }
            if state.agents != oldValue.agents { agents.applySettings() }
            if state.dataHoarderEnabled != oldValue.dataHoarderEnabled {
                dataHoarder.model.enabled = state.dataHoarderEnabled
            }
            if state.dataHoarder != oldValue.dataHoarder {
                dataHoarder.model.applyCaptureSettings(state.dataHoarder)
            }
        }
    }

    /// The Menu Bar utility: the spacers, the reveal gestures, the
    /// chevron status item and the glass Item Bar.
    let menuBar: MenuBarUtility
    /// The Dock utility: the hover-preview watcher over Apple's Dock.
    let dock: DockUtility
    /// The Agent Overview utility: the roster's management seat — the
    /// compact state-grouped list, the counts, and the session verbs
    /// (`open_session`, `answer_ask`, `dismiss_session`,
    /// `clear_completed`, `snooze`) the panel already owns.
    let agents: AgentUtility
    let dataHoarder = DataHoarderUtility()

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
        dataHoarder.model.enabled = state.dataHoarderEnabled
        dataHoarder.onEnabledChange = { [weak self] enabled in
            self?.state.dataHoarderEnabled = enabled
        }
        dataHoarder.model.applyCaptureSettings(state.dataHoarder)
        dataHoarder.model.onCaptureSettingsChange = { [weak self] updated in
            guard let self, self.state.dataHoarder != updated else { return }
            self.state.dataHoarder = updated
        }
        // The roster's `agent_id` is `provider:session:<uuid>`; a captured
        // record whose probed session uuid still ends a live row can be
        // opened — anything else leaves the button disabled.
        dataHoarder.model.sessionResolver = { [weak self] record in
            guard let self, let sessionID = record.sessionID, !sessionID.isEmpty,
                  let provider = record.provider else { return nil }
            return self.core.state?.sessions.first {
                !$0.remote && $0.provider == provider && $0.id.hasSuffix(sessionID)
            }?.id
        }
        dataHoarder.model.sessionOpener = { [weak self] id in
            self?.core.openSession(id)
        }
        dataHoarder.model.applyCapture()
        // The utility reads and writes the persisted blob through these;
        // the store stays the single owner of `state`.
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
        agents.settings = { [weak self] in self?.state.agents ?? AgentOrganizerSettings() }
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
    /// (`open_session`) to act — it resumes, it doesn't raise.
    @discardableResult
    func raiseSessionWindow(_ sessionID: String) -> Bool {
        dock.raiseSessionWindow(sessionID) == .raised
    }

    /// The same, for an async caller (`SessionOpener`): the window lists
    /// and the walk for another Space's window run on `DockAXWorker`, so
    /// a hung host app never holds the main thread; the activation and
    /// the answer come back to it.
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
        dataHoarder.model.stopCapture()
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
