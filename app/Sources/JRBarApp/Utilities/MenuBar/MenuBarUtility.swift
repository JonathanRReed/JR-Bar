import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility (docs/UTILITIES.md): owns the hider's spacers
/// and override covers, the reveal gestures, the glass Item Bar, and
/// the utility's two control items — the chevron that is the hidden
/// run's boundary *and* its spacer, and the always-hidden control that
/// does the same for the deeper run and opens the Item Bar.
/// `UtilitiesStore` keeps it; the page's card reads it as a `Toy`, so
/// one shell serves every utility.
///
/// The model is Bartender's: items left of the chevron are hidden,
/// items left of the always-hidden control are always-hidden, and the
/// person ⌘-drags items across the controls to choose. Hiding is the
/// control growing a spacer that packs those items off the row into
/// macOS's own overflow; revealing collapses it. The object itself is
/// a façade — the rules live in the pieces it wires: `MenuBarItemHider`
/// measures and plans, `MenuBarReveal` decides what counts as a
/// gesture, and the chevron toggles the run by hand. Nothing here
/// posts mouse events: tile clicks go through `AXPress` — the one
/// reposted-click fallback only fires when a person clicked a tile and
/// the item's element could not be resolved.
@MainActor
@Observable
final class MenuBarUtility: Toy {
    /// Live read of the persisted settings — the store wires it to
    /// `state.menuBar`, so the card's observation of the store's
    /// `state` still registers through the closure.
    @ObservationIgnored var settings: @MainActor () -> MenuBarSettings = { MenuBarSettings() }
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it and re-applies the utility.
    @ObservationIgnored var onSettingsChange: (@MainActor (MenuBarSettings) -> Void)?

    /// The spacer lengths, the override covers and the reconcile cadence.
    let hider = MenuBarItemHider()
    /// Hover / empty-space click / scroll.
    let reveal = MenuBarReveal()
    /// The glass bar of hidden-item tiles.
    let bar = MenuBarBar()
    /// Arrange mode, the ⌘⇧K command bar, the global hotkeys and the
    /// trigger engine — the utility implements `MenuBarActionsDelegate`
    /// (bottom of file) so every action lands on the same machinery
    /// the card's own rows use.
    let actions = MenuBarActions()
    /// The real trigger feed, created once; `syncActions` runs it only
    /// while at least one rule is enabled.
    @ObservationIgnored private let systemTriggerSource = MenuBarSystemTriggerSource()
    /// The last arrange run's outcome — the card's report line.
    private(set) var lastArrangeOutcome: MenuBarArrangeOutcome?
    /// True while an arrange is dragging — the card disables its button.
    private(set) var arranging = false
    /// Where the profile-cycling cursor sits: 0 is the built-in "None",
    /// i > 0 is `profiles[i - 1]`. `applyProfile` keeps it honest.
    @ObservationIgnored private var profileCursor = 0

    /// The latest layout — the card's count row and item list read it.
    /// While the utility runs the hider keeps it fresh; while it is
    /// parked the card's `refreshListing()` fills it once, spacers down.
    private(set) var lastPlan = MenuBarHidePlan()
    /// Spacers parked, monitors up.
    private(set) var running = false
    /// Accessibility, re-polled at most every `accessibilityPollSeconds`
    /// — `AXIsProcessTrusted` is a `TCCAccessRequest` IPC, so it must
    /// never run per render, per event, or on the reconcile cadence.
    /// Probed on a listing refresh, a tile click, and each start.
    private(set) var accessibilityGranted = false
    @ObservationIgnored private var accessibilityCheckedAt = Date.distantPast
    /// The minimum gap between TCC polls.
    nonisolated static let accessibilityPollSeconds: TimeInterval = 3

    /// The cached grant, refreshed when the cache is stale. A parked
    /// utility asks nothing of TCC at all — the probe only runs on
    /// demand.
    @discardableResult
    func probeAccessibility() -> Bool {
        if Date().timeIntervalSince(accessibilityCheckedAt) > Self.accessibilityPollSeconds {
            accessibilityCheckedAt = Date()
            accessibilityGranted = AXIsProcessTrusted()
        }
        return accessibilityGranted
    }

    /// The chevron status item — the hidden run's toggle on the row.
    /// Target/action needs an `NSObject`, so the buttons' clicks land
    /// on this box and forward.
    @ObservationIgnored private let chevronActions = MenuBarChevronActions()
    /// Readable for the teardown test; only `install`/`removeChevron` write it.
    @ObservationIgnored private(set) var chevron: NSStatusItem?
    /// The always-hidden control — a narrower item whose click opens
    /// the Item Bar, the deeper run's only surface.
    @ObservationIgnored private(set) var alwaysHiddenControl: NSStatusItem?
    /// The single control when `combinedStatusItem` is on: click opens
    /// the Item Bar, right-click pops the covered-item menu that also
    /// carries the hidden run's toggle.
    @ObservationIgnored private(set) var combinedControl: NSStatusItem?

