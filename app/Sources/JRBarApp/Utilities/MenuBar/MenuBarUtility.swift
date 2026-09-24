import AppKit
import ApplicationServices
import CoreGraphics
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
/// revealing collapses it. Under the macOS 27 concealer the agent hides
/// whole apps instead and reorders the bar itself, so sections there
/// are explicit per app, and the icon is `MenuBarIconMirror` standing at
/// the right end of the blank run. The object itself is
/// a façade — the rules live in the pieces it wires: `MenuBarItemHider`
/// measures and plans, `MenuBarReveal` decides what counts as a
/// gesture, and the boundary's click toggles the run by hand. Tile
/// clicks go through `AXPress`; an element that cannot be resolved
/// raises its app instead — the pointer never moves.
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
    /// The ⌘⇧K command bar, the global hotkeys and the trigger engine
    /// — the utility implements `MenuBarActionsDelegate`
    /// (MenuBarUtilityDelegate.swift) so every action lands on the same machinery
    /// the card's own rows use.
    let actions = MenuBarActions()
    /// The real trigger feed, created once; `syncActions` runs it only
    /// while at least one rule is enabled.
    @ObservationIgnored private let systemTriggerSource = MenuBarSystemTriggerSource()
    /// The "while" rules' runtime — levels, the outcome, and its effects
    /// on the bar, the LED scene and the agents' quiet. The app delegate
    /// wires the scene and quiet closures.
    @ObservationIgnored let stateRules = MenuBarStateRunner()
    /// Whether the levels were seeded for the rules now enabled.
    @ObservationIgnored private var stateRulesSeeded = false
    /// Whether this launch has checked for a scene a rule held when the
    /// last one quit (`restoreSceneOnce`).
    @ObservationIgnored private var sceneRestoreChecked = false
    /// Bumped whenever the rules' outcome moves, so the card's "holding
    /// now" line observes it.
    private(set) var stateOutcomeVersion = 0
    /// Hotkey registrations the system refused — a key another app
    /// already owns. Mirrored out of `actions.hotkeys` after each
    /// registration pass so the card's note observes it.
    private(set) var failedHotkeyActions: Set<MenuBarHotkeyAction> = []
    /// The system-item click bridge could not install its event tap —
    /// Accessibility is missing, so clicks on the clock, battery and
    /// Wi-Fi stay native while the run is concealed. Set from the
    /// bridge's own start, not inferred.
    var clickBridgeFailed = false

    /// The latest layout — the card's count row and item list read it.
    /// While the utility runs the hider keeps it fresh; while it is
    /// parked the card's `refreshListing()` fills it once, spacers down.
    var lastPlan = MenuBarHidePlan()
    /// Spacers parked, monitors up.
    private(set) var running = false
    /// Accessibility, re-polled at most every `accessibilityPollSeconds`
    /// and probed on a listing refresh, a tile click, and each start —
    /// never per render, per event, or on the reconcile cadence. That is
    /// plain thrift; TCC does not need it: `AXIsProcessTrusted` sends
    /// one `TCCAccessRequest` IPC on its first call only (measured
    /// 2026-09-22; see `MenuBarItemLister.axTrusted`).
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

    /// The hidden-items submenu's target: target/action needs an
    /// `NSObject`, so its rows' clicks land on this box and forward.
    @ObservationIgnored let menuActions = MenuBarMenuActions()
    /// The spacer/label items settings carries — keyed by `Spacer.id`.
    /// Born visible, never re-registered.
    @ObservationIgnored var spacerItems: [String: NSStatusItem] = [:]
    /// The spacer buttons' target — a click reveals like the ‹'s.
    @ObservationIgnored let spacerActions = MenuBarSpacerActions()
    /// The agent-state item and its click target.
    @ObservationIgnored var agentItem: NSStatusItem?
    @ObservationIgnored let agentActions = MenuBarSpacerActions()
    @ObservationIgnored var lastAgentSignature = ""
    /// The combined system item — battery/Wi-Fi/sound/Focus in one.
    @ObservationIgnored let combinedItem = MenuBarCombinedItem()
    /// Whether the CC extras are hidden through our item right now —
    /// the defaults write and the `killall` only run on the flip. Seeded
    /// from the saved originals: a crash can leave them hidden.
    @ObservationIgnored var coveredExtrasHidden = MenuBarCombinedItem.coveredExtrasSaved()
    /// The full-bar tint underlay.
    @ObservationIgnored let underlay = MenuBarUnderlay()
    /// The agent feed's read — wired by the app delegate; the item
    /// asks on every extras sync rather than holding its own watcher.
    var agentState: @MainActor () -> (state: AgentAggregateState, detail: String) = { (.idle, "") }
    /// The agent item's click — opens the Overview.
    var onOpenOverview: () -> Void = {}
    /// The daemon's facts for the rules — the agents, the asks, the
    /// usage headroom, SidePulse. Wired by the app delegate, read on
    /// every `coreFactsChanged()`.
    var coreFacts: @MainActor () -> MenuBarCoreFacts = { MenuBarCoreFacts() }
    /// The facts the rules last heard — samples go out only when a
    /// value moved, so a 20 Hz state stream costs a compare.
    @ObservationIgnored private(set) var lastCoreFacts: MenuBarCoreFacts?
    /// The display whose mapped profile was last applied, and the
    /// pointer-screen sightings a pending switch has collected.
    @ObservationIgnored var activeDisplayKey: String?
    @ObservationIgnored var pendingDisplayKey: (key: String, count: Int)?
    /// The desk the Mac sits at now — the card names it and maps it.
    private(set) var currentDesk: (key: String, name: String)?
    @ObservationIgnored private var deskObserver: Any?
    @ObservationIgnored private var deskRead: Task<Void, Never>?
    /// The macOS 27 engine: `MenuBarAgent` conceals the hidden apps
    /// itself (`MenuBarConcealer`). nil where the private framework
    /// does not resolve — the spacer engine stands in then.
    /// Internal (not private) so a test can inject a fake-backend
    /// concealer and drive `stopConcealer`/`noteWorkspaceChange`.
    @ObservationIgnored var concealer: MenuBarConcealer?
    /// The click bridge for the system's own items while an assertion
    /// is live.
    @ObservationIgnored var clickBridge: MenuBarSystemClickBridge?
    /// Items of every app the listing has ever seen this run, by bundle
    /// identifier — a concealed app's items leave the Accessibility
    /// tree, and the card and the Item Bar still list them from here.
    @ObservationIgnored var knownItems: [String: [MenuBarItem]] = [:]
    @ObservationIgnored var workspaceObservers: [NSObjectProtocol] = []
    /// NSWorkspace enumeration is expensive. Notifications invalidate this
    /// snapshot promptly; a bounded refresh still discovers quiet helpers.
    @ObservationIgnored let runningApps: RunningBundleIDCache
    /// Whether the concealer drives hiding right now.
    var concealing: Bool { concealer != nil }
    /// Whether the agent's mechanism resolves on this macOS at all.
    var concealerAvailable: Bool { MenuBarAssessmentBackend.isAvailable }

    // MARK: Provider — who renders

    /// Re-resolved on every workspace launch/terminate so an external
    /// pick's running/installed state flips live in the card — the
    /// notch's pattern; stored so Observation tracks the read.
    private(set) var workspaceVersion = 0
    /// The provider watch's observers — installed for the object's
    /// life. `workspaceObservers` above is concealer-scoped and torn
    /// down at stop, so this needs its own array.
    @ObservationIgnored private var providerObservers: [NSObjectProtocol] = []

    /// The picked counterpart's probe — nil while JR-Bar renders.
    private var externalProbe: ExternalAppProbe? {
        switch settings().provider {
        case .jrbar: return nil
        case .bartender: return ExternalProviders.bartender
        case .ice: return ExternalProviders.ice
        case .hiddenBar: return ExternalProviders.hiddenBar
        }
    }

    /// The card's write path for the picker — same shape as `bind`.
    var providerBinding: Binding<MenuBarProvider> {
        Binding(get: { self.settings().provider },
                set: { p in self.update { $0.provider = p } })
    }

    /// The counterpart's app URL — the card's "Open" button.
    var externalURL: URL? {
        _ = workspaceVersion
        return externalProbe?.url
    }

    /// What the card's chip says while a counterpart owns the surface —
    /// nil under `.jrbar`, so the header falls back to the engine line.
    var providerNote: String? {
        guard let probe = externalProbe else { return nil }
        _ = workspaceVersion
        let name = providerName
        if !probe.installed { return "\(name) isn't installed — pick JR-Bar or install it" }
        return probe.running
            ? "\(name) is rendering the bar — ours is parked"
            : "\(name) isn't running — ours stays parked"
    }

    /// The picked counterpart's display name for the note.
    private var providerName: String {
        switch settings().provider {
        case .jrbar: return "JR-Bar"
        case .bartender: return "Bartender"
        case .ice: return "Ice"
        case .hiddenBar: return "Hidden Bar"
        }
    }

    /// The card's "Open" — launches the picked counterpart.
    func openExternal() { externalProbe?.open() }
    /// Whether this build passes Gatekeeper — nil until probed.
    private(set) var notarized: Bool?
    /// Which `start()` a pending notarization answer belongs to — a
    /// disable and re-enable inside the probe must not let the stale
    /// answer act on the new run.
    @ObservationIgnored private var startGeneration = 0
    /// When the concealer came up — the first assertion waits
    /// `adoptionGrace` past it so a relaunch's dying assertion has
    /// drained first. Internal (not private) so the seed-race test can
    /// age the engine.
    @ObservationIgnored var concealerStartedAt = Date.distantPast
    nonisolated static let adoptionGrace: TimeInterval = 2.5
    /// How long the seed waits for our own item to list. Past it the
    /// path just marks the map seeded — nothing is inferred from the
    /// listing — so a fresh install never wedges.
    nonisolated static let adoptionTimeout: TimeInterval = 8

    /// The drop zone the boundary always claims while the utility is
    /// on — wide enough for the ‹ mark the host draws inside it. An
    /// invisible stretch of bar is no affordance; Bartender keeps its
    /// separator on the row permanently too.
    static let boundaryAffordance: CGFloat = 30

    /// The boundary's host — the app's own status item. Everything
    /// left of it is the hidden run; it grows the spacer, draws the
    /// hint, takes the reveal click and carries the hidden-items
    /// submenu. Without a host there is no boundary.
    @ObservationIgnored weak var host: (any MenuBarBoundaryHost)? {
        didSet {
            host?.onBoundaryClick = { [weak self] in self?.boundaryClicked() }
            host?.hiddenItemsMenu = { [weak self] in self?.hiddenItemsMenu() }
            host?.onFaceChange = { [weak self] in self?.faceChanged() }
            if running { installBoundary(); hider.controlsReinstalled() }
        }
    }

    init(
        runningBundleIDRead: (@MainActor () -> Set<String>)? = nil,
        monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        runningApps = RunningBundleIDCache(
            read: runningBundleIDRead ?? MenuBarUtility.readRunningBundleIDs,
            monotonic: monotonic
        )
        // The hider plans against the live map — the curated one with
        // Hide all / Show all laid over it — never the stored copy.
        hider.settings = { [weak self] in self?.liveSettings() ?? MenuBarSettings() }
        hider.onPlan = { [weak self] plan in
            guard let self else { return }
            if self.concealer != nil, !self.seedConcealedAppsIfNeeded(from: plan) {
                self.lastPlan = plan
                return
            }
            self.lastPlan = self.concealer == nil ? plan : self.concealedPlan(from: plan)
            // The hider draws the utility-owned plan's covers (items
            // the agent cannot target); nil under the spacer engine,
            // where its own plan rules. Assigned here — the plan
            // callback lands before the shutter pass — so the cover
            // plan never lags a reconcile behind the listing.
            self.hider.externalPlan = self.concealer == nil ? nil : self.lastPlan
            self.watchConcealedEscapees(in: plan)
            self.refreshBoundary()
            // Ear limits read the raw listing — the items physically on
            // the row. The concealed plan's hidden runs carry remembered
            // positions (knownItems) that would gate the ears by ghosts.
            self.publishEarAvoidance(plan)
            self.syncConcealer()
            self.pollDisplayProfile()
            self.bar.syncItems()
            self.refreshExtrasFaces()
            self.photographReveal()
            // The writing passes land off the plan's stack — a settings
            // write inside `onPlan` would nest a whole reconcile inside
            // one, and the updates pass can itself reveal. Deferred like
            // `pollDisplayProfile`'s apply.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.noticeUpdates(in: self.lastPlan)
                self.pruneUninstalledConcealedApps()
                self.noticeNewcomers()
                self.refreshEarFeed()
            }
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
        // Zones where an on-row item is unreachable: the notch band
        // (Quartz x between the aux areas, the row's depth) and the
        // stretch the menus on the bar overdraw — the lister's cached
        // edge of the menu-bar owner's menus, re-read by every AX scan
        // and whenever the menu bar changes hands.
        hider.obscuredFrames = { [weak self] in
            guard let self else { return [] }
            let settings = self.settings()
            guard settings.hideUnderNotch || settings.hideOnMenuOverlap else { return [] }
            let row = MenuBarItemLister.menuBarRow()
            var frames: [CGRect] = []
            if settings.hideUnderNotch, let screen = NSScreen.main,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                frames.append(CGRect(x: left.maxX, y: row.minY,
                                     width: right.minX - left.maxX, height: row.height))
            }
            if settings.hideOnMenuOverlap,
               let edge = MenuBarItemLister.appMenuEdge, edge > row.minX {
                frames.append(CGRect(x: row.minX, y: row.minY,
                                     width: edge - row.minX, height: row.height))
            }
            return frames
        }
        hider.setControlLength = { [weak self] section, length in
            self?.setControlLength(section, length: length)
        }
        reveal.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        // The reveal zone is the row minus the *visible* items — the
        // covered stretch is exactly the space a gesture lands on. The
        // island's ‹ handle counts as an item: the island owns clicks
        // there outright, so the empty-space gesture must stand down.
        reveal.itemFrames = { [weak self] in
            var frames = self?.shownItemFrames() ?? []
            if let handle = ScreenBarGeometry.menuHandleScreenRect { frames.append(handle) }
            return frames
        }
        reveal.revealZone = { [weak self] in self?.revealZone() }
        // The « is the affordance — hovering it reveals too (Bartender's
        // chevron opens on hover), while its click stays its own toggle.
        // The frame is the live control's — the host's boundary — and
        // under the concealer the ear's ‹ handle, its frame published by
        // the screen bar, while it stands.
        reveal.hotFrames = { [weak self] in
            guard let self else { return [] }
            if self.concealer != nil {
                // Under the agent there is no « to point at, and the
                // icon is never a hover target: its click is the panel,
                // and a 0.18 s hover reveal on it would race that click.
                // (Keyed to the old undrawn anchor, this frame sat over
                // the ear's Codex mark and popped the Item Bar from
                // there.) Only the ear's ‹ answers a hover, while it
                // stands; the blank run left of the icon is the zone.
                return [ScreenBarGeometry.menuHandleScreenRect].compactMap { $0 }
            }
            // controlFrames().hidden is Quartz; mouseLocation is AppKit.
            // Without the flip a hover on the « never registers — the
            // spacer engine's hot zone sat at the bottom of the screen
            // (audit 2026-09-21).
            let height = CGDisplayBounds(CGMainDisplayID()).height
            return [self.controlFrames().hidden.map {
                NSRect(x: $0.minX, y: height - $0.maxY,
                       width: $0.width, height: $0.height)
            }, ScreenBarGeometry.menuHandleScreenRect]
                .compactMap { $0 }
        }
        reveal.barFrame = { [weak self] in self?.bar.panelFrame }
        reveal.itemMenuOpen = { [weak self] in self?.listedItemMenuOpen() ?? false }
        // The reveal style picks the surface: `.bar` opens the Item
        // Bar — Bartender's model, the row never un-conceals so the
        // assertion holds and nothing flaps — while `.inline` drops the
        // covers and reflows the run onto the row, Ice and Hidden Bar's
        // model.
        reveal.onReveal = { [weak self] in
            guard let self else { return }
            // A gesture on the Screen Bar's right ear is its peek's —
            // the ear answers it, the bar never opens a second surface.
            guard !self.earAnswersGesture() else { return }
            switch self.settings().revealStyle {
            case .inline:
                self.hider.reveal([.hidden])
            case .bar:
                self.revealBarStyle()
            }
        }
        reveal.onHide = { [weak self] in
            self?.bar.close()
            // The inline reveal's run folds here — and a deliberate
            // per-item pull still owes its fold-back under `.bar`.
            self?.hider.hide()
        }
        bar.items = { [weak self] in self?.barItems() ?? [] }
        bar.glyphFace = { [weak self] item in self?.glyphFace(for: item) }
        // The bar hangs under the icon's ‹ while the mirror carries it —
        // the ‹'s own zone, not the compound face the extras widen.
        bar.anchorFrame = { [weak self] in
            guard let self, self.iconMirrored, let mirror = self.iconMirror,
                  let frame = self.standingMirrorFrame else { return nil }
            return MenuBarIconMirror.chevronFrame(in: frame, hiddenCount: mirror.face.hiddenCount)
        }
        // A concealed item's ghost reports a frozen on-row frame but
        // draws nothing — capturing that rect would tile empty bar.
        // Ghosts take the owner's app icon like parked items do.
        bar.tiles.isCapturable = { [weak self] item in
            self.map { !$0.isConcealedGhost(item) } ?? true
        }
        bar.onTrigger = { [weak self] item in self?.trigger(item) }
        bar.onRevealItem = { [weak self] item in self?.revealItem(item) }
        // The tile's context menu: the same section write the pickers
        // and the palette make — a tile never drags anything itself.
        bar.itemSection = { [weak self] item in
            self.map { $0.effectiveSection(for: item) } ?? .hidden
        }
        bar.onMoveItem = { [weak self] item, section in
            self?.setSection(section, for: item.id)
        }
        // "Show when it changes" — offered only while show for updates is
        // on, so the menu never promises what the feature won't do.
        bar.updateWatch = { [weak self] item in
            guard let self, self.settings().showForUpdates else { return nil }
            return self.watchesUpdates(of: item)
        }
        bar.onUpdateWatch = { [weak self] item, on in self?.setWatchesUpdates(on, for: item) }
        // The combined readout's popover carries the agents' line too —
        // the promised Agent variant, one click from the face.
        combinedItem.agentLine = { [weak self] in self?.combinedAgentLine() }
        bar.onOpenChange = { [weak self] open in
            guard let self else { return }
            self.reveal.holdOpen = open
            // The `.bar`-style half of "hide shown while revealing" —
            // the hider gates on the setting itself, this is only the
            // "a reveal surface is up" signal.
            self.hider.setBarCoveringShown(open)
            if !open {
                self.barClosedAtUptime = ProcessInfo.processInfo.systemUptime
                self.reveal.noteBarClosed()
            } else if self.concealer == nil {
                // Under the spacer engine a covered item still renders
                // under our shutter: photograph the stale ones for the
                // day the concealer takes over.
                self.photograph(self.onRowItems(in: self.barItems()))
            }
        }
        actions.delegate = self
        actions.rules = { [weak self] in self?.settings().triggerRules ?? [] }
        actions.triggerSource = systemTriggerSource
        // The "while" rules hear the feed only while their levels are
        // seeded — which is only ever while the utility runs.
        systemTriggerSource.onSample = { [weak self] event in
            guard let self, self.stateRulesSeeded else { return }
            self.stateRules.absorb(event)
        }
        stateRules.rules = { [weak self] in self?.settings().curation.stateRules ?? [] }
        stateRules.sceneBeforeRule = { [weak self] in self?.settings().curation.sceneBeforeRule }
        stateRules.setSceneBeforeRule = { [weak self] scene in
            self?.update { $0.curation.sceneBeforeRule = scene }
        }
        // A stopped hider is never re-planned: its reconcile would put
        // covers back over a bar the utility just gave up.
        stateRules.onLayersChange = { [weak self] in
            guard let self, self.running else { return }
            self.hider.reconcile()
        }
        stateRules.onOutcomeChange = { [weak self] in self?.stateOutcomeVersion += 1 }
        menuActions.utility = self
        spacerActions.onClick = { [weak self] in self?.spacerClicked() }
        agentActions.onClick = { [weak self] in self?.onOpenOverview() }
        // Provider watch: a counterpart launching or quitting flips
        // the card's note live — the concealer's own launch watch is
        // engine-scoped, so this pair rides for the object's life.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            providerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.runningApps.invalidate()
                    self.workspaceVersion += 1
                    // A launch only matters while parked under a
                    // counterpart — the note flips live. Under JR-Bar
                    // the reconcile poll owns workspace churn already.
                    if self.settings().provider != .jrbar { self.applySettings() }
                }
            })
        }
    }

    isolated deinit {
        for (_, item) in spacerItems { NSStatusBar.system.removeStatusItem(item) }
        if let agentItem { NSStatusBar.system.removeStatusItem(agentItem) }
        combinedItem.remove()
        underlay.hide()
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
    func update(_ mutate: (inout MenuBarSettings) -> Void) {
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

    /// The custom-spacing dial's binding: `itemSpacing` is stored as
    /// whole points; the slider speaks Double.
    var itemSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings().itemSpacing) },
            set: { value in self.update { $0.itemSpacing = Int(value.rounded()) } })
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
                  !MenuBarItemLister.isProtected(item),
                  !Self.isOwnFamily(item.bundleID) else { return }
            if let bundleID = item.bundleID, MenuBarConcealPlan.canConcealApp(bundleID) {
                update { draft in
                    // A profile that already speaks for the app takes
                    // the pick; otherwise it lands on the base, so it
                    // holds in every profile. `.shown` is written, not
                    // deleted: the explicit marker records a deliberate
                    // pick, and absent keys read as shown the same way.
                    if MenuBarProfiles.pickTargetsProfile(appID: bundleID, in: draft),
                       let profileID = draft.curation.activeProfileID {
                        MenuBarProfiles.setDelta(appID: bundleID, to: section,
                                                 profileID: profileID, in: &draft)
                    } else {
                        draft.concealedApps[bundleID] = section
                    }
                }
            } else {
                // Apple's own extras and bare helpers have no concealment
                // path through the agent — cover them where they sit
                // instead, Ice-style, via the positional map the
                // cover-fallback in `concealedPlan` reads.
                writeCoverPick(section, for: itemID)
            }
            hider.reconcile()
            return
        }
        writeCoverPick(section, for: itemID)
    }

    /// A positional pick: into the active profile's delta when it speaks
    /// for the item (kept explicit — a delta's Shown must outrank the
    /// base), else onto the base map.
    private func writeCoverPick(_ section: MenuBarItemSection, for itemID: String) {
        update { draft in
            if MenuBarProfiles.pickTargetsProfile(itemID: itemID, in: draft),
               let profileID = draft.curation.activeProfileID {
                MenuBarProfiles.setDelta(itemID: itemID, to: section,
                                         profileID: profileID, in: &draft)
            } else {
                draft.sections = MenuBarItemHider.updatedSections(
                    items: listedItems, sections: draft.sections,
                    changedID: itemID, target: section)
            }
        }
    }

    /// The section an item's app is in under the concealer; the item
    /// map's answer otherwise.
    func effectiveSection(for item: MenuBarItem) -> MenuBarItemSection {
        // The curated truth — the base with the active profile laid over
        // it. A standing Hide all / Show all is not a pick and never
        // shows in the pickers.
        let curated = curatedSettings()
        return Self.effectiveSection(itemID: item.id, bundleID: item.bundleID,
                              sections: curated.sections,
                              concealedApps: curated.concealedApps,
                              concealing: concealer != nil,
                              ownBundleID: Bundle.main.bundleIdentifier)
    }

    /// The per-item truth the palette and covers read, pure so a test
    /// can pin it: under the concealer a concealable app's section is
    /// its `concealedApps` entry — a concealed item reads hidden and
    /// offers "Show"; Apple extras and bare helpers fall back to the
    /// positional map.
    nonisolated static func effectiveSection(
        itemID: String, bundleID: String?,
        sections: [String: MenuBarItemSection],
        concealedApps: [String: MenuBarItemSection],
        concealing: Bool, ownBundleID: String?
    ) -> MenuBarItemSection {
        if concealing, let bundleID, MenuBarConcealPlan.canConcealApp(bundleID),
           !(ownBundleID.map { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? false) {
            return concealedApps[bundleID] ?? .shown
        }
        return sections[itemID] ?? .shown
    }

    // MARK: Hide all / Show all — the overlay over your curation

    /// The overlay standing right now, if any.
    var activeOverlay: MenuBarOverlay.Kind? {
        if ruleOverlayWins, let rule = stateRules.outcome.overlay { return rule }
        return settings().curation.overlay.flatMap { $0.isLive() ? $0.kind : nil }
    }

    /// When the overlay was last put back by hand — Restore, or Keep. A
    /// "while" rule's overlay that took hold before it stands down until
    /// the rule next takes hold, the way a later Show all beats it.
    /// Runtime only, like the profile's; observed, so the card's Restore
    /// row answers at once.
    private(set) var overlayRestoredAt: Date?

    /// Whether a holding rule's overlay is the one in force: of it and
    /// your own last word on the overlay — a Hide all, a Show all, a
    /// Restore — whichever came last.
    private var ruleOverlayWins: Bool {
        _ = stateOutcomeVersion
        guard stateRules.outcome.overlay != nil else { return false }
        let manual = settings().curation.overlay.flatMap { $0.isLive() ? $0 : nil }
            .map { Date(timeIntervalSince1970: $0.sinceEpoch) }
        let manualSince = [manual, overlayRestoredAt].compactMap { $0 }.max()
        return MenuBarStateRuleEngine.ruleWins(ruleSince: stateRules.overlaySince,
                                               manualSince: manualSince)
    }

    /// The card's line while an overlay stands.
    var overlayNote: String? {
        if ruleOverlayWins, let kind = stateRules.outcome.overlay {
            return MenuBarLayers.ruleOverlayNote(kind)
        }
        return MenuBarLayers.overlayNote(settings().curation.overlay)
    }

    /// The curated maps: the base with the active profile's deltas laid
    /// over it — what the pickers show.
    func curatedSettings() -> MenuBarSettings {
        MenuBarProfiles.curated(settings())
    }

    /// The settings the engines converge to: the curated maps with the
    /// standing overlay laid over them. Writes always go to `settings()`.
    func liveSettings() -> MenuBarSettings {
        let base = settings()
        var curated: MenuBarSettings
        if let profile = ruleProfile(in: base) {
            // A holding rule's profile stands in for the active one —
            // its deltas and its cover look, never your saved choice.
            curated = MenuBarProfiles.curated(base, profile: profile)
            MenuBarProfiles.applyCoverLook(profile, to: &curated)
        } else {
            curated = MenuBarProfiles.curated(base)
        }
        guard let overlay = activeOverlay else { return curated }
        return MenuBarLayers.live(curated, overlay: overlay,
                                  apps: overlay == .hideEverything ? overlayApps() : [],
                                  itemIDs: overlay == .hideEverything ? overlayItemIDs() : [])
    }

    /// Every app with an item the agent can take — what the quiet bar
    /// tucks away: the apps this run has seen on the bar, less ours, the
    /// system's and Apple's extras (those cover in place instead).
    private func overlayApps() -> Set<String> {
        var ids = Set(knownItems.keys)
        ids.formUnion(listedItems.compactMap(\.bundleID))
        return ids.filter {
            MenuBarConcealPlan.canConcealApp($0) && !Self.isOwnFamily($0)
                && !MenuBarConcealPlan.systemItemOwners.contains($0)
        }
    }

    /// Every item the quiet bar covers in place: under the concealer only
    /// what the agent cannot take (Apple extras, bare helpers); under the
    /// spacer engine every listed foreign item. Protected items — the
    /// clock, Control Center — never.
    private func overlayItemIDs() -> Set<String> {
        Set(Self.hideAllTargets(listedItems).filter { item in
            concealer == nil || !(item.bundleID.map(MenuBarConcealPlan.canConcealApp) ?? false)
        }.map(\.id))
    }

    /// The listed items "hide all" reaches: foreign, named, unprotected,
    /// never the native overflow control and never our own family.
    nonisolated static func hideAllTargets(_ items: [MenuBarItem]) -> [MenuBarItem] {
        items.filter {
            !MenuBarItemLister.isProtected($0) && !$0.ownerName.isEmpty
                && !$0.isNativeOverflowControl && !isOwnFamily($0.bundleID)
        }
    }

    /// One-click relief for a crowded bar — the quiet bar laid over your
    /// curation, or, over a standing "show everything", your curated bar
    /// back. The map itself is never touched: restoring is dropping the
    /// overlay. `duration` lets it lapse on its own.
    func hideAllListed(for duration: TimeInterval? = nil) {
        update { draft in
            draft.curation.overlay = MenuBarOverlay.afterHideAll(
                draft.curation.overlay, until: duration.map { Date().addingTimeInterval($0) })
        }
        hider.reconcile()
    }

    /// Bring every hidden item back without forgetting what was hidden:
    /// "show everything" over your curation, or, over a standing quiet
    /// bar, your curated bar back. It survives a restart like any
    /// setting and ends with the next Hide all, Restore, or its clock.
    func showAllListed(for duration: TimeInterval? = nil) {
        update { draft in
            draft.curation.overlay = MenuBarOverlay.afterShowAll(
                draft.curation.overlay, until: duration.map { Date().addingTimeInterval($0) })
        }
        hider.reconcile()
    }

    /// Drop the overlay — the curated bar, exactly as you left it. A
    /// rule's overlay stands down too, until the rule next takes hold.
    func restoreCuratedBar() {
        let manual = settings().curation.overlay != nil
        guard manual || ruleOverlayWins else { return }
        overlayRestoredAt = Date()
        if manual { update { $0.curation.overlay = nil } }
        hider.reconcile()
    }

    /// "Keep" — the standing overlay becomes your curation: every listed
    /// app written Hidden (or every app written Shown and the covers
    /// cleared), then the overlay drops. The old one-click rewrite, now
    /// only ever on this explicit ask.
    func keepOverlay() {
        guard let kind = activeOverlay else { return }
        let targets = Self.hideAllTargets(listedItems)
        let concealing = concealer != nil
        update { draft in
            switch kind {
            case .hideEverything:
                for item in targets {
                    if concealing, let id = item.bundleID, MenuBarConcealPlan.canConcealApp(id) {
                        if draft.concealedApps[id] != .alwaysHidden { draft.concealedApps[id] = .hidden }
                    } else if draft.sections[item.id] != .alwaysHidden {
                        // The picker's routing: Apple extras, bare helpers
                        // and the spacer engine hide by covers.
                        draft.sections[item.id] = .hidden
                    }
                }
            case .showEverything:
                // `.shown` is written, not deleted: the explicit marker
                // records a deliberate pick.
                draft.concealedApps = draft.concealedApps.mapValues { _ in .shown }
                for id in targets.compactMap(\.bundleID) where MenuBarConcealPlan.canConcealApp(id) {
                    draft.concealedApps[id] = .shown
                }
                draft.sections = [:]
            }
            draft.curation.overlay = nil
        }
        // Kept is yours now: a rule's overlay it came from stands down.
        overlayRestoredAt = Date()
        hider.reconcile()
    }

    /// A timed overlay's lapse — rearmed on every settings apply.
    @ObservationIgnored private var overlayExpiry: Task<Void, Never>?

    /// Arm (or drop) the clock that ends a timed overlay. An overlay
    /// already past its time is cleared on the next turn — never inside
    /// the apply that noticed it.
    private func scheduleOverlayExpiry() {
        overlayExpiry?.cancel()
        overlayExpiry = nil
        guard let overlay = settings().curation.overlay, let until = overlay.untilEpoch else { return }
        let delay = max(0, until - Date().timeIntervalSince1970)
        overlayExpiry = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled else { return }
            self?.expireOverlayIfDue()
        }
    }

    /// Clear a timed overlay whose clock has run out — the curated bar
    /// comes back. An overlay still standing, or one without a clock, is
    /// left alone. A lapse while the utility is stopped still clears the
    /// file; only a running hider re-plans.
    func expireOverlayIfDue(now: Date = Date()) {
        guard let overlay = settings().curation.overlay, overlay.untilEpoch != nil,
              !overlay.isLive(at: now) else { return }
        update { $0.curation.overlay = nil }
        if running { hider.reconcile() }
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
        // A switch made after a rule took hold wins over the rule's.
        manualProfileAt = Date()
        update { MenuBarProfiles.apply(profile, to: &$0) }
    }

    /// When a profile was last switched by hand (the card, the menu, a
    /// hotkey, a one-shot rule, a display) — against a "while" rule's
    /// profile, the later one wins. Runtime only: after a relaunch a
    /// holding rule wins.
    @ObservationIgnored private var manualProfileAt: Date?

    /// The profile a holding "while" rule lays over the bar, while it
    /// wins — resolved by name like the triggers; "None" is your bar with
    /// the default look.
    private func ruleProfile(in settings: MenuBarSettings) -> MenuBarSettings.Profile? {
        guard let name = stateRules.outcome.profileName,
              MenuBarStateRuleEngine.ruleWins(ruleSince: stateRules.profileSince,
                                              manualSince: manualProfileAt) else { return nil }
        if name.caseInsensitiveCompare(MenuBarProfiles.noneName) == .orderedSame {
            return MenuBarSettings.Profile(id: MenuBarProfiles.noneID, name: MenuBarProfiles.noneName)
        }
        return settings.profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The active profile's id, or the built-in None's.
    var activeProfileID: String {
        MenuBarProfiles.activeProfile(in: settings())?.id ?? MenuBarProfiles.noneID
    }

    /// The profile editor's rows: every app the agent can take (one row
    /// per bundle, not per item — the concealer hides whole apps) and
    /// every item it cannot, which covers in place. Under the spacer
    /// engine every listed item is its own row. Protected items and our
    /// own family never.
    var profileSubjects: [MenuBarProfileSubject] {
        var seenApps: Set<String> = []
        var rows: [MenuBarProfileSubject] = []
        for item in Self.hideAllTargets(listedItems) {
            if concealer != nil, let app = item.bundleID, MenuBarConcealPlan.canConcealApp(app) {
                guard seenApps.insert(app).inserted else { continue }
                rows.append(MenuBarProfileSubject(key: app, isApp: true, title: item.ownerName, item: item))
            } else {
                rows.append(MenuBarProfileSubject(
                    key: item.id, isApp: false,
                    title: item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName, item: item))
            }
        }
        return rows
    }

    /// The profile editor's write — nil makes the app follow the base.
    func setProfileDelta(_ section: MenuBarItemSection?, forApp appID: String, profileID: String) {
        update { MenuBarProfiles.setDelta(appID: appID, to: section, profileID: profileID, in: &$0) }
        hider.reconcile()
    }

    /// The same for a covered item.
    func setProfileDelta(_ section: MenuBarItemSection?, forItem itemID: String, profileID: String) {
        update { MenuBarProfiles.setDelta(itemID: itemID, to: section, profileID: profileID, in: &$0) }
        hider.reconcile()
    }

    /// Save the current arrangement under `name`; returns the saved
    /// profile's id (nil on an unusable name).
    @discardableResult
    func saveProfileAs(_ name: String) -> String? {
        var savedID: String?
        update { savedID = MenuBarProfiles.saveCurrent(as: name, in: &$0) }
        return savedID
    }

    // MARK: Extras writes

    /// A spacer row's edit — the settings write; the item itself syncs
    /// through `applySettings`.
    func updateSpacer(id: String, _ mutate: (inout MenuBarSettings.Spacer) -> Void) {
        update { draft in
            guard let index = draft.spacers.firstIndex(where: { $0.id == id }) else { return }
            mutate(&draft.spacers[index])
        }
    }

    func addSpacer(label: String = "") {
        update { $0.spacers.append(MenuBarSettings.Spacer(label: label)) }
    }

    func removeSpacer(id: String) {
        update { $0.spacers.removeAll { $0.id == id } }
    }

    /// The display→profile map entry; empty clears the mapping.
    func setDisplayProfile(_ profileID: String, displayKey: String) {
        update { draft in
            if profileID.isEmpty {
                draft.displayProfiles[displayKey] = nil
            } else {
                draft.displayProfiles[displayKey] = profileID
            }
        }
    }

    func renameProfile(id: String, to name: String) {
        update { MenuBarProfiles.rename(id: id, to: name, in: &$0) }
    }

    func deleteProfile(id: String) {
        update { MenuBarProfiles.delete(id: id, in: &$0) }
    }

    // MARK: Actions (hotkeys, triggers, command bar)

    /// The bindings the hotkey registry actually uses — the persisted
    /// list, or the shipping set while the file has never carried one.
    /// An action this build added after the file's list materialized
    /// joins it disabled: the card can still bind it, and an upgrade
    /// never turns a key on by itself.
    func resolvedHotkeyBindings() -> [MenuBarHotkeyBinding] {
        let stored = settings().hotkeyBindings
        let base = stored.isEmpty ? MenuBarHotkeys.standard : stored
        let missing = MenuBarHotkeys.standard.filter { standard in
            !base.contains { $0.action == standard.action }
        }
        return base + missing.map {
            MenuBarHotkeyBinding(action: $0.action, keyCode: $0.keyCode,
                                 modifiers: $0.modifiers, enabled: false)
        }
    }

    /// The card's per-action toggle — writes the materialized list so
    /// the settings file carries what the person actually sees.
    func setHotkeyEnabled(_ enabled: Bool, for action: MenuBarHotkeyAction) {
        var list = resolvedHotkeyBindings()
        guard let index = list.firstIndex(where: { $0.action == action }) else { return }
        list[index].enabled = enabled
        update { $0.hotkeyBindings = list }
        // The ‹'s tooltip names the toggle hotkey while it is on.
        faceChanged()
    }

    /// The ⌘⇧K palette — also the card's "Command bar" button.
    func openCommandBar() { actions.openCommandBar() }

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

    // MARK: "While" rules

    func addStateRule(_ rule: MenuBarStateRule) {
        update { $0.curation.stateRules.append(rule) }
    }

    func setStateRule(id: String, enabled: Bool) {
        update { draft in
            guard let i = draft.curation.stateRules.firstIndex(where: { $0.id == id }) else { return }
            draft.curation.stateRules[i].enabled = enabled
        }
    }

    func deleteStateRule(id: String) {
        update { $0.curation.stateRules.removeAll { $0.id == id } }
    }

    /// The rules holding right now, as the card lists them.
    var holdingStateRules: [MenuBarStateRule] {
        _ = stateOutcomeVersion
        let holding = Set(stateRules.outcome.holding)
        return settings().curation.stateRules.filter { holding.contains($0.id) }
    }

    /// The daemon's feed changed: whatever moved among the agents, the
    /// asks, the headroom and SidePulse reaches the rule engine as a
    /// sample. The baselines always move — a stopped utility's included —
    /// so a start or a rule enabled later never fires on a transition
    /// that happened while it was off; only a running utility acts.
    func coreFactsChanged() {
        let facts = coreFacts()
        let samples = MenuBarCoreFacts.samples(from: lastCoreFacts, to: facts)
        lastCoreFacts = facts
        // After this change's samples have reached the rules, whichever
        // branch below runs.
        defer { if facts.live { restoreSceneOnce() } }
        guard running else {
            // A stopped utility — disabled, or handed over to another
            // manager — holds nothing and writes nothing: the one-shot
            // engine hears the samples against no rules, and the "while"
            // levels are seeded afresh on the next start.
            let day = MenuBarSystemTriggerSource.dayStamp()
            for sample in samples {
                _ = actions.triggerEngine.actions(for: sample, rules: [], dayStamp: day)
            }
            return
        }
        for sample in samples { systemTriggerSource.emit(sample) }
        // The agent glance follows the feed, not the scan cadence.
        if samples.contains(where: { if case .agentState = $0 { return true } else { return false } }) {
            refreshExtrasFaces(force: true)
        }
        // An open ask rides no trigger sample; the "while" rules read it
        // — once their levels are seeded, like every other sample.
        if stateRulesSeeded, facts.live, stateRules.levels.askPending != facts.askPending {
            stateRules.update { $0.askPending = facts.askPending }
        }
    }

    /// Once a launch, at the core's first live facts — `currentScene` and
    /// `setScene` need the daemon — the relaunch half of a quit mid-rule:
    /// the scene a "while" rule replaced goes back unless a rule holds one
    /// again. It runs with the utility parked or no rule enabled too: then
    /// nothing holds, and the scene is yours.
    private func restoreSceneOnce() {
        guard !sceneRestoreChecked else { return }
        sceneRestoreChecked = true
        stateRules.restoreSceneAfterRelaunch()
    }

    // MARK: Lifecycle

    /// The card toggle and the store's `state` write land here: start
    /// on enable, stop on disable, reconcile on any other change.
    func applySettings() {
        runningApps.invalidate()
        migrateSectionsIfNeeded()
        syncSpacing()
        scheduleOverlayExpiry()
        let enabled = settings().enabled && settings().provider == .jrbar
        if enabled, !running {
            start()
        } else if !enabled, running {
            stop()
        } else if running {
            // The control set is settings-driven too — a combined-mode
            // flip or a profile apply lands here between covers.
            installBoundary()
            syncConcealerChoice()
            hider.reconcile()
            syncActions()
            syncExtras()
        }
    }

    /// The spacing value this run already pushed into the global
    /// domain — a re-apply with the same setting is a no-op.
    private var lastSpacingApplied = -1

    /// The card's item-spacing picker → the current-host global
    /// domain. Writing a value marks the setting managed so picking
    /// the default later removes the keys; a value never written
    /// leaves whatever the system (or a `defaults` user) has alone.
    private func syncSpacing() {
        let s = settings()
        guard s.itemSpacing != lastSpacingApplied else { return }
        if s.itemSpacing > 0 {
            MenuBarSpacing.write(spacing: s.itemSpacing, managed: true)
            lastSpacingApplied = s.itemSpacing
            if !s.itemSpacingManaged {
                update { $0.itemSpacingManaged = true }
            }
        } else if s.itemSpacingManaged {
            MenuBarSpacing.write(spacing: 0, managed: true)
            lastSpacingApplied = 0
            update { $0.itemSpacingManaged = false }
        } else {
            lastSpacingApplied = 0
        }
    }

    /// The card's "hide anyway" switch: bring the agent up or down to
    /// match, on an unnotarized build.
    private func syncConcealerChoice() {
        guard MenuBarAssessmentBackend.isAvailable, host != nil, let notarized else { return }
        let wanted = (notarized || settings().concealUnnotarized)
            && !settings().curation.forceSpacerEngine
        if wanted, concealer == nil {
            startConcealer()
        } else if !wanted, concealer != nil {
            stopConcealer()
            host?.setBoundarySpacer(0)
        }
    }

    /// A file from the cover era assigned every item hidden — under
    /// the position model that map would cover every item right of the
    /// chevron in place. Model 3 clears the concealer's auto-seeded
    /// map as well: hiding is opt-in, the person's ⌘-drag layout and
    /// the pickers are the arrangement now.
    func migrateSectionsIfNeeded() {
        let current = settings()
        let legacy = current.layoutModel < MenuBarSettings.currentLayoutModel
        let supported = current.concealedApps.filter { MenuBarConcealPlan.canConcealApp($0.key) }
        let snapshots = current.curation.profileModel < MenuBarCuration.currentProfileModel
        guard legacy || snapshots || supported != current.concealedApps else { return }
        update { draft in
            // Profiles move to deltas against today's base first, so
            // each keeps exactly the layout it had.
            MenuBarProfiles.migrateToDeltas(&draft)
            if legacy {
                draft.sections = [:]
                draft.concealedApps = [:]
                draft.concealSeeded = true
                draft.layoutModel = MenuBarSettings.currentLayoutModel
            } else if supported != current.concealedApps {
                // Old positional learning put Apple extras in a second
                // map their picker never reads or clears. Keep the actual
                // per-item choices and remove only those invalid entries.
                draft.concealedApps = supported
            }
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
        startSettleUntil = Date().addingTimeInterval(Self.startSettle)
        startGeneration += 1
        let generation = startGeneration
        probeAccessibility()
        Self.forgetRetiredItems()
        installBoundary()
        if MenuBarAssessmentBackend.isAvailable, host != nil {
            // The agent honours an allowlist only for apps that pass
            // Gatekeeper: from an unnotarized build the agent hides
            // JR-Bar's own icon too. The spacer stands in unless the
            // person chose the agent anyway.
            Task { [weak self] in
                let notarized = await MenuBarAssessmentBackend.bundleIsNotarized()
                guard let self, self.running, self.startGeneration == generation else { return }
                self.notarized = notarized
                if self.settings().curation.forceSpacerEngine {
                    MenuBarAssessmentBackend.log.notice("conceal: the spacer engine is forced in Advanced")
                } else if notarized || self.settings().concealUnnotarized {
                    self.startConcealer()
                    self.hider.reconcile()
                } else {
                    MenuBarAssessmentBackend.log.notice("conceal: build is not notarized — the agent would hide our own icon; spacer engine stands in")
                }
            }
        }
        hider.start()
        reveal.start()
        // Bindings land before start so registration uses the persisted
        // set, not the defaults the actions object was built with.
        syncActions()
        actions.start()
        failedHotkeyActions = actions.hotkeys.failedActions
        syncExtras()
        startDeskWatch()
        // First AX fill — a no-op without the grant — then reconcile
        // against real frames.
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            self?.hider.reconcile()
        }
    }

    /// Everything down: the bar closes, the gestures stop, the covers
    /// lift, and the control items leave the row. `forQuit` leaves what
    /// the "while" rules hold where it stands: a quit cannot put the
    /// scene back (the daemon write is a task the process never runs),
    /// and the saved scene-before-rule is what the next launch restores
    /// (`restoreSceneOnce`). The quiet lease ends on the daemon's clock.
    func stop(forQuit: Bool = false) {
        guard running else { return }
        bar.close()
        reveal.stop()
        hider.stop()
        actions.stop()
        stopConcealer()
        removeBoundary()
        removeExtras()
        // An update reveal's pending re-hide belongs to this run.
        updateHideTask?.cancel()
        updateHideTask = nil
        overlayExpiry?.cancel()
        overlayExpiry = nil
        stopDeskWatch()
        failedHotkeyActions = []
        running = false
        // The ear lets go of the menu bar with the utility, its nudges
        // included — they belonged to this run.
        earNudgeExpiry?.cancel()
        earNudgeExpiry = nil
        earNudge = nil
        queuedNudges = []
        refreshEarFeed()
        // A stopped utility holds nothing: the scene and the quiet go
        // back, the layers drop — after `running` falls, so the layers'
        // re-plan never reaches the hider that just stood down.
        if stateRulesSeeded {
            stateRulesSeeded = false
            if !forQuit { stateRules.stop() }
        }
    }

    // MARK: Extras — spacers, underlay, agent item, combined item
    // Its state; the code is in MenuBarUtilityExtras.swift.

    /// When `refreshExtrasFaces` last ran — its throttle.
    @ObservationIgnored var extrasRefreshedAt = Date.distantPast

    /// The gate on Control Center's items — see `MenuBarDrawnGate`.
    @ObservationIgnored var combinedGate =
        MenuBarDrawnGate(hidden: MenuBarCombinedItem.coveredExtrasSaved())

    // MARK: Desks

    /// How long the screens must hold still before a desk is read — a
    /// dock or a lid shutting reconfigures them in a burst.
    nonisolated static let deskSettle: TimeInterval = 1.5

    /// Read the desk now and again whenever the screens change.
    private func startDeskWatch() {
        guard deskObserver == nil else { return }
        deskObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDeskRead(after: Self.deskSettle) }
        }
        // Off start's stack: an arrival writes settings.
        scheduleDeskRead(after: 0)
    }

    private func stopDeskWatch() {
        if let deskObserver { NotificationCenter.default.removeObserver(deskObserver) }
        deskObserver = nil
        deskRead?.cancel()
        deskRead = nil
    }

    private func scheduleDeskRead(after delay: TimeInterval) {
        deskRead?.cancel()
        deskRead = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled, let self, self.running else { return }
            self.noteDesk(MenuBarDesk.current(),
                          lidClosed: MenuBarSystemTriggerSource.clamshellClosed() ?? false)
        }
    }

    /// A desk read: name it for the card and, when it is a different desk
    /// from the last one seen, take the profile it maps to — once, so a
    /// profile picked by hand afterwards holds until the desk changes.
    func noteDesk(_ displays: [MenuBarDesk.Display], lidClosed: Bool) {
        guard let key = MenuBarDesk.key(displays) else { return }
        let name = MenuBarDesk.name(displays, lidClosed: lidClosed)
        currentDesk = (key, name)
        let curation = settings().curation
        let arriving = MenuBarDesk.profileToApply(previousKey: curation.lastDeskKey,
                                                  currentKey: key, desks: curation.deskProfiles)
        let renamed = curation.deskProfiles.contains { $0.key == key && $0.name != name }
        guard curation.lastDeskKey != key || renamed else { return }
        update { draft in
            draft.curation.lastDeskKey = key
            if let index = draft.curation.deskProfiles.firstIndex(where: { $0.key == key }) {
                draft.curation.deskProfiles[index].name = name
            }
        }
        if let arriving, deskProfileExists(arriving) { applyProfile(id: arriving) }
    }

    /// Map the current desk to a profile (empty clears it). Picking one
    /// takes it now — the desk you are at is the one you are choosing for.
    func setProfileForCurrentDesk(_ profileID: String) {
        guard let desk = currentDesk else { return }
        update { draft in
            draft.curation.deskProfiles = MenuBarDesk.setting(profileID, forKey: desk.key, name: desk.name,
                                                              in: draft.curation.deskProfiles)
            draft.curation.lastDeskKey = desk.key
        }
        if !profileID.isEmpty, deskProfileExists(profileID) { applyProfile(id: profileID) }
    }

    /// Forget a desk that is not attached.
    func forgetDesk(key: String) {
        update { draft in draft.curation.deskProfiles.removeAll { $0.key == key } }
    }

    private func deskProfileExists(_ id: String) -> Bool {
        id == MenuBarProfiles.noneID || settings().profiles.contains { $0.id == id }
    }

    // MARK: The concealer (macOS 27)
    // Its state; the code is in MenuBarUtilityConcealer.swift.

    /// The icon while the concealer runs — see `MenuBarIconMirror`.
    @ObservationIgnored var iconMirror: MenuBarIconMirror?

    /// Whether the mirror carries the icon right now; the ear's ‹ reads
    /// it, so a flip tells the band at once.
    @ObservationIgnored var iconMirrored = false {
        didSet { if iconMirrored != oldValue { menuHandleChanged() } }
    }

    /// The last seat logged — the log speaks only when it moves.
    @ObservationIgnored var lastMirrorSeat: CGFloat?

    /// The hidden run's reveal state the band last heard about.
    @ObservationIgnored var handleRevealedSeen = false

    /// A cover re-cut is queued for the next run-loop turn, or is the
    /// pass now running (`recutCovers`).
    @ObservationIgnored var coverRecutQueued = false

    @ObservationIgnored var coverRecutRunning = false

    /// Apps lifted out of the assertion for a moment, and until when: a
    /// tile's press stands its app alone while its menu is read, a
    /// watched item that changed stands alone for the rehide clock.
    /// Every plan pass re-applies the target, so a lift lives here, not
    /// in a one-off apply the next pass would undo within the second.
    @ObservationIgnored var lifts: [String: Date] = [:]

    /// The plan the card and the Item Bar read under the concealer: the
    /// listing's shown items minus the concealed apps, and every
    /// concealed app's remembered items as the hidden runs. The spacer
    /// model's positional sections mean nothing here — the agent
    /// reorders the bar on its own.
    /// Concealed bundle IDs whose items reported on the row at the
    /// last live scan — the baseline a re-registered item transitions
    /// out of. Frozen while concealment is lifted: under a reveal or
    /// a suspend everything may stand legitimately.
    @ObservationIgnored var concealedStanding: Set<String> = []

    /// When the current live stretch began — the post-activation
    /// settle rides inside this grace so a mid-parking item is not
    /// mistaken for an escapee.
    @ObservationIgnored var concealLiveSince: Date = .distantPast

    /// Last re-assert time — escape churn must not flap the bar.
    @ObservationIgnored var lastReassert: Date = .distantPast

    /// First time each concealed bundle's item was seen standing —
    /// the clock a re-assert gets to park it before covers take over.
    @ObservationIgnored var escapeFirstSeen: [String: Date] = [:]

    /// Escapees standing through a completed re-assert: the agent
    /// will not take them, so the cover fallback paints over them
    /// like the other agent-proof items.
    @ObservationIgnored var resistantConcealed: Set<String> = []

    /// The frame each concealed app's item reported on the last pass.
    /// The agent takes a concealed item's pixels but not its
    /// Accessibility node — the ghost keeps answering with the frame
    /// it froze at, on-row and pressable but undrawn, pass after pass.
    @ObservationIgnored var lastConcealedFrames: [String: CGRect] = [:]

    /// Every on-row frame an unproven concealed item has reported —
    /// the ghost's bookkeeping. The agent can relayout its ghosts
    /// (a MenuBarAgent restart moved the whole concealed run from
    /// frozen on-row frames to parked ones); a return to a reported
    /// slot is still the ghost, a novel on-row slot is a live item.
    @ObservationIgnored var concealedGhostFrames: [String: Set<CGRect>] = [:]

    /// Concealed-bundle item ids that proved live, stamped with when
    /// the proof landed — a frame that moved to a slot the ghost never
    /// reported. Proof is NOT sticky: ten seconds without a novel
    /// slot, or a return to a ghost slot, and the item reads as the
    /// ghost again until pixels say otherwise.
    @ObservationIgnored var liveConcealedItems: [String: Date] = [:]

    /// Re-assert stamps each standing escapee survived, ≥20 s apart —
    /// the no-permission path to `resistantConcealed` (three
    /// consecutive standings where the pixel test cannot reach).
    @ObservationIgnored var escapeStandings: [String: [Date]] = [:]

    /// Escapees with a pixel probe in flight — one capture at a time.
    @ObservationIgnored var pendingResistance: Set<String> = []

    /// Escapees the pixel test disproved — a flat capture means the
    /// rect is the ghost; cleared when the bundle leaves `standing`.
    @ObservationIgnored var pixelDisproven: Set<String> = []

    /// The pixel-proof seam — the live-tile capture path while Screen
    /// Recording is granted. Tests stub it; a nil *answer* means the
    /// capture is unavailable and the standings rule decides.
    @ObservationIgnored var escapeeCapture: ((CGRect) async -> CGImage?)?

    @ObservationIgnored var escapeeCaptureSource: DisplayFilterSource?

    // MARK: The glyph camera
    // Its state; the code is in MenuBarUtilityConcealer.swift.

    /// Photographs items while they are legitimately drawn and files
    /// their glyphs for the Item Bar. Set by the app delegate — a test
    /// utility has none, so no test ever captures the screen or writes
    /// the cache.
    @ObservationIgnored var glyphCamera: MenuBarGlyphCamera? {
        didSet {
            glyphCamera?.dark = { [weak self] in self?.barIsDark() ?? false }
            glyphCamera?.onChange = { [weak self] item in
                // A picture that changed while tucked away — the next
                // Item Bar marks it, and the ear may say so.
                self?.bar.updatedIDs.insert(item.id)
                self?.noticePictureChange(item)
            }
            // Each frame is bracketed by a fresh listing: the item must
            // still be drawn, unmoved, and alone in its rect, or the
            // photograph is someone else's. Fresh means begun after the
            // frame — the hider's scan in flight would hand back a list
            // older than it, and the check would compare it to itself.
            glyphCamera?.locate = { [weak self] item in
                guard let listed = await MenuBarItemLister.freshAXItems(),
                      let self, let fresh = listed.first(where: { $0.id == item.id }) else { return nil }
                return Self.photographable(fresh, among: listed,
                                           rows: MenuBarItemLister.menuBarRows(),
                                           concealed: self.concealer?.concealedApps ?? [])
                    ? fresh : nil
            }
            pruneGlyphs()
        }
    }

    /// The engine just came up: photograph before the first assertion.
    @ObservationIgnored var prePhotographPending = false

    /// This reveal's photographs are taken (or under way).
    @ObservationIgnored var revealPhotographed = false

    /// Waits out the moment this reveal may be photographed.
    @ObservationIgnored var revealPhotoWatch: Task<Void, Never>?

    // MARK: Engine health and rivals

    /// Bumped whenever the engine's state moves, so the card's line
    /// observes it — the concealer itself is not observable.
    var engineVersion = 0

    /// Which engine hides the bar, and whether it is healthy.
    var engineHealth: MenuBarEngineHealth {
        _ = engineVersion
        return .assess(.init(
            running: running,
            frameworkAvailable: concealerAvailable,
            forced: settings().curation.forceSpacerEngine,
            notarized: notarized,
            concealUnnotarized: settings().concealUnnotarized,
            engineUp: concealer != nil,
            assertionLive: concealer?.isConcealing ?? false,
            activationFailing: concealer?.activationFailing ?? false,
            inStartGrace: Date().timeIntervalSince(concealerStartedAt) < Self.adoptionGrace,
            concealedCount: concealer?.concealedApps.count ?? 0))
    }

    /// The card's "Right now" line.
    var engineLine: String {
        let health = engineHealth
        if case .spacer = health { return health.line(fitEdge: hider.fitEdge) }
        return health.line()
    }

    /// Other menu-bar managers running while ours renders — their
    /// assertions un-hide what ours conceals. Empty while a counterpart
    /// is the pick (then running it is the point) or ours is parked.
    var runningRivals: [MenuBarRivals.Rival] {
        _ = workspaceVersion
        guard settings().provider == .jrbar, settings().enabled else { return [] }
        return MenuBarRivals.runningNow()
    }

    /// The guard's "Hand over": the rival renders, ours parks.
    func handOver(to rival: MenuBarRivals.Rival) {
        guard let provider = rival.handoff else { return }
        update { $0.provider = provider }
    }

    /// The guard's "Quit": ask the rival to quit — the person's click.
    func quitRival(_ rival: MenuBarRivals.Rival) {
        MenuBarRivals.quit(rival)
    }

    /// The diagnostic toggle: keep the spacer engine even where the
    /// concealer resolves. The apply brings the engine up or down.
    func setForceSpacerEngine(_ on: Bool) {
        update { $0.curation.forceSpacerEngine = on }
        engineVersion += 1
    }

    /// The fit-edge dial for the spacer engine — a nudge, a reset.
    func nudgeFitEdge(by delta: CGFloat) { hider.nudgeFitEdge(by: delta) }
    func resetFitEdge() { hider.forgetFitEdge() }

    /// A held-back click on the clock, battery or Wi-Fi: lift, replay,
    /// let concealment return.
    func bridgeClick(at point: CGPoint) {
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
        let whileRulesOn = settings().curation.stateRules.contains(where: \.enabled)
        if whileRulesOn, !stateRulesSeeded {
            // The levels no sample carries yet: the running apps, the
            // front one, the lock, the displays, the lid — and the
            // daemon's facts as last heard.
            stateRulesSeeded = true
            var seed = MenuBarStateRunner.seedLevels()
            if let facts = lastCoreFacts, facts.live {
                seed.agent = facts.agent
                seed.askPending = facts.askPending
                seed.quotaRemaining = facts.quotaRemaining
                seed.sidePulse = facts.sidePulsePresent
            }
            stateRules.update { $0 = seed }
            systemTriggerSource.pollNow()
        } else if !whileRulesOn, stateRulesSeeded {
            stateRulesSeeded = false
            stateRules.stop()
        }
        if settings().triggerRules.contains(where: \.enabled) || whileRulesOn {
            systemTriggerSource.start()
        } else {
            systemTriggerSource.stop()
        }
        // A rule edited, added or toggled re-resolves against the levels.
        if whileRulesOn { stateRules.evaluate() }
        // `apply()` re-registers — the refusal set is refreshed either
        // way, and a fresh start clears a stale failure list.
        failedHotkeyActions = actions.hotkeys.failedActions
    }

    // MARK: Listing (the card's item rows)
    // Its state; the code is in MenuBarUtilityListing.swift.

    /// When the Item Bar last folded, in system uptime.
    @ObservationIgnored var barClosedAtUptime: TimeInterval = -.infinity

    // MARK: The boundary
    // Its state; the code is in MenuBarUtilityBoundary.swift.

    /// One click, one transition — a double-fired action or a stray
    /// second delivery inside this window must not toggle twice and
    /// leave the run flapping between states.
    @ObservationIgnored var lastChevronToggleAt = Date.distantPast

    /// The last scan's hidden-item titles for "show for updates" —
    /// empty while the feature is off or unseeded.
    @ObservationIgnored var updateSignatures: [String: String] = [:]

    /// The pending re-hide an update reveal scheduled.
    @ObservationIgnored var updateHideTask: Task<Void, Never>?

    // MARK: The Screen Bar's right ear
    // Its state; the code is in MenuBarUtilityEar.swift.

    /// What the right ear shows of the menu bar: the hidden runs' tiles
    /// for its peek. nil while the utility is parked or another manager
    /// renders. Observed by the Screen Bar; written only when it moves,
    /// so a reconcile pass that changed nothing re-lays no ear.
    var earFeed: MenuBarEarFeed?

    /// Whether the Screen Bar's ears are up to carry the menu bar's
    /// marks — wired by the Screen Bar.
    @ObservationIgnored var earAvailable: @MainActor () -> Bool = { false }

    /// Whether the pointer is on the ear's peek or the ear under it
    /// right now — wired by the Screen Bar. The bar's own reveal
    /// gestures stand down there: a scroll on the ear is the peek's.
    @ObservationIgnored var earAnswersGesture: @MainActor () -> Bool = { false }

    // MARK: Newcomers and changes, on the ear
    // Its state; the code is in MenuBarUtilityEar.swift.

    /// The apps the menu bar has ever shown — set by the app delegate. A
    /// test utility has none, so it learns nothing and nudges nothing.
    @ObservationIgnored var newcomerMemory: MenuBarNewcomerMemory?

    /// One nudge as the utility holds it, before the feed dresses it
    /// with the live item and its face.
    struct PendingNudge {
        var id: String
        var kind: MenuBarEarFeed.Nudge.Kind
        var itemID: String
        var detail: String?
        /// Read once, so the ear's mark is the same picture every pass.
        var icon: NSImage?
    }

    /// The nudge standing now, and the few waiting behind it — one mark
    /// on the ear at a time.
    @ObservationIgnored var earNudge: PendingNudge?

    @ObservationIgnored var queuedNudges: [PendingNudge] = []

    @ObservationIgnored var earNudgeExpiry: Task<Void, Never>?

    @ObservationIgnored var earNudgeSerial = 0

    /// Until when this run's listings and photographs are learned in
    /// silence — set at start: the AX listing fills in over the first
    /// scans, login items put their icons up in the same seconds, and
    /// the first photographs are held against the last run's.
    @ObservationIgnored var startSettleUntil = Date.distantPast
    nonisolated static let startSettle: TimeInterval = 20

    /// A rule's keep-awake hold — the app's own hold by default; a test
    /// records it.
    @ObservationIgnored var holdAwake: @MainActor (Int?) -> Void = { seconds in
        _ = AppCommandRouter.shared.perform(.keepAwake(seconds: seconds))
    }

    // MARK: Permissions

    /// The card's "Open Settings" for the click-through row.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One row of a profile's editor: an app (keyed by bundle id) under the
/// concealer, or an item (keyed by its identity) that covers in place.
struct MenuBarProfileSubject: Identifiable, Equatable {
    var key: String
    var isApp: Bool
    var title: String
    /// A listed item of the subject's, for the row's icon.
    var item: MenuBarItem
    var id: String { (isApp ? "app:" : "item:") + key }
}
