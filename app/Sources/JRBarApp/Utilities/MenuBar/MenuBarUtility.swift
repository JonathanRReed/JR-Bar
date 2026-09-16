import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility (docs/UTILITIES.md): owns the hider's spacer
/// and override covers, the reveal gestures, the glass Item Bar, and
/// the boundary — JR-Bar's own status item, hosting the hidden run's
/// spacer. `UtilitiesStore` keeps it; the page's card reads it as a
/// `Toy`, so one shell serves every utility.
///
/// The model is Bartender's: items left of the JR-Bar icon are hidden
/// and the person ⌘-drags items across the icon to choose; "always
/// hidden" is an override (a cover where the item sits) rather than a
/// second boundary — a second status item of ours swapped places with
/// the first on every reflow. Hiding is the boundary growing a spacer
/// that packs those items off the row into macOS's own overflow;
/// revealing collapses it. The object itself is
/// a façade — the rules live in the pieces it wires: `MenuBarItemHider`
/// measures and plans, `MenuBarReveal` decides what counts as a
/// gesture, and the boundary's click toggles the run by hand. Nothing
/// here posts mouse events: tile clicks go through `AXPress` — the one
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
    /// The macOS 27 engine: `MenuBarAgent` conceals the hidden apps
    /// itself (`MenuBarConcealer`). nil where the private framework
    /// does not resolve — the spacer engine stands in then.
    @ObservationIgnored private(set) var concealer: MenuBarConcealer?
    /// The click bridge for the system's own items while an assertion
    /// is live.
    @ObservationIgnored private var clickBridge: MenuBarSystemClickBridge?
    /// Items of every app the listing has ever seen this run, by bundle
    /// identifier — a concealed app's items leave the Accessibility
    /// tree, and the card and the Item Bar still list them from here.
    @ObservationIgnored private var knownItems: [String: [MenuBarItem]] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// Whether the concealer drives hiding right now.
    var concealing: Bool { concealer != nil }
    @ObservationIgnored private var ownAdoptionLogged = false
    /// When the concealer came up — the first assertion waits
    /// `adoptionGrace` past it so a relaunch's dying assertion has
    /// drained and our own icon is adopted by the agent first.
    @ObservationIgnored private var concealerStartedAt = Date.distantPast
    @ObservationIgnored private var adoptionRetries = 0
    @ObservationIgnored private var adoptionCheck: Task<Void, Never>?
    nonisolated static let adoptionGrace: TimeInterval = 2.5

    /// The boundary's host — the app's own status item. Everything
    /// left of it is the hidden run; it grows the spacer, draws the
    /// hint, takes the reveal click and carries the hidden-items
    /// submenu. Without a host the fallback chevron item stands in.
    @ObservationIgnored weak var host: (any MenuBarBoundaryHost)? {
        didSet {
            host?.onBoundaryClick = { [weak self] in self?.boundaryClicked() }
            host?.hiddenItemsMenu = { [weak self] in self?.hiddenItemsMenu() }
            if running { installChevron(); hider.controlsReinstalled() }
        }
    }

    init() {
        hider.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        hider.onPlan = { [weak self] plan in
            guard let self else { return }
            if self.concealer != nil, !self.seedConcealedAppsIfNeeded(from: plan) {
                self.lastPlan = plan
                return
            }
            self.lastPlan = self.concealer == nil ? plan : self.concealedPlan(from: plan)
            self.refreshChevron()
            self.publishEarAvoidance(self.lastPlan)
            self.syncConcealer()
        }
        // Our own control is never covered — its live frame splits
        // cover runs even on the no-AX path where it cannot list.
        hider.protectedFrames = { [weak self] in
            guard let self, let frame = self.controlFrames().hidden else { return [] }
            return [frame]
        }
        hider.controlFrames = { [weak self] in
            self?.controlFrames() ?? MenuBarControlFrames()
        }
        hider.setControlLength = { [weak self] section, length in
            self?.setControlLength(section, length: length)
        }
        reveal.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        // The reveal zone is the row minus the *visible* items — the
        // covered stretch is exactly the space a gesture lands on.
        reveal.itemFrames = { [weak self] in self?.shownItemFrames() ?? [] }
        reveal.revealZone = { [weak self] in self?.revealZone() }
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
    }

    // MARK: Toy

    let id = "menuBar"
    let name = "Menu Bar"
    let blurb = "Tuck menu bar items away behind the JR-Bar icon — hover, click or scroll the blank stretch to bring them back."
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
        if concealer != nil {
            guard let item = listedItems.first(where: { $0.id == itemID }),
                  let bundleID = item.bundleID, !MenuBarItemLister.isProtected(item),
                  bundleID != Bundle.main.bundleIdentifier else { return }
            update { draft in
                if section == .shown { draft.concealedApps[bundleID] = nil } else { draft.concealedApps[bundleID] = section }
            }
            hider.reconcile()
            return
        }
        update { draft in
            draft.sections = MenuBarItemHider.updatedSections(
                items: listedItems, sections: draft.sections,
                changedID: itemID, target: section)
        }
    }

    /// The section an item's app is in under the concealer; the item
    /// map's answer otherwise.
    func effectiveSection(for item: MenuBarItem) -> MenuBarItemSection {
        if concealer != nil, let id = item.bundleID { return settings().concealedApps[id] ?? .shown }
        return section(for: item.id)
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

    /// Under the position model the chevron's slot *is* the setting.
    /// The controls seed once at `seedPreferredPosition`'s slots and the
    /// person ⌘-drags them from there — exactly Bartender's onboarding.
    /// An automatic seat next to JR-Bar's own item was tried and
    /// removed: a status item's preferred position is a sort key
    /// against other apps' stored keys, not an x, and steering it
    /// blind left the controls in the wrong place on a real bar.

    private func start() {
        guard !running else { return }
        running = true
        probeAccessibility()
        installChevron()
        if MenuBarAssessmentBackend.isAvailable, host != nil {
            startConcealer()
        }
        hider.start()
        reveal.start()
        // Bindings land before start so registration uses the persisted
        // set, not the defaults the actions object was built with.
        syncActions()
        actions.start()
        // First AX fill — a no-op without the grant — then reconcile
        // against real frames.
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            self?.hider.reconcile()
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
        stopConcealer()
        removeChevron()
        running = false
    }

    // MARK: The concealer (macOS 27)

    /// Bring the agent-side engine up: the hider keeps listing and
    /// planning (the card, the Item Bar, the reveal clock all read its
    /// plan) but never grows a spacer or draws a cover; the plan's
    /// sections come from the per-app map; the bridge takes the
    /// system's clicks.
    private func startConcealer() {
        let concealer = MenuBarConcealer()
        concealer.onChange = { [weak self] in self?.concealerChanged() }
        self.concealer = concealer
        concealerStartedAt = Date()
        adoptionRetries = 0
        hider.shuttersSuppressed = true
        host?.setBoundarySpacer(0)
        let bridge = MenuBarSystemClickBridge { [weak self] point in
            self?.bridgeClick(at: point)
        }
        bridge.start()
        clickBridge = bridge
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let concealer = self.concealer else { return }
                    // The agent defers adopting an item registered while an
                    // assertion holds: a beat with no assertion lets a
                    // freshly launched app's item land before the
                    // allowlist (now including it) goes back up.
                    self.syncConcealer()
                    Task { await concealer.suspend(for: MenuBarConcealer.adoptionBeat) }
                }
            })
        }
        MenuBarAssessmentBackend.log.notice("conceal: engine up (MenuBarClientCore resolved)")
    }

    private func stopConcealer() {
        guard let concealer else { return }
        concealer.releaseAll()
        clickBridge?.stop()
        clickBridge = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        hider.shuttersSuppressed = false
        self.concealer = nil
    }

    /// The bundle identifiers of every running app — the allowlist's
    /// universe. An app that launches later is re-applied for by the
    /// workspace observers.
    private static func runningBundleIDs() -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Ourselves, always: the workspace list can omit the current
        // process, and an allowlist without us concealed our own icon.
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    /// The plan the card and the Item Bar read under the concealer: the
    /// listing's shown items minus the concealed apps, and every
    /// concealed app's remembered items as the hidden runs. The spacer
    /// model's positional sections mean nothing here — the agent
    /// reorders the bar on its own.
    private func concealedPlan(from listing: MenuBarHidePlan) -> MenuBarHidePlan {
        let all = listing.shown + listing.hidden + listing.alwaysHidden
        var seen: [String: [MenuBarItem]] = [:]
        for item in all {
            guard let id = item.bundleID else { continue }
            seen[id, default: []].append(item)
        }
        for (id, items) in seen { knownItems[id] = items }
        let apps = settings().concealedApps
        var plan = MenuBarHidePlan()
        let row = MenuBarItemLister.menuBarRow()
        plan.shown = all.filter { item in
            guard let id = item.bundleID, let section = apps[id] else { return true }
            return section == .shown
        }.filter { $0.bounds.intersects(row) || MenuBarItemLister.isProtected($0) }
        for (id, section) in apps.sorted(by: { $0.key < $1.key }) {
            let items = knownItems[id] ?? []
            switch section {
            case .hidden: plan.hidden.append(contentsOf: items)
            case .alwaysHidden: plan.alwaysHidden.append(contentsOf: items)
            case .shown: break
            }
        }
        return plan
    }

    /// The first map, once: whatever the spacer model would have hidden
    /// — the apps whose items sit left of the JR-Bar icon — becomes
    /// hidden. Runs on the first listing that shows the boundary.
    private func seedConcealedAppsIfNeeded(from listing: MenuBarHidePlan) -> Bool {
        guard !settings().concealSeeded else { return true }
        guard listing.shown.contains(where: { !Self.isForeignOwner($0.ownerName) }) else { return false }
        let own = Bundle.main.bundleIdentifier ?? "com.jonathanreed.jrbar"
        let map = MenuBarConcealPlan.seed(
            hidden: listing.hidden.map { ($0, $0.bundleID) },
            alwaysHidden: listing.alwaysHidden.map { ($0, $0.bundleID) },
            own: own)
        update { draft in
            draft.concealedApps = map
            draft.concealSeeded = true
        }
        MenuBarAssessmentBackend.log.notice("conceal: seeded \(map.count, privacy: .public) apps from the spacer plan")
        return true
    }

    /// Hand the concealer its target for the current reveal state.
    private func syncConcealer() {
        guard let concealer else { return }
        // Nothing of ours grows under the agent — whatever the spacer
        // engine wrote on the seeding pass folds back.
        host?.setBoundarySpacer(0)
        // Not before our own icon stands on the row: an item registered
        // while an assertion holds is not adopted by the agent, and the
        // first assertion at launch left JR-Bar's own icon parked
        // unseen (measured 2026-09-16).
        let settled = !ownIconStale()
            && Date().timeIntervalSince(concealerStartedAt) >= Self.adoptionGrace
        guard settled || concealer.isConcealing else {
            if !ownAdoptionLogged {
                ownAdoptionLogged = true
                MenuBarAssessmentBackend.log.notice("conceal: waiting for our own icon to land before the first assertion")
            }
            return
        }
        var concealed = MenuBarConcealPlan.concealed(apps: settings().concealedApps,
                                                     revealed: hider.revealed)
        if let own = Bundle.main.bundleIdentifier { concealed.remove(own) }
        concealer.apply(concealed: concealed, running: Self.runningBundleIDs())
        clickBridge?.update(items: lastPlan.shown, concealing: !concealed.isEmpty)
    }

    private func concealerChanged() {
        clickBridge?.update(items: lastPlan.shown, concealing: concealer?.isConcealing ?? false)
        refreshChevron()
        scheduleAdoptionCheck()
    }

    /// Our own icon, as the agent draws it: an item the agent has not
    /// adopted keeps a frame from before — stacked on a neighbour, or
    /// off the row. A stale icon after an assertion means the agent
    /// deferred it; a beat with no assertion lets it land (Pelmet's
    /// adoption window), three tries at most.
    private func ownIconStale() -> Bool {
        let row = MenuBarItemLister.menuBarRow()
        guard let own = lastPlan.shown.first(where: { !Self.isForeignOwner($0.ownerName) }) else { return true }
        guard own.bounds.intersects(row) else { return true }
        let concealed = concealer?.concealedApps ?? []
        return lastPlan.shown.contains { other in
            Self.isForeignOwner(other.ownerName) && other.bounds.intersects(row)
                && other.bundleID.map { !concealed.contains($0) } ?? true
                && other.bounds.intersection(own.bounds).width > 3
        }
    }

    private func scheduleAdoptionCheck() {
        adoptionCheck?.cancel()
        adoptionCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, let concealer = self.concealer, concealer.isConcealing else { return }
            _ = await MenuBarItemLister.refreshAXItems()
            self.hider.reconcile()
            guard self.ownIconStale(), self.adoptionRetries < 3 else { return }
            self.adoptionRetries += 1
            MenuBarAssessmentBackend.log.notice("conceal: our own icon reads stale under the assertion — adoption window \(self.adoptionRetries, privacy: .public)/3")
            await concealer.suspend(for: 0.8)
        }
    }

    /// A held-back click on the clock, battery or Wi-Fi: lift, replay,
    /// let concealment return.
    private func bridgeClick(at point: CGPoint) {
        guard let concealer else { return }
        Task { @MainActor in
            await concealer.suspend(for: MenuBarSystemClickBridge.liftWindow)
            try? await Task.sleep(nanoseconds: UInt64(MenuBarSystemClickBridge.liftDelay * 1e9))
            MenuBarSystemClickBridge.replay(at: point)
        }
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

    /// Anyone's item but ours — the system's extras included: a gesture
    /// must respect the clock and Wi-Fi, never our own spacer.
    nonisolated static func isForeignOwner(_ owner: String) -> Bool {
        !["JR-Bar", "JRBarApp"].contains(owner)
    }

    /// The on-row items a click should count as "on an item" — the
    /// shown zone only. Covered items are the reveal zone itself.
    /// Frames arrive in Quartz and flip to AppKit for the hit test.
    private func shownItemFrames() -> [NSRect] {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        // The « is covered while the run is hidden — a click on it is
        // the reveal, not a click on an item. Our own items are the
        // boundary and the controls: the host's frame spans the whole
        // blank stretch, which is exactly the zone a gesture lands on.
        return lastPlan.shown.filter {
            !$0.isNativeOverflowControl && Self.isForeignOwner($0.ownerName)
        }.map {
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
        if concealer != nil, let id = item.bundleID,
           MenuBarConcealPlan.concealed(apps: settings().concealedApps, revealed: hider.revealed).contains(id) {
            // Concealed: the element is not in the tree. Reveal the run
            // (the rehide clock takes it back), give the agent a beat
            // to draw the item, then press it where it landed.
            hider.reveal([.hidden, .alwaysHidden])
            reveal.rearm()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                _ = await MenuBarItemLister.refreshAXItems()
                let fresh = MenuBarItemLister.axItems.first { $0.id == item.id } ?? item
                if MenuBarAX.press(fresh) { return }
                await MainActor.run { self?.clickFallback(fresh) }
            }
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

    // MARK: The boundary

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

    /// The boundary. With a host — the app's own status item — the
    /// boundary is the host and no chevron item exists; without one
    /// (tests, a build that never wired it) the separate chevron stands
    /// in. Safe to call any time — it guards on its own reference.
    func installChevron() {
        if host == nil {
            installChevronItem()
        } else if chevron != nil {
            removeChevronItem()
        }
        // The always-hidden control of earlier builds left its slot in
        // our defaults; a stale key is harmless but says nothing true.
        UserDefaults.standard.removeObject(
            forKey: "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-ah-control")
    }

    /// The fallback chevron: a status item of its own.
    private func installChevronItem() {
        guard chevron == nil else { return }
        Self.seedPreferredPosition(660, autosaveName: "com.jonathanreed.jrbar.menubar-chevron")
        let item = NSStatusBar.system.statusItem(withLength: MenuBarControlFrames.glyphLength)
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
    }

    private func removeChevronItem() {
        guard let chevron else { return }
        chevron.button?.target = nil
        chevron.button?.action = nil
        NSStatusBar.system.removeStatusItem(chevron)
        self.chevron = nil
    }

    /// The whole teardown: off the bar, target/action dropped, the
    /// reference nil, the host's spacer folded — a disable can never
    /// leave a dead control parked and a re-enable never stacks a
    /// second one (the install guards on the reference).
    func removeChevron() {
        removeChevronItem()
        host?.setBoundarySpacer(0)
        host?.hiddenCount = 0
        host?.hiddenRevealed = false
        ScreenBarGeometry.earAvoidScreenRect = nil
    }

    /// Left-click on the fallback chevron toggles the hidden run;
    /// right-click (or ⌥-click) opens the Item Bar.
    fileprivate func chevronClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            bar.toggle()
        } else {
            toggleHiddenSection()
        }
    }

    /// The host's blank stretch was clicked: the hidden run toggles.
    fileprivate func boundaryClicked() {
        toggleHiddenSection()
    }

    /// The "Hidden Menu Bar Items" submenu the host's menu carries: the
    /// reveal/hide toggle, the Item Bar, then every hidden item with an
    /// activate action. nil while the utility is parked, so the menu
    /// row disappears with it.
    fileprivate func hiddenItemsMenu() -> NSMenu? {
        guard running else { return nil }
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
        return menu
    }

    /// The menu's hidden-item rows land here: activate the item the
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
    /// The deliberate reveal: collapse the spacer and start the rehide
    /// clock, or stand it back up when the run is already out. Hide and
    /// reveal are mutually exclusive — a manual hide cancels the rehide
    /// clock outright rather than leaving it armed to fire a second
    /// `onHide` after the spacer already stands.
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

    /// The faces follow the run's state: the fallback chevron points at
    /// where the items are (left while they are packed off the left
    /// edge, right while the run is out); the host takes the counts and
    /// draws its own hint.
    private func refreshChevron() {
        if let host {
            host.hiddenCount = lastPlan.hidden.count + lastPlan.alwaysHidden.count
            host.hiddenRevealed = hider.revealed.contains(.hidden)
        }
        guard let chevron, let button = chevron.button else { return }
        Self.style(button, symbol: Self.chevronSymbol(revealed: hider.revealed.contains(.hidden)),
                   length: chevron.length, description: "JR-Bar hidden items")
    }

    private static func chevronSymbol(revealed: Bool) -> String {
        revealed ? "chevron.right" : "chevron.left"
    }

    /// The hider's length write. For the hidden run the host takes
    /// everything past its own glyph as spacer (a length at or under
    /// the glyph folds it); the fallback chevron takes the whole length
    /// and redraws its glyph flush right so the spacer part reads as
    /// empty bar.
    private func setControlLength(_ section: MenuBarItemSection, length: CGFloat) {
        if concealer != nil {
            // The agent hides; nothing of ours ever grows.
            host?.setBoundarySpacer(0)
            return
        }
        switch section {
        case .hidden:
            if let host {
                host.setBoundarySpacer(max(0, length - host.boundaryGlyphLength))
                return
            }
            guard let chevron, let button = chevron.button else { return }
            if abs(chevron.length - length) >= 1 { chevron.length = length }
            Self.style(button, symbol: Self.chevronSymbol(revealed: hider.revealed.contains(.hidden)),
                       length: length, description: "JR-Bar hidden items")
        case .alwaysHidden, .shown:
            return
        }
    }

    /// The live control frame for the hider: the host's item (or the
    /// fallback chevron), with the boundary's glyph share.
    private func controlFrames() -> MenuBarControlFrames {
        // Under the concealer there is no boundary once the map is
        // seeded: no positional sections, no spacer, no « to read.
        if concealer != nil, settings().concealSeeded { return MenuBarControlFrames() }
        return MenuBarControlFrames(
            hidden: host?.boundaryFrame ?? Self.quartzFrame(of: chevron),
            hiddenGlyph: host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength)
    }

    /// The « the run hides beside, handed to the Screen Bar so its right
    /// ear stops short of it (screen coordinates, AppKit). nil when the
    /// run is revealed or nothing is hidden.
    private func publishEarAvoidance(_ plan: MenuBarHidePlan) {
        let rect: NSRect? = plan.overflowControlFrame.map { frame in
            let height = CGDisplayBounds(CGMainDisplayID()).height
            return NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        }
        if ScreenBarGeometry.earAvoidScreenRect != rect {
            ScreenBarGeometry.earAvoidScreenRect = rect
        }
    }

    /// The stretch a hover or an empty-space click reveals: from the
    /// region's edge to the boundary glyph's right edge, in AppKit
    /// screen coordinates. nil while no boundary stands.
    private func revealZone() -> NSRect? {
        let frames = controlFrames()
        guard let boundary = frames.hidden else { return nil }
        let row = MenuBarItemLister.menuBarRow()
        guard boundary.intersects(row) else { return nil }
        if concealer != nil {
            // No blank stretch of ours: the zone is the empty bar from
            // the notch's edge to the leftmost shown item on the right.
            let height = CGDisplayBounds(CGMainDisplayID()).height
            let leftmost = lastPlan.shown
                .filter { $0.bounds.intersects(row) && $0.bounds.minX > row.midX }
                .map(\.bounds.minX).min() ?? boundary.minX
            let edge = NSScreen.main?.auxiliaryTopRightArea?.minX ?? row.midX
            let minX = min(edge, leftmost)
            return NSRect(x: minX, y: height - row.maxY,
                          width: max(0, leftmost - minX), height: row.height)
        }
        // The blank stretch starts where the spacer may land, less the
        // room the « takes — a gesture on the « is a gesture on the run.
        let edge = (hider.fitEdge ?? boundary.minX) - 30
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let minX = min(edge, boundary.minX)
        return NSRect(x: minX, y: height - row.maxY,
                      width: max(0, boundary.maxX - minX), height: row.height)
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

/// The boundary's host: what the Menu Bar utility needs from the app's
/// own status item to make it the hidden run's edge — its frame, its
/// icon's width, a spacer write, the reveal click, the hidden-items
/// submenu, and the counts it draws its hint from.
@MainActor
protocol MenuBarBoundaryHost: AnyObject {
    /// The item's frame in Quartz coordinates; nil before it has a window.
    var boundaryFrame: CGRect? { get }
    /// The icon's own width — the part that is not spacer.
    var boundaryGlyphLength: CGFloat { get }
    /// Claim `length` points of blank bar left of the icon (0 folds).
    func setBoundarySpacer(_ length: CGFloat)
    var onBoundaryClick: (@MainActor () -> Void)? { get set }
    var hiddenItemsMenu: (@MainActor () -> NSMenu?)? { get set }
    var hiddenCount: Int { get set }
    var hiddenRevealed: Bool { get set }
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