    init() {
        hider.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        hider.onPlan = { [weak self] plan in
            guard let self else { return }
            self.lastPlan = plan
            self.refreshChevron()
        }
        // Our own controls are never covered — their live frames split
        // cover runs even on the no-AX path where they cannot list.
        hider.protectedFrames = { [weak self] in
            guard let self else { return [] }
            return [self.chevron, self.alwaysHiddenControl, self.combinedControl]
                .compactMap { Self.quartzFrame(of: $0) }
        }
        hider.controlFrames = { [weak self] in
            guard let self else { return MenuBarControlFrames() }
            return MenuBarControlFrames(
                hidden: Self.quartzFrame(of: self.chevron ?? self.combinedControl),
                alwaysHidden: Self.quartzFrame(of: self.alwaysHiddenControl))
        }
        hider.setControlLength = { [weak self] section, length in
            self?.setControlLength(section, length: length)
        }
        reveal.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        // The reveal zone is the row minus the *visible* items — the
        // covered stretch is exactly the space a gesture lands on.
        reveal.itemFrames = { [weak self] in self?.shownItemFrames() ?? [] }
        reveal.barFrame = { [weak self] in self?.bar.panelFrame }
        reveal.onReveal = { [weak self] in self?.hider.reveal([.hidden]) }
        reveal.onHide = { [weak self] in self?.hider.hide() }
        bar.items = { [weak self] in self?.barItems() ?? [] }
        bar.onTrigger = { [weak self] item in self?.trigger(item) }
        bar.onRevealItem = { [weak self] item in self?.revealItem(item) }
        bar.onOpenChange = { [weak self] open in
            guard let self else { return }
            self.reveal.holdOpen = open
            if !open { self.reveal.noteBarClosed() }
        }
        actions.delegate = self
        actions.rules = { [weak self] in self?.settings().triggerRules ?? [] }
        actions.triggerSource = systemTriggerSource
        chevronActions.utility = self
    }

    isolated deinit {
        if let chevron { NSStatusBar.system.removeStatusItem(chevron) }
        if let alwaysHiddenControl { NSStatusBar.system.removeStatusItem(alwaysHiddenControl) }
        if let combinedControl { NSStatusBar.system.removeStatusItem(combinedControl) }
    }

    // MARK: Toy

    let id = "menuBar"
    let name = "Menu Bar"
    let blurb = "Tuck menu bar items behind a chevron — hover, click or scroll the bar to bring them back."
    let symbol = "menubar.rectangle"

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        if !isOn { return .off }
        return running ? .on : .paused("Parked")
    }

    var controls: AnyView {
        AnyView(MenuBarUtilityControls(utility: self))
    }

    // MARK: Settings writes

    /// A card edit: mutate a copy of the persisted settings and hand it
    /// to the store, whose `state` write persists and re-applies.
    private func update(_ mutate: (inout MenuBarSettings) -> Void) {
        var draft = settings()
        mutate(&draft)
        onSettingsChange?(draft)
    }

    /// A binding into the persisted settings; the store's `didSet`
    /// debounces the write, so a dragged slider doesn't stream saves.
    func bind<T>(_ keyPath: WritableKeyPath<MenuBarSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// The section an item sits in; unlisted is shown.
    func section(for itemID: String) -> MenuBarItemSection {
        settings().section(for: itemID)
    }

    /// The card's per-item picker: the write is the single mapping and
    /// the cover lands where the item already sits — nothing is ever
    /// dragged anywhere.
    func setSection(_ section: MenuBarItemSection, for itemID: String) {
        update { draft in
            draft.sections = MenuBarItemHider.updatedSections(
                items: listedItems, sections: draft.sections,
                changedID: itemID, target: section)
        }
    }

    // MARK: Appearance bindings (hex-string settings ↔ Color)

    /// The tint's on/off — `coverTint` empty is the untinted cover.
    func bindCoverTintEnabled() -> Binding<Bool> {
        Binding(
            get: { !self.settings().coverTint.isEmpty },
            set: { on in self.update {
                $0.coverTint = on ? MenuBarCoverAppearance.defaultTintHex : ""
            } })
    }

    /// The tint's color — `coverTint` is a "#RRGGBB" string.
    func bindCoverTintColor() -> Binding<Color> {
        Binding(
            get: {
                MenuBarCoverAppearance.tintComponents(self.settings().coverTint)
                    .map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .gray
            },
            set: { color in self.update {
                $0.coverTint = MenuBarCoverAppearance.hex(from: NSColor(color)) ?? ""
            } })
    }

    // MARK: Profiles

    /// Apply a profile — or the built-in "None" — through the normal
    /// settings write, so the reconcile path restyles and re-covers.
    func applyProfile(id: String) {
        let profile = settings().profiles.first { $0.id == id }
        // Keep the hotkey cycle cursor honest: None is index 0, the
        // profiles follow in list order.
        profileCursor = profile.map { p in
            (settings().profiles.firstIndex(where: { $0.id == p.id }) ?? 0) + 1
        } ?? 0
        update { MenuBarProfiles.apply(profile, to: &$0) }
    }

    /// Save the current arrangement under `name`; returns the saved
    /// profile's id (nil on an unusable name).
    @discardableResult
    func saveProfileAs(_ name: String) -> String? {
        var savedID: String?
        update { savedID = MenuBarProfiles.saveCurrent(as: name, in: &$0) }
        return savedID
    }

    func renameProfile(id: String, to name: String) {
        update { MenuBarProfiles.rename(id: id, to: name, in: &$0) }
    }

    func deleteProfile(id: String) {
        update { MenuBarProfiles.delete(id: id, in: &$0) }
    }

    // MARK: Actions (hotkeys, triggers, arrange, command bar)

    /// The bindings the hotkey registry actually uses — the persisted
    /// list, or the shipping set while the file has never carried one.
    func resolvedHotkeyBindings() -> [MenuBarHotkeyBinding] {
        let stored = settings().hotkeyBindings
        return stored.isEmpty ? MenuBarHotkeys.standard : stored
    }

    /// The card's per-action toggle — writes the materialized list so
    /// the settings file carries what the person actually sees.
    func setHotkeyEnabled(_ enabled: Bool, for action: MenuBarHotkeyAction) {
        var list = resolvedHotkeyBindings()
        guard let index = list.firstIndex(where: { $0.action == action }) else { return }
        list[index].enabled = enabled
        update { $0.hotkeyBindings = list }
    }

    /// The ⌘⇧K palette — also the card's "Command bar" button.
    func openCommandBar() { actions.openCommandBar() }

    /// The arrange editor's list: the layout a run would drive the bar
    /// to — unnamed movable items keep their bar order as the deep
    /// (left) block, named ids pack right of it in saved order.
    var arrangeItems: [MenuBarItem] {
        let movable = listedItems.filter { !MenuBarItemLister.isProtected($0) }
        let order = settings().arrangeOrder
        var used: Set<String> = []
        let named = order.compactMap { id -> MenuBarItem? in
            guard !used.contains(id),
                  let item = movable.first(where: { $0.id == id }) else { return nil }
            used.insert(id)
            return item
        }
        return movable.filter { !used.contains($0.id) } + named
    }

    /// Move an item one slot in the editor; the write carries the whole
    /// resolved order so the arrange run drives every item it reaches.
    func moveArrangeItem(id: String, by delta: Int) {
        var order = arrangeItems.map(\.id)
        guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        update { $0.arrangeOrder = order }
    }

    /// The explicit arrange action — the only caller of the synthetic
    /// ⌘-drag machinery. The banner, cursor restore and abort watcher
    /// are the coordinator's; this just runs it and reports.
    func arrangeNow() {
        guard !arranging else { return }
        // An empty order is a no-op — materialize the editor's list so
        // the button always does what the list shows.
        if settings().arrangeOrder.isEmpty {
            update { $0.arrangeOrder = arrangeItems.map(\.id) }
        }
        arranging = true
        // The spacers collapse first: an expanded chevron reaches to
        // the region's edge, and the plan would pack against it.
        hider.reveal([.hidden, .alwaysHidden])
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.lastArrangeOutcome = await self.actions.arrangeMenuBar()
            self.arranging = false
            self.hider.hide()
        }
    }

    /// What the last arrange run reported — the card's status line.
    var arrangeNote: String? {
        switch lastArrangeOutcome {
        case .completed(let n):
            return n == 0 ? "Already in that order." : "Arranged — \(n) item\(n == 1 ? "" : "s") moved."
        case .alreadyInOrder: return "Already in that order."
        case .aborted(let n): return "Cancelled — \(n) move\(n == 1 ? "" : "s") had landed."
        case .incomplete(let n): return "Stopped — the bar never settled (\(n) moves)."
        case .busy: return "An arrange is already running."
        case nil: return nil
        }
    }

    // MARK: Trigger rules

    func addTriggerRule(trigger: MenuBarTrigger, action: MenuBarTriggerAction) {
        update { $0.triggerRules.append(MenuBarTriggerRule(trigger: trigger, action: action)) }
    }

    func setTriggerRule(id: String, enabled: Bool) {
        update { draft in
            guard let i = draft.triggerRules.firstIndex(where: { $0.id == id }) else { return }
            draft.triggerRules[i].enabled = enabled
        }
    }

    func deleteTriggerRule(id: String) {
        update { $0.triggerRules.removeAll { $0.id == id } }
    }

    // MARK: Lifecycle

    /// The card toggle and the store's `state` write land here: start
    /// on enable, stop on disable, reconcile on any other change.
    func applySettings() {
        migrateSectionsIfNeeded()
        let enabled = settings().enabled
        if enabled, !running {
            start()
        } else if !enabled, running {
            stop()
        } else if running {
            // The control set is settings-driven too — a combined-mode
            // flip or a profile apply lands here between covers.
            installChevron()
            hider.reconcile()
            syncActions()
        }
    }

    /// A file from the cover era assigned every item hidden — under
    /// the position model that map would cover every item right of the
    /// chevron in place. Clear it once; the person's ⌘-drag layout is
    /// the arrangement now, and the pickers write fresh overrides.
    func migrateSectionsIfNeeded() {
        guard settings().layoutModel < MenuBarSettings.currentLayoutModel else { return }
        update { draft in
            draft.sections = [:]
            draft.layoutModel = MenuBarSettings.currentLayoutModel
        }
    }

    /// Under the position model the chevron's slot *is* the setting,
    /// so an install seats the chevron once just left of JR-Bar's own
    /// status item: what arrived after JR-Bar hides, the system's
    /// items and ours stay. The person ⌘-drags it from there. Needs the chevron's live frame (to
    /// calibrate preferred position against x) and our main item's;
    /// without either it waits for the next start.
    /// - Parameters:
    ///   - mainItemMinX: the left edge of JR-Bar's own status item.
    ///   - chevronMinX: the collapsed chevron's left edge right now.
    ///   - chevronPreferred: the preferred position the chevron was
    ///     seated with.
    /// Returns the preferred positions to write for the chevron and
    /// the always-hidden control.
    nonisolated static func reseatPositions(mainItemMinX: CGFloat, chevronMinX: CGFloat,
                                            chevronPreferred: Double) -> (chevron: Double, alwaysHidden: Double) {
        // macOS seats an item at x ≈ offset − preferred; the offset is
        // whatever it is on this bar, measured off our own chevron.
        let offset = chevronPreferred + Double(chevronMinX)
        let target = Double(mainItemMinX - MenuBarControlFrames.glyphLength - 2)
        let chevron = (offset - target).rounded()
        return (chevron, chevron + 30)
    }

    /// Run the reseat once the controls stand and the listing is in.
    func reseatControlsIfNeeded() {
        guard !settings().controlsSeated,
              !settings().combinedStatusItem,
              let chevron, let chevronFrame = Self.quartzFrame(of: chevron),
              chevronFrame.intersects(MenuBarItemLister.menuBarRow()),
              let preferred = UserDefaults.standard.object(
                forKey: "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-chevron") as? Double,
              let main = MenuBarItemLister.list().first(where: {
                  $0.ownerName == "JR-Bar" && $0.identifier == StatusItemController.accessibilityIdentifier
              }) else { return }
        let positions = Self.reseatPositions(mainItemMinX: main.bounds.minX,
                                             chevronMinX: chevronFrame.minX,
                                             chevronPreferred: preferred)
        MenuBarItemHider.log.notice("reseating controls next to the JR-Bar item at \(main.bounds.minX, privacy: .public): chevron \(positions.chevron, privacy: .public), always-hidden \(positions.alwaysHidden, privacy: .public)")
        removeSeparateControls()
        UserDefaults.standard.set(positions.chevron,
                                  forKey: "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-chevron")
        UserDefaults.standard.set(positions.alwaysHidden,
                                  forKey: "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-ah-control")
        installSeparateControls()
        hider.resetCaps()
        update { $0.controlsSeated = true }
        hider.scheduleSettle()
    }

    private func start() {
        guard !running else { return }
        running = true
        probeAccessibility()
        installChevron()
        hider.start()
        reveal.start()
        // Bindings land before start so registration uses the persisted
        // set, not the defaults the actions object was built with.
        syncActions()
        actions.start()
        // First AX fill — a no-op without the grant — then reconcile
        // against real frames, and seat a migrated install's controls.
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self else { return }
            self.reseatControlsIfNeeded()
            self.hider.reconcile()
        }
    }

    /// Everything down: the bar closes, the gestures stop, the covers
    /// lift, and the control items leave the row.
    func stop() {
        guard running else { return }
        bar.close()
        reveal.stop()
        hider.stop()
        actions.stop()
        removeChevron()
        running = false
    }

    /// Keep the actions object's moving parts in step with the
    /// persisted settings: the hotkey list (the empty file means the
    /// shipping set — toggling one materializes the whole list) and
    /// the trigger feed, which runs only while a rule can fire.
    private func syncActions() {
        let resolved = resolvedHotkeyBindings()
        if actions.hotkeys.bindings != resolved {
            actions.hotkeys.bindings = resolved
            actions.hotkeys.apply()
        }
        if settings().triggerRules.contains(where: \.enabled) {
            systemTriggerSource.start()
        } else {
            systemTriggerSource.stop()
        }
    }

    // MARK: Listing (the card's item rows)

    /// The card's enumeration with the utility parked: refresh the AX
    /// snapshot (off-actor — a slow app must not stall the card) and
    /// run the listing-only plan — a parked utility draws no covers,
    /// so everything on the row reports as it sits.
    func refreshListing() {
        probeAccessibility()
        guard !running else { return }
        guard accessibilityGranted else {
            lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.list(), row: MenuBarItemLister.menuBarRow())
            return
        }
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self, !self.running else { return }
            self.lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.axItems, row: MenuBarItemLister.menuBarRow())
        }
    }

    /// Every item the card lists, in bar order.
    var listedItems: [MenuBarItem] {
        lastPlan.shown + lastPlan.hidden + lastPlan.alwaysHidden
    }

    /// The Item Bar's tiles: both hidden runs.
    private func barItems() -> [MenuBarItem] {
        lastPlan.hidden + lastPlan.alwaysHidden
    }

    /// The on-row items a click should count as "on an item" — the
    /// shown zone only. Covered items are the reveal zone itself.
    /// Frames arrive in Quartz and flip to AppKit for the hit test.
    private func shownItemFrames() -> [NSRect] {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return lastPlan.shown.map {
            NSRect(x: $0.bounds.minX, y: height - $0.bounds.maxY,
                   width: $0.bounds.width, height: $0.bounds.height)
        }
    }

    // MARK: Tile actions

    /// A plain click on a tile: `AXPress` the item's element —
    /// Accessibility required. It reaches a covered item without
    /// dropping the shutter and a system-parked item a reposted click
    /// could never hit. Without the grant the tile just raises the
    /// owning app, the posture the permissions row sets. When the
    /// element can no longer be resolved — the app reordered its
    /// extras mid-relaunch — the click falls back to a reveal plus a
    /// reposted click at wherever the item settled.
    /// macOS needs a beat to reflow the row once the covers drop —
    /// the click must land where the item settles, not where the stash
    /// left it. The retry is the insurance: an item still off the row
    /// at the deadline gets one more beat before the click goes anyway.
    nonisolated static let reflowDelay: TimeInterval = 0.7
    nonisolated static let reflowRetryDelay: TimeInterval = 0.4

    private func trigger(_ item: MenuBarItem) {
        let granted = probeAccessibility()
        bar.close()
        guard granted else {
            item.owner?.activate()
            return
        }
        Task.detached { [weak self] in
            if MenuBarAX.press(item) { return }
            await MainActor.run { self?.clickFallback(item) }
        }
    }

    /// The no-press fallback: uncover both runs and repost a real
    /// click at the item's frame once it settles on the row.
    private func clickFallback(_ item: MenuBarItem) {
        hider.reveal([.hidden, .alwaysHidden])
        reveal.rearm()
        clickWhenSettled(item, retriesLeft: 1, deadline: Self.reflowDelay)
    }

    /// Re-list after the spacer's drop and click where the item landed.
    /// A target still parked off the row means the reflow has not
    /// settled — wait one more beat rather than clicking the stash's
    /// offscreen bounds.
    private func clickWhenSettled(_ item: MenuBarItem, retriesLeft: Int, deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hider.reconcile()
                let all = self.lastPlan.shown + self.lastPlan.hidden + self.lastPlan.alwaysHidden
                let target = all.first { $0.id == item.id } ?? item
                if retriesLeft > 0 && !target.bounds.intersects(MenuBarItemLister.menuBarRow()) {
                    self.clickWhenSettled(item, retriesLeft: retriesLeft - 1,
                                          deadline: Self.reflowRetryDelay)
                    return
                }
                Self.postClick(at: CGPoint(x: target.bounds.midX, y: target.bounds.midY))
            }
        }
    }

    /// A ⌘-click on a tile: pull the item up into the hidden run and
    /// drop the spacer so it shows — the always-hidden section's own
    /// reveal gesture.
    private func revealItem(_ item: MenuBarItem) {
        setSection(.hidden, for: item.id)
        hider.reveal([.hidden])
        reveal.rearm()
    }

    /// One synthetic click at a Quartz global point.
    nonisolated static func postClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Controls (chevron + always-hidden)

    /// Seed our own items' preferred positions — the system stores them
    /// in our defaults under this key, so the first run lands the
    /// controls near the row's middle rather than wherever the system
    /// happened to drop them. Only ever seeds an absent key: a slot
    /// the person ⌘-dragged to is theirs.
    private static func seedPreferredPosition(_ position: Double, autosaveName: String) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
        }
    }

    /// Match the installed controls to `combinedStatusItem`: the two
    /// separate items when off, the single combined one when on. Safe
    /// to call any time — each half guards on its own reference, so a
    /// settings write mid-run just swaps the set.
    func installChevron() {
        let plan = MenuBarControlPlan.plan(combinedStatusItem: settings().combinedStatusItem)
        if plan.roles == [.combined] {
            removeSeparateControls()
            installCombinedControl()
        } else {
            removeCombinedControl()
            installSeparateControls()
        }
    }

    /// The two-control layout — the chevron plus the always-hidden
    /// item. A no-op when the chevron already stands.
    private func installSeparateControls() {
        guard chevron == nil else { return }
        // Preferred position is a distance from the screen's right
        // edge — larger is further left — so the always-hidden control
        // seeds deeper than the chevron it sits left of.
        Self.seedPreferredPosition(700, autosaveName: "com.jonathanreed.jrbar.menubar-ah-control")
        Self.seedPreferredPosition(660, autosaveName: "com.jonathanreed.jrbar.menubar-chevron")
        let item = NSStatusBar.system.statusItem(withLength: MenuBarControlFrames.glyphLength)
        // The slot is the person's to move (⌘-drag); the autosave name
        // is what lets macOS remember where they put it.
        item.autosaveName = "com.jonathanreed.jrbar.menubar-chevron"
        if let button = item.button {
            Self.style(button, symbol: Self.chevronSymbol(revealed: false),
                       length: MenuBarControlFrames.glyphLength,
                       description: "JR-Bar hidden items")
            button.toolTip = "JR-Bar — items left of this chevron are hidden. Click to reveal; ⌘-drag items across it."
            button.target = chevronActions
            button.action = #selector(MenuBarChevronActions.clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        chevron = item
        let deeper = NSStatusBar.system.statusItem(withLength: MenuBarControlFrames.glyphLength)
        deeper.autosaveName = "com.jonathanreed.jrbar.menubar-ah-control"
        if let button = deeper.button {
            Self.style(button, symbol: "ellipsis", length: MenuBarControlFrames.glyphLength,
                       description: "JR-Bar always-hidden items")
            button.toolTip = "JR-Bar — items left of this are always hidden. Click for the Item Bar."
            button.target = chevronActions
            button.action = #selector(MenuBarChevronActions.alwaysHiddenClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        alwaysHiddenControl = deeper
    }

    /// The combined control: one item whose click opens the Item Bar
    /// and whose right-click pops the covered-item menu — the menu is
    /// where the chevron's reveal/hide job lives in this mode, since
    /// the one click cannot hold both.
    private func installCombinedControl() {
        guard combinedControl == nil else { return }
        Self.seedPreferredPosition(660, autosaveName: "com.jonathanreed.jrbar.menubar-combined")
        let item = NSStatusBar.system.statusItem(withLength: MenuBarControlFrames.glyphLength)
        item.autosaveName = "com.jonathanreed.jrbar.menubar-combined"
        if let button = item.button {
            Self.style(button, symbol: Self.chevronSymbol(revealed: hider.revealed.contains(.hidden)),
                       length: MenuBarControlFrames.glyphLength,
                       description: "JR-Bar hidden items")
            button.toolTip = "JR-Bar — hidden items (click: Item Bar, right-click: list)"
            button.target = chevronActions
            button.action = #selector(MenuBarChevronActions.combinedClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        combinedControl = item
    }

    /// Drop the separate pair — combined mode's side of the swap.
    private func removeSeparateControls() {
        for item in [chevron, alwaysHiddenControl].compactMap({ $0 }) {
            item.button?.target = nil
            item.button?.action = nil
            NSStatusBar.system.removeStatusItem(item)
        }
        chevron = nil
        alwaysHiddenControl = nil
    }

    /// Drop the combined item — separate mode's side of the swap.
    private func removeCombinedControl() {
        guard let combinedControl else { return }
        combinedControl.button?.target = nil
        combinedControl.button?.action = nil
        NSStatusBar.system.removeStatusItem(combinedControl)
        self.combinedControl = nil
    }

    /// The whole teardown: off the bar, target/action dropped, the
    /// references nil — a disable can never leave a dead control parked
    /// and a re-enable never stacks a second one (the installs guard
    /// on the references).
    func removeChevron() {
        removeSeparateControls()
        removeCombinedControl()
    }

    /// Left-click toggles the hidden run; right-click (or ⌥-click)
    /// opens the Item Bar.
    fileprivate func chevronClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            bar.toggle()
        } else {
            toggleHiddenSection()
        }
    }

    /// The always-hidden control's click: the Item Bar is the deeper
    /// run's only surface.
    fileprivate func alwaysHiddenControlClicked() {
        bar.toggle()
    }

    /// The combined item's click: left opens the Item Bar; right (or
    /// ⌥-click) pops the covered-item menu — which is also where the
    /// hidden run's toggle lives in this mode.
    fileprivate func combinedClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            presentCombinedMenu()
        } else {
            bar.toggle()
        }
    }

    /// Build the covered-item menu from the current plan and pop it
    /// under the combined item. Setting `menu` for the click is the
    /// standard right-click trick — a permanent `menu` would swallow
    /// the left click, so it is attached, clicked, and detached.
    private func presentCombinedMenu() {
        guard let item = combinedControl, let button = item.button else { return }
        let menu = NSMenu()
        for entry in MenuBarCombinedMenu.entries(
            plan: lastPlan, hiddenRevealed: hider.revealed.contains(.hidden)) {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .toggleHidden:
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarChevronActions.menuToggleHidden(_:)),
                    keyEquivalent: "")
                menuItem.target = chevronActions
                menu.addItem(menuItem)
            case .openBar:
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarChevronActions.menuOpenBar(_:)),
                    keyEquivalent: "")
                menuItem.target = chevronActions
                menu.addItem(menuItem)
            case .item(let id, _):
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarChevronActions.menuItemClicked(_:)),
                    keyEquivalent: "")
                menuItem.target = chevronActions
                menuItem.representedObject = id
                if let listed = (lastPlan.hidden + lastPlan.alwaysHidden)
                    .first(where: { $0.id == id }) {
                    let icon = listed.owner?.icon
                    icon?.size = NSSize(width: 16, height: 16)
                    menuItem.image = icon
                }
                menu.addItem(menuItem)
            case .more:
                let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            }
        }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    /// The menu's covered-item rows land here: activate the item the
    /// same way a tile click does.
    fileprivate func menuItemActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = (lastPlan.hidden + lastPlan.alwaysHidden)
                .first(where: { $0.id == id }) else { return }
        trigger(item)
    }

    /// The menu's toggle row lands here.
    fileprivate func menuToggleHiddenActivated() {
        toggleHiddenSection()
    }

    /// One click, one transition — a double-fired action or a stray
    /// second delivery inside this window must not toggle twice and
    /// leave the run flapping between states.
    @ObservationIgnored private var lastChevronToggleAt = Date.distantPast
    /// The chevron's own reveal: drop the hidden spacer and start the
    /// rehide clock, or stand it back up when the run is already out.
    /// Hide and reveal are mutually exclusive — a manual hide cancels
    /// the rehide clock outright rather than leaving it armed to fire
    /// a second `onHide` after the spacers already stand.
    private func toggleHiddenSection() {
        let now = Date()
        guard now.timeIntervalSince(lastChevronToggleAt) > 0.3 else { return }
        lastChevronToggleAt = now
        if hider.revealed.contains(.hidden) {
            reveal.cancelReveal()
            hider.hide()
        } else {
            hider.reveal([.hidden])
            reveal.rearm()
        }
        refreshChevron()
    }

    /// The glyph points at where the items are: left while they are
    /// packed off the left edge, right while the run is out. Redrawn
    /// at the control's current length so it stays flush right.
    private func refreshChevron() {
        let symbol = Self.chevronSymbol(revealed: hider.revealed.contains(.hidden))
        for item in [chevron, combinedControl].compactMap({ $0 }) {
            guard let button = item.button else { continue }
            Self.style(button, symbol: symbol, length: item.length,
                       description: "JR-Bar hidden items")
        }
    }

    private static func chevronSymbol(revealed: Bool) -> String {
        revealed ? "chevron.right" : "chevron.left"
    }

    /// The hider's length write: the control claims `length` points,
    /// its glyph redrawn flush right so the spacer part reads as empty
    /// bar.
    private func setControlLength(_ section: MenuBarItemSection, length: CGFloat) {
        let item: NSStatusItem?
        let symbol: String
        let description: String
        switch section {
        case .hidden:
            item = chevron ?? combinedControl
            symbol = Self.chevronSymbol(revealed: hider.revealed.contains(.hidden))
            description = "JR-Bar hidden items"
        case .alwaysHidden:
            item = alwaysHiddenControl
            symbol = "ellipsis"
            description = "JR-Bar always-hidden items"
        case .shown:
            return
        }
        guard let item, let button = item.button else { return }
        if abs(item.length - length) >= 1 { item.length = length }
        Self.style(button, symbol: symbol, length: length, description: description)
    }

    /// A control's face: a template image as wide as the control with
    /// the glyph in its right-most `glyphLength`, so an expanded control
    /// draws its glyph exactly where the collapsed one did and the rest
    /// is the bar's own material.
    private static func style(_ button: NSStatusBarButton, symbol: String,
                              length: CGFloat, description: String) {
        button.image = controlImage(symbol: symbol, length: length, description: description)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.alignment = .right
    }

    /// The composite face image; pure over its inputs so a test can pin
    /// the size.
    nonisolated static func controlImage(symbol: String, length: CGFloat,
                                         description: String) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) else { return nil }
        let glyphSize = glyph.size
        let height: CGFloat = 18
        let width = max(length, MenuBarControlFrames.glyphLength) - 8
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let x = width - (MenuBarControlFrames.glyphLength - 8) / 2 - glyphSize.width / 2
            let y = (height - glyphSize.height) / 2
            glyph.draw(in: NSRect(x: x, y: y, width: glyphSize.width, height: glyphSize.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// A control's live frame in Quartz coordinates (top-left origin),
    /// off its button's window; nil when the control is not installed
    /// or has no window yet.
    private static func quartzFrame(of item: NSStatusItem?) -> CGRect? {
        guard let frame = item?.button?.window?.frame else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: height - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    // MARK: Permissions

    /// The card's "Open Settings" for the click-through row.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - MenuBarActionsDelegate

/// The actions facade's seam: every command-bar row, hotkey and
/// trigger lands on the same machinery the card rows use. (Same file
/// — `trigger` and friends are fileprivate-adjacent privates.)
extension MenuBarUtility: MenuBarActionsDelegate {
    func menuBarItems(for _: MenuBarActions) -> [MenuBarItem] { listedItems }

    func menuBarSections(for _: MenuBarActions) -> [String: MenuBarItemSection] {
        settings().sections
    }

    func menuBarArrangeOrder(for _: MenuBarActions) -> [String] {
        settings().arrangeOrder
    }

    func menuBarArrangeBoundary(for _: MenuBarActions) -> CGFloat {
        MenuBarArrangePlan.rightBoundary(
            items: listedItems,
            regionMax: CGDisplayBounds(CGMainDisplayID()).maxX,
            row: MenuBarItemLister.menuBarRow())
    }

    func menuBarActions(_: MenuBarActions, setSection section: MenuBarItemSection,
                        for itemID: String) {
        setSection(section, for: itemID)
    }

    func menuBarActions(_: MenuBarActions, openItem itemID: String) {
        guard let item = listedItems.first(where: { $0.id == itemID }) else { return }
        trigger(item)
    }

    func menuBarActionsRevealHidden(_: MenuBarActions) {
        hider.reveal([.hidden])
        reveal.rearm()
    }

    func menuBarActions(_: MenuBarActions, revealFor seconds: Double) {
        hider.reveal([.hidden])
        reveal.rearm(for: seconds)
    }

    func menuBarActionsHideAll(_: MenuBarActions) {
        update { $0.sections = MenuBarCommands.hideAllSections(items: listedItems) }
    }

    func menuBarActionsShowAll(_: MenuBarActions) {
        update { $0.sections = [:] }
    }

    func menuBarActions(_: MenuBarActions, applyProfile name: String) {
        if name == MenuBarProfiles.noneName {
            applyProfile(id: MenuBarProfiles.noneID)
        } else if let profile = settings().profiles.first(where: { $0.name == name }) {
            applyProfile(id: profile.id)
        }
        // An unknown name is a no-op, not a clear — never fall through
        // to `apply(nil)` on a mistyped trigger.
    }

    /// The profile cursor for cycling — which id is live, tracked at
    /// runtime (the card's picker owns its own selection). Index 0 is
    /// the built-in "None".
    func menuBarActions(_: MenuBarActions, cycleProfile direction: Int) {
        let profiles = settings().profiles
        let count = profiles.count + 1
        guard count > 1 else { return }
        profileCursor = ((profileCursor + direction) % count + count) % count
        applyProfile(id: profileCursor == 0 ? MenuBarProfiles.noneID
                                            : profiles[profileCursor - 1].id)
    }
}

/// The chevron button's target: an `NSObject` shim so `MenuBarUtility`
/// stays a plain `@Observable` class (the `BuddyMenuActions` pattern).
/// The button's action only ever fires on the main thread.
@MainActor
private final class MenuBarChevronActions: NSObject {
    weak var utility: MenuBarUtility?

    @objc func clicked(_ sender: Any?) {
        utility?.chevronClicked()
    }

    @objc func alwaysHiddenClicked(_ sender: Any?) {
        utility?.alwaysHiddenControlClicked()
    }

    @objc func combinedClicked(_ sender: Any?) {
        utility?.combinedClicked()
    }

    @objc func menuToggleHidden(_ sender: NSMenuItem) {
        utility?.menuToggleHiddenActivated()
    }

    @objc func menuOpenBar(_ sender: NSMenuItem) {
        utility?.bar.toggle()
    }

    @objc func menuItemClicked(_ sender: NSMenuItem) {
        utility?.menuItemActivated(sender)
    }
}
