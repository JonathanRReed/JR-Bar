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
    /// Arrange mode, the ⌘⇧K command bar, the global hotkeys and the
    /// trigger engine — the utility implements `MenuBarActionsDelegate`
    /// (bottom of file) so every action lands on the same machinery
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
    private(set) var clickBridgeFailed = false
    /// The last arrange run's outcome — the card's report line.
    private(set) var lastArrangeOutcome: MenuBarArrangeOutcome?
    /// True while an arrange is dragging — the card disables its button.
    private(set) var arranging = false

    /// The latest layout — the card's count row and item list read it.
    /// While the utility runs the hider keeps it fresh; while it is
    /// parked the card's `refreshListing()` fills it once, spacers down.
    private(set) var lastPlan = MenuBarHidePlan()
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

    /// The chevron status item — the hidden run's toggle on the row.
    /// Target/action needs an `NSObject`, so the buttons' clicks land
    /// on this box and forward.
    @ObservationIgnored private let chevronActions = MenuBarChevronActions()
    /// Readable for the teardown test; only `install`/`removeChevron` write it.
    @ObservationIgnored private(set) var chevron: NSStatusItem?
    /// The spacer/label items settings carries — keyed by `Spacer.id`.
    /// Same rules as the chevron: born visible, never re-registered.
    @ObservationIgnored private var spacerItems: [String: NSStatusItem] = [:]
    /// The spacer buttons' target — a click reveals like the chevron's.
    @ObservationIgnored private let spacerActions = MenuBarSpacerActions()
    /// The agent-state item and its click target.
    @ObservationIgnored private var agentItem: NSStatusItem?
    @ObservationIgnored private let agentActions = MenuBarSpacerActions()
    @ObservationIgnored private var lastAgentSignature = ""
    /// The combined system item — battery/Wi-Fi/sound/Focus in one.
    @ObservationIgnored private let combinedItem = MenuBarCombinedItem()
    /// Whether the CC extras are hidden through our item right now —
    /// the defaults write and the `killall` only run on the flip. Seeded
    /// from the saved originals: a crash can leave them hidden.
    @ObservationIgnored private var coveredExtrasHidden = MenuBarCombinedItem.coveredExtrasSaved()
    /// The full-bar tint underlay.
    @ObservationIgnored private let underlay = MenuBarUnderlay()
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
    @ObservationIgnored private var activeDisplayKey: String?
    @ObservationIgnored private var pendingDisplayKey: (key: String, count: Int)?
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
    @ObservationIgnored private var clickBridge: MenuBarSystemClickBridge?
    /// Items of every app the listing has ever seen this run, by bundle
    /// identifier — a concealed app's items leave the Accessibility
    /// tree, and the card and the Item Bar still list them from here.
    @ObservationIgnored private var knownItems: [String: [MenuBarItem]] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// NSWorkspace enumeration is expensive. Notifications invalidate this
    /// snapshot promptly; a bounded refresh still discovers quiet helpers.
    @ObservationIgnored private let runningApps: RunningBundleIDCache
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
    private static let boundaryAffordance: CGFloat = 30

    /// The boundary's host — the app's own status item. Everything
    /// left of it is the hidden run; it grows the spacer, draws the
    /// hint, takes the reveal click and carries the hidden-items
    /// submenu. Without a host the fallback chevron item stands in.
    @ObservationIgnored weak var host: (any MenuBarBoundaryHost)? {
        didSet {
            host?.onBoundaryClick = { [weak self] in self?.boundaryClicked() }
            host?.hiddenItemsMenu = { [weak self] in self?.hiddenItemsMenu() }
            host?.onFaceChange = { [weak self] in self?.faceChanged() }
            if running { installChevron(); hider.controlsReinstalled() }
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
            self.refreshChevron()
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
        // The frame is the live control's — the host's boundary when one
        // hosts, the fallback chevron otherwise — and under the concealer
        // the ear's ‹ handle, its frame published by the screen bar,
        // while it stands.
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
        chevronActions.utility = self
        spacerActions.onClick = { [weak self] in self?.chevronClicked() }
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
        if let chevron { NSStatusBar.system.removeStatusItem(chevron) }
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
    nonisolated private static func hideAllTargets(_ items: [MenuBarItem]) -> [MenuBarItem] {
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

    // MARK: Actions (hotkeys, triggers, arrange, command bar)

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

    /// Whether Arrange can do anything at all: only under the spacer
    /// engine. Under the macOS 27 concealer MenuBarAgent orders the bar
    /// itself and a concealed item cannot be ⌘-dragged, so a run would
    /// move the real cursor and deliver nothing — the card hides the
    /// section and the palette's row finds no order to drive. Pure so a
    /// test pins the gate.
    var arrangeAvailable: Bool { Self.arrangeAvailable(concealing: concealer != nil) }

    nonisolated static func arrangeAvailable(concealing: Bool) -> Bool { !concealing }

    /// The explicit arrange action — the only caller of the synthetic
    /// ⌘-drag machinery. The banner, cursor restore and abort watcher
    /// are the coordinator's; this just runs it and reports.
    func arrangeNow() {
        guard !arranging, arrangeAvailable else { return }
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
            installChevron()
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
        startGeneration += 1
        let generation = startGeneration
        probeAccessibility()
        installChevron()
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
    /// lift, and the control items leave the row.
    func stop() {
        guard running else { return }
        bar.close()
        reveal.stop()
        hider.stop()
        actions.stop()
        stopConcealer()
        removeChevron()
        removeExtras()
        // An update reveal's pending re-hide belongs to this run.
        updateHideTask?.cancel()
        updateHideTask = nil
        overlayExpiry?.cancel()
        overlayExpiry = nil
        stopDeskWatch()
        failedHotkeyActions = []
        running = false
        // A stopped utility holds nothing: the scene and the quiet go
        // back, the layers drop — after `running` falls, so the layers'
        // re-plan never reaches the hider that just stood down.
        if stateRulesSeeded {
            stateRulesSeeded = false
            stateRules.stop()
        }
    }

    // MARK: Extras — spacers, underlay, agent item, combined item

    /// Bring every settings-driven extra in step: the spacer items,
    /// the underlay, the agent item and the combined system item.
    /// Runs on start and on every settings apply while running.
    private func syncExtras() {
        let s = settings()
        MenuBarCombinedItem.log.notice("syncExtras: spacers=\(s.spacers.count) underlay=\(s.barUnderlay) agentItem=\(s.agentStatusItem) combined=\(s.combinedSystemItem)")
        // Under the concealer macOS draws none of our status items, and it
        // orders the bar itself, so a spacer could neither show nor sit
        // between chosen apps: the rows keep their settings and the items
        // stand down until the spacer engine is back (the card says so).
        syncSpacerItems(Self.spacersDrawable(concealing: concealer != nil) ? s.spacers : [])
        if s.barUnderlay {
            underlay.show(appearance: MenuBarCoverAppearance(settings: s))
        } else {
            underlay.hide()
        }
        if s.combinedSystemItem {
            Self.seedPreferredPosition(475,
                                       autosaveName: "com.jonathanreed.jrbar.menubar-combined")
            combinedItem.sync(blank: extrasMirrored)
        } else {
            combinedItem.remove()
        }
        syncAgentItem()
        pushAccessories()
        stepCombinedGate()
    }

    /// Whether spacer items can do their job: only under the spacer
    /// engine. Pure so a test pins the gate.
    nonisolated static func spacersDrawable(concealing: Bool) -> Bool { !concealing }

    /// Whether the mirror carries the extras right now — the real items
    /// then stand blank, so a lift can never flash a second copy.
    private var extrasMirrored: Bool { concealer != nil && iconMirrored }

    /// The ids of the compound face's segments.
    nonisolated static let agentAccessoryID = "agents"
    nonisolated static let combinedAccessoryID = "combined"

    /// The extras the mirror wears as segments of its one compound face
    /// while the concealer runs: the agent glance and the combined
    /// readout. Empty under the spacer engine, where the real items draw.
    private func extrasAccessories() -> [MenuBarFaceAccessory] {
        guard concealer != nil, running else { return [] }
        let s = settings()
        var out: [MenuBarFaceAccessory] = []
        if s.agentStatusItem {
            let read = agentState()
            out.append(MenuBarFaceAccessory(
                id: Self.agentAccessoryID,
                image: Self.agentDotImage(tintHex: read.state.tintHex),
                title: read.state.label,
                toolTip: "Agents — \(read.state.label)" + (read.detail.isEmpty ? "" : ": \(read.detail)"),
                accessibilityLabel: "Agents: \(read.state.label)",
                signature: "\(read.state.rawValue)|\(read.detail)"))
        }
        if s.combinedSystemItem {
            let read = combinedItem.readout()
            out.append(MenuBarFaceAccessory(
                id: Self.combinedAccessoryID, image: read.image, title: nil,
                toolTip: "Battery, Wi-Fi, sound and Focus — one item. Click for the panel.",
                accessibilityLabel: read.label, signature: read.signature))
        }
        return out
    }

    /// The mirror's face: the host's, with the extras as segments. A
    /// style that draws no icon lends the mirror no face — only the
    /// segments stand.
    private func mirrorFace() -> MenuBarIconFace? {
        guard let host else { return nil }
        var face = host.face
        if !host.anchorWantsVisibleSeat {
            face.image = nil
            face.title = nil
            face.length = 0
        }
        face.accessories = extrasAccessories()
        face.chevronToolTip = Self.chevronToolTip(
            hiddenCount: face.hiddenCount,
            toggleHotkey: resolvedHotkeyBindings().first { $0.action == .toggleReveal && $0.enabled },
            style: settings().revealStyle)
        return face
    }

    /// A binding's key as a menu key equivalent — a letter or a digit;
    /// nil for a key a menu cannot draw as one.
    nonisolated static func menuKeyEquivalent(for binding: MenuBarHotkeyBinding) -> String? {
        let name = MenuBarHotkeys.keyName(for: binding.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return name.lowercased()
    }

    /// The ‹'s tooltip: what a click does, and — when the toggle hotkey
    /// is on — that the same keys open the Item Bar for the keyboard.
    /// Pure so a test pins the copy.
    nonisolated static func chevronToolTip(hiddenCount: Int, toggleHotkey: MenuBarHotkeyBinding?,
                                           style: MenuBarSettings.RevealStyle) -> String? {
        guard hiddenCount > 0 else { return nil }
        let items = "\(hiddenCount) hidden item\(hiddenCount == 1 ? "" : "s")"
        let click = style == .bar ? "click for the Item Bar" : "click to bring them back"
        guard let hotkey = toggleHotkey else { return "\(items) — \(click)" }
        let keys = style == .bar
            ? "\(hotkey.displayString) opens it for the keyboard: arrows, type to filter, Return"
            : "\(hotkey.displayString) does the same"
        return "\(items) — \(click). \(keys)."
    }

    /// Push the current segments to the mirror when they changed.
    private func pushAccessories() {
        guard let mirror = iconMirror, let face = mirrorFace() else { return }
        let wanted = face.accessories.map(\.signature)
        guard wanted != mirror.face.accessories.map(\.signature) else { return }
        mirror.update(face: face)
        updateIconMirror()
    }

    /// A segment's click: the agents open the Overview, the readout its
    /// popover — anchored on the segment.
    private func accessoryClicked(_ id: String, view: NSView) {
        switch id {
        case Self.agentAccessoryID: onOpenOverview()
        case Self.combinedAccessoryID: combinedItem.toggle(relativeTo: view)
        default: break
        }
    }

    /// Refresh the extras' faces — the agent glance and the combined
    /// readout change with the world, not with settings. Throttled: the
    /// plan pass calls it every scan.
    @ObservationIgnored private var extrasRefreshedAt = Date.distantPast
    private func refreshExtrasFaces(force: Bool = false) {
        guard running else { return }
        let now = Date()
        guard force || now.timeIntervalSince(extrasRefreshedAt) >= 2 else { return }
        extrasRefreshedAt = now
        let s = settings()
        if s.combinedSystemItem { combinedItem.sync(blank: extrasMirrored) }
        syncAgentItem()
        pushAccessories()
        stepCombinedGate(now: now)
    }

    /// The gate on Control Center's items — see `MenuBarDrawnGate`.
    @ObservationIgnored private var combinedGate =
        MenuBarDrawnGate(hidden: MenuBarCombinedItem.coveredExtrasSaved())

    private func stepCombinedGate(now: Date = Date()) {
        let wanted = running && settings().combinedSystemItem
        guard let hide = combinedGate.step(wanted: wanted, drawn: combinedFaceDrawn, now: now) else { return }
        MenuBarCombinedItem.log.notice("combined item: \(hide ? "face drawn — hiding" : "face not drawn — restoring", privacy: .public) Control Center's items")
        coveredExtrasHidden = hide
        MenuBarCombinedItem.setCoveredExtrasHidden(hide)
    }

    /// Whether the combined face is on screen: under a live assertion
    /// only the mirror's segment can be (macOS draws no item of ours);
    /// with none, the real item once it has a window.
    private var combinedFaceDrawn: Bool {
        guard settings().combinedSystemItem, combinedItem.item != nil else { return false }
        if let concealer, concealer.isConcealing || concealer.isSuspended {
            guard iconMirrored, let mirror = iconMirror, mirror.isVisible else { return false }
            return mirror.face.accessories.contains { $0.id == Self.combinedAccessoryID }
        }
        return combinedItem.item?.button?.window != nil
    }

    /// Everything extras-related off the bar — the disable path and
    /// the deinit share it.
    private func removeExtras() {
        for (id, item) in spacerItems {
            item.button?.target = nil
            item.button?.action = nil
            NSStatusBar.system.removeStatusItem(item)
            spacerItems[id] = nil
        }
        underlay.hide()
        combinedItem.remove()
        _ = combinedGate.release()
        if coveredExtrasHidden {
            coveredExtrasHidden = false
            MenuBarCombinedItem.setCoveredExtrasHidden(false)
        }
        if let agentItem {
            agentItem.button?.target = nil
            agentItem.button?.action = nil
            NSStatusBar.system.removeStatusItem(agentItem)
            self.agentItem = nil
        }
        lastAgentSignature = ""
    }

    /// The spacer/label items, in step with `settings().spacers`: born
    /// visible, fixed or hugging length, a click revealing like the
    /// chevron's. Removed rows leave the bar on the spot.
    private func syncSpacerItems(_ spacers: [MenuBarSettings.Spacer]) {
        var live: Set<String> = []
        for spacer in spacers {
            live.insert(spacer.id)
            let autosave = "com.jonathanreed.jrbar.menubar-spacer-\(spacer.id)"
            if spacerItems[spacer.id] == nil {
                Self.seedPreferredPosition(480, autosaveName: autosave)
                let item = NSStatusBar.system.statusItem(
                    withLength: spacer.width > 0 ? spacer.width : NSStatusItem.variableLength)
                item.autosaveName = autosave
                if let button = item.button {
                    button.target = spacerActions
                    button.action = #selector(MenuBarSpacerActions.clicked(_:))
                    button.sendAction(on: [.leftMouseUp])
                    button.toolTip = "JR-Bar spacer — click reveals the hidden items."
                }
                spacerItems[spacer.id] = item
                MenuBarCombinedItem.log.notice("spacer \(spacer.id) created: len=\(item.length) visible=\(item.isVisible) window=\(item.button?.window != nil)")
            }
            guard let item = spacerItems[spacer.id] else { continue }
            if item.button?.title != spacer.label { item.button?.title = spacer.label }
            let wanted = spacer.width > 0 ? spacer.width : NSStatusItem.variableLength
            if item.length != wanted { item.length = wanted }
            if !item.isVisible { item.isVisible = true }
        }
        for (id, item) in spacerItems where !live.contains(id) {
            item.button?.target = nil
            item.button?.action = nil
            NSStatusBar.system.removeStatusItem(item)
            spacerItems[id] = nil
        }
    }

    /// The agent-state item: a tinted dot plus the feed's label —
    /// redrawn only when the signature changes.
    private func syncAgentItem() {
        guard settings().agentStatusItem else {
            if let agentItem {
                agentItem.button?.target = nil
                agentItem.button?.action = nil
                NSStatusBar.system.removeStatusItem(agentItem)
                self.agentItem = nil
                lastAgentSignature = ""
            }
            return
        }
        if agentItem == nil {
            Self.seedPreferredPosition(490,
                                       autosaveName: "com.jonathanreed.jrbar.menubar-agents")
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.jonathanreed.jrbar.menubar-agents"
            if let button = item.button {
                button.target = agentActions
                button.action = #selector(MenuBarSpacerActions.clicked(_:))
                button.sendAction(on: [.leftMouseUp])
                button.imagePosition = .imageLeft
            }
            agentItem = item
        }
        let read = agentState()
        let blank = extrasMirrored
        let signature = "\(read.state.rawValue)|\(read.detail)" + (blank ? "|blank" : "")
        guard signature != lastAgentSignature else { return }
        lastAgentSignature = signature
        // While the mirror carries the glance the item stands blank —
        // macOS draws nothing of ours under the assertion anyway, and a
        // lift must not flash a second copy.
        agentItem?.button?.image = blank ? nil : Self.agentDotImage(tintHex: read.state.tintHex)
        agentItem?.button?.title = blank ? "" : read.state.label
        agentItem?.button?.toolTip = "Agents — \(read.state.label)"
            + (read.detail.isEmpty ? "" : ": \(read.detail)")
    }

    /// A 10-pt dot in the state's tint — template where the state
    /// carries no colour so the bar keeps its own.
    nonisolated static func agentDotImage(tintHex: String?) -> NSImage? {
        let side: CGFloat = 10
        let colour = tintHex
            .flatMap { MenuBarCoverAppearance.tintComponents($0) }
            .map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
            ?? .labelColor
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)).fill()
            return true
        }
        image.isTemplate = tintHex == nil
        return image
    }

    /// The per-display profile follow: the pointer's screen maps to a
    /// profile id; entering a mapped display applies it once two
    /// reconcile passes in a row agree — a pointer straddling a seam
    /// must not write settings on every pass.
    private func pollDisplayProfile() {
        let map = settings().displayProfiles
        guard !map.isEmpty else {
            activeDisplayKey = nil
            pendingDisplayKey = nil
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }), let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let key = number.stringValue
        guard key != activeDisplayKey else { return }
        guard let profileID = map[key] else { return }
        let count = pendingDisplayKey?.key == key ? pendingDisplayKey!.count + 1 : 1
        pendingDisplayKey = (key, count)
        guard count >= 2 else { return }
        activeDisplayKey = key
        // Deferred — `applyProfile` writes settings, which reconciles;
        // running it inside `onPlan` would nest a reconcile in one.
        Task { @MainActor [weak self] in self?.applyProfile(id: profileID) }
    }

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

    /// Bring the agent-side engine up: the hider keeps listing and
    /// planning (the card, the Item Bar, the reveal clock all read its
    /// plan) but never grows a spacer or draws a cover; the plan's
    /// sections come from the per-app map; the bridge takes the
    /// system's clicks; the mirror carries the icon.
    private func startConcealer() {
        // One engine at a time: a second start would overwrite the first
        // engine's bridge and helper without stopping them, leaving a
        // live event tap pointing at a freed bridge.
        guard concealer == nil else { return }
        runningApps.invalidate()
        let concealer = MenuBarConcealer()
        concealer.onChange = { [weak self] in self?.concealerChanged() }
        self.concealer = concealer
        concealerStartedAt = Date()
        prePhotographPending = true
        hider.shuttersSuppressed = true
        // No affordance under the agent: nothing of ours grows while the
        // agent hides — the icon is the mirror's.
        host?.setBoundarySpacer(0)
        let bridge = MenuBarSystemClickBridge { [weak self] point in
            self?.bridgeClick(at: point)
        }
        bridge.start()
        clickBridge = bridge
        clickBridgeFailed = !bridge.tapLive
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.noteWorkspaceChange()
                }
            })
        }
        MenuBarAssessmentBackend.log.notice("conceal: engine up (MenuBarClientCore resolved)")
        installChevron()
        refreshChevron()
        iconMirror = makeIconMirror()
        updateIconMirror()
        menuHandleChanged()
        // The spacers stand down and the extras move onto the mirror.
        if running { syncExtras() }
    }

    /// The icon while the concealer runs — see `MenuBarIconMirror`.
    @ObservationIgnored private var iconMirror: MenuBarIconMirror?
    /// Whether the mirror carries the icon right now; the ear's ‹ reads
    /// it, so a flip tells the band at once.
    @ObservationIgnored private var iconMirrored = false {
        didSet { if iconMirrored != oldValue { menuHandleChanged() } }
    }
    /// The last seat logged — the log speaks only when it moves.
    @ObservationIgnored private var lastMirrorSeat: CGFloat?
    /// The hidden run's reveal state the band last heard about.
    @ObservationIgnored private var handleRevealedSeen = false
    /// A cover re-cut is queued for the next run-loop turn, or is the
    /// pass now running (`recutCovers`).
    @ObservationIgnored private var coverRecutQueued = false
    @ObservationIgnored private var coverRecutRunning = false

    /// The mirror's frame while it stands; nil while it is down.
    private var standingMirrorFrame: NSRect? {
        iconMirror.flatMap { $0.isVisible ? $0.frame : nil }
    }

    /// The ear's ‹ (`menuHandleRevealed`) may have changed: the mirror
    /// took or gave back the icon, the hidden run flipped, the engine
    /// came up or went down. The band otherwise saw these only on its
    /// 1 Hz safety poll, and for up to about 1.25 s two ‹ marks stood —
    /// the mirror's and the ear's — or none did. It rides the ear-limit
    /// push, whose debounced rescan compares the handle too.
    private func menuHandleChanged() {
        ScreenBarGeometry.earLimitsChanged?()
    }

    /// The mirror moved, resized, came up or went down. The covers the
    /// hider paints this pass were cut against its frame from before it
    /// settled: `onPlan` builds the cover runs before `syncConcealer`
    /// seats the mirror, and a face change re-seats it with no plan at
    /// all. A merged run could then span the new seat, and a shutter at
    /// the mirror's own level paint over the icon until the next scan.
    /// One reconcile on the next run-loop turn re-cuts them around the
    /// settled frame. Only one: a seat that moves again inside that pass
    /// waits for the next pass of its own, so a re-cut never chains.
    private func recutCovers() {
        guard !coverRecutQueued, !coverRecutRunning else { return }
        coverRecutQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.coverRecutQueued = false
            guard self.concealer != nil else { return }
            self.coverRecutRunning = true
            self.hider.reconcile()
            self.coverRecutRunning = false
        }
    }

    /// The mirror, wired the way the real button is: the face's click is
    /// the panel, its right/Option click the item's full menu, the ‹ the
    /// hidden run's toggle. Internal so a test can drive the wiring
    /// without an engine.
    func makeIconMirror() -> MenuBarIconMirror {
        let mirror = MenuBarIconMirror()
        mirror.onPrimaryClick = { [weak self] in self?.host?.faceClicked() }
        mirror.onSecondaryClick = { [weak self] view in self?.host?.popUpMenu(in: view) }
        mirror.onChevronClick = { [weak self] in self?.host?.onBoundaryClick?() }
        mirror.onPlace = { [weak self] frame in self?.host?.mirroredFaceFrame = frame }
        mirror.onAccessoryClick = { [weak self] id, view in self?.accessoryClicked(id, view: view) }
        if let face = mirrorFace() { mirror.update(face: face) }
        return mirror
    }

    /// When the mirror carries the icon: the engine is up, the style
    /// draws an icon, and something is (or is about to be) concealed —
    /// the assertion is live, a click-bridge lift is only a suspend, or
    /// the engine has a target it is still asserting (the first 2.5 s
    /// after start, while a relaunch's old assertion drains, or an
    /// activation in flight). A target the engine keeps failing to
    /// assert is not about to be concealed: nothing holds, macOS draws
    /// the real item, and a mirror would only blank it. Otherwise no
    /// assertion holds and macOS draws the real item itself. Pure so a
    /// test pins the table.
    nonisolated static func mirrorsIcon(engineUp: Bool, styleDrawsIcon: Bool, concealing: Bool,
                                        suspended: Bool, targetEmpty: Bool,
                                        activationFailing: Bool = false) -> Bool {
        engineUp && styleDrawsIcon
            && (concealing || (!activationFailing && (suspended || !targetEmpty)))
    }

    /// The set the engine converges to: the map's hidden apps less the
    /// live reveal — our own family never, whatever a stale map says
    /// (the daemon's meter hid itself once).
    private func concealTarget() -> Set<String> {
        let now = Date()
        lifts = lifts.filter { $0.value > now }
        return Self.liveTarget(
            MenuBarConcealPlan.concealed(apps: liveSettings().concealedApps, revealed: hider.revealed),
            lifts: lifts, now: now)
    }

    /// Apps lifted out of the assertion for a moment, and until when: a
    /// tile's press stands its app alone while its menu is read, a
    /// watched item that changed stands alone for the rehide clock.
    /// Every plan pass re-applies the target, so a lift lives here, not
    /// in a one-off apply the next pass would undo within the second.
    @ObservationIgnored private var lifts: [String: Date] = [:]

    /// The target with the live lifts left out — never our own family.
    /// Pure so a test pins it.
    nonisolated static func liveTarget(_ concealed: Set<String>, lifts: [String: Date],
                                       now: Date) -> Set<String> {
        concealed.filter { !isOwnFamily($0) && !(lifts[$0].map { $0 > now } ?? false) }
    }

    /// How long a lift holds for its photograph — the camera's two
    /// frames and their listings, with room to spare; the pass ends it
    /// sooner.
    nonisolated static let liftPhotographHold: TimeInterval = 3

    /// Stand `app` alone on the row until `until` (a later lift wins),
    /// and converge now.
    private func lift(_ app: String, until: Date) {
        lifts[app] = max(until, lifts[app] ?? until)
        syncConcealer()
    }

    /// End a lift once nothing of the app's is open — a menu the person
    /// is reading keeps it standing, polled each second for up to five
    /// minutes — then put the full target back.
    private func releaseLift(_ app: String, item: MenuBarItem) async {
        for _ in 0..<300 {
            guard MenuBarItemLister.menuOpen(ownerPIDs: [item.ownerPID],
                                             infos: MenuBarItemLister.windowInfos()) else { break }
            lifts[app] = Date().addingTimeInterval(2)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // The press is answered and its menu closed, and the lift still
        // stands the item on the row: the moment to photograph a stale
        // glyph. Never before the press — each frame lights the
        // recording indicator and shifts the bar, which must not land
        // between a click and the menu it opens. A fresh glyph costs no
        // capture at all. Only a lift still standing is held — one that
        // already lapsed is not raised again for a picture.
        if let camera = glyphCamera, let until = lifts[app], until > Date() {
            lifts[app] = max(until, Date().addingTimeInterval(Self.liftPhotographHold))
            let stored = await camera.photograph([item], rows: MenuBarItemLister.menuBarRows())
            if !stored.isEmpty { bar.glyphsChanged() }
        }
        lifts[app] = nil
        runningApps.invalidate()
        syncConcealer()
    }

    /// Settle who draws the icon and, while the mirror does, where it
    /// stands. Runs on every plan pass and every engine change; the
    /// window moves only when its frame does, and a frame that changed
    /// re-cuts the covers.
    private func updateIconMirror() {
        guard let concealer else { return }
        let before = standingMirrorFrame
        // A target of apps that are not running conceals nothing — the
        // engine drops the assertion and macOS draws the real item.
        // A style that draws no icon still stands a mirror while the
        // extras ride it — they have nowhere else to show.
        let drawsSomething = (host?.anchorWantsVisibleSeat ?? false)
            || !(iconMirror?.face.accessories.isEmpty ?? true)
        let mirrored = Self.mirrorsIcon(engineUp: true,
                                        styleDrawsIcon: drawsSomething,
                                        concealing: concealer.isConcealing,
                                        suspended: concealer.isSuspended,
                                        targetEmpty: concealTarget().isDisjoint(with: runningApps.snapshot()),
                                        activationFailing: concealer.activationFailing)
        let extrasFlipped = iconMirrored != mirrored
        iconMirrored = mirrored
        host?.setFaceMirrored(mirrored)
        if extrasFlipped {
            // The extras' real items blank or wear their faces again.
            if settings().combinedSystemItem { combinedItem.sync(blank: extrasMirrored) }
            syncAgentItem()
        }
        stepCombinedGate()
        if mirrored, let mirror = iconMirror, let primary = NSScreen.screens.first {
            mirror.show(row: Self.primaryRow(), primaryMaxY: primary.frame.maxY) { width in
                mirrorSeat(width: width)
            }
        } else {
            iconMirror?.hide()
        }
        if standingMirrorFrame != before { recutCovers() }
    }

    /// The menu bar's row on the Quartz origin display — the one the
    /// mirror stands on. `menuBarRow()` takes its depth from
    /// `NSScreen.main`, the key window's screen: with an external
    /// display in front the notch's 37-pt row reads as 24, which would
    /// seat the mirror 6.5 pt high.
    private static func primaryRow() -> CGRect {
        MenuBarItemLister.menuBarRows().first ?? MenuBarItemLister.menuBarRow()
    }

    /// The host redrew its face — style, tint, tooltip, highlight,
    /// pulse, the hidden run's count. The mirror wears it and re-seats
    /// (a label or the ‹ changes its width); a flip to or from the
    /// `.hidden` style settles whether it stands at all.
    private func faceChanged() {
        guard concealer != nil, let face = mirrorFace() else { return }
        iconMirror?.update(face: face)
        updateIconMirror()
    }

    /// The mirror's left edge for a `width`-wide panel: flush left of
    /// the first drawn item, from the right, with room to stand — the
    /// right end of the blank run the concealed apps leave — or, on a
    /// bar with no such room, `MenuBarIconMirror.seat`'s fallbacks,
    /// which cover as little of any drawn item as they can. Drawn is
    /// every listed item on the main row that is not ours and not
    /// concealed, the native « included. While no assertion holds (a
    /// bridged click's lift, the start grace) the target counts as
    /// concealed, so a 0.45 s reflow never walks the icon — unless the
    /// engine is failing to assert it: then macOS draws every target
    /// app, and a seat that skipped them would stand on one.
    private func mirrorSeat(width: CGFloat) -> CGFloat {
        let row = Self.primaryRow()
        let clear = mirrorClearOf()
        let targetOnItsWay = concealer.map { !$0.isConcealing && !$0.activationFailing } ?? true
        let concealed = targetOnItsWay ? concealTarget() : (concealer?.concealedApps ?? [])
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let drawn = (lastPlan.shown + lastPlan.hidden + lastPlan.alwaysHidden).filter { item in
            item.ownerPID != ourPID && Self.isForeignOwner(item.ownerName)
                && item.bounds.intersects(row)
                && !(item.bundleID.map { concealed.contains($0) } ?? false)
        }.map(\.bounds)
        let seat = MenuBarIconMirror.seat(drawn: drawn, clearOf: clear, width: width, rowMaxX: row.maxX)
        if seat != lastMirrorSeat {
            lastMirrorSeat = seat
            let line = "conceal: mirror seat \(String(format: "%.0f", seat)) w=\(String(format: "%.0f", width)) clear of \(String(format: "%.0f", clear)), \(drawn.count) drawn"
            // A seat on a drawn item hides that app's icon and takes its
            // clicks: no gap on the row fits the face. Said at notice so
            // a crowded bar's overlap shows in the log.
            let covered = drawn.filter { $0.minX < seat + width && $0.maxX > seat }.count
            if covered > 0 {
                MenuBarAssessmentBackend.log.notice("\(line, privacy: .public) — stands on \(covered, privacy: .public), no gap fits")
            } else {
                MenuBarAssessmentBackend.log.debug("\(line, privacy: .public)")
            }
        }
        return seat
    }

    /// Where nothing covers the row on the Quartz origin display. The
    /// mirror seats, and the reveal zone starts, right of it.
    private func mirrorClearOf() -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        return Self.mirrorClearOf(
            notch: primary.auxiliaryTopRightArea?.minX,
            covering: ScreenBarGeometry.coveringScreenRect.flatMap { rect in
                primary.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) ? rect.maxX : nil
            },
            appMenuEdge: MenuBarItemLister.appMenuEdge,
            row: Self.primaryRow())
    }

    /// The furthest right of: the notch's right edge; our band's (or
    /// island's) right edge — the band window claims its ears' full
    /// extent; and the front app's last menu title. The menus are not
    /// in the listing, so without their edge a crowded bar's seat (or a
    /// notch Mac's menus spilling past the notch) lands the mirror on
    /// them — a status-bar-level panel taking their clicks — and the
    /// reveal zone starts on them. The menu edge is the front app's on
    /// whichever bar it drew; one outside the origin display's `row`
    /// would push the seat off it, so only an edge inside counts. Pure
    /// so a test pins it.
    nonisolated static func mirrorClearOf(notch: CGFloat?, covering: CGFloat?,
                                          appMenuEdge: CGFloat?, row: CGRect) -> CGFloat {
        let menus = appMenuEdge.flatMap { $0 > row.minX && $0 < row.maxX ? $0 : nil }
        return max(notch ?? 0, covering ?? 0, menus ?? 0, 0)
    }

    /// A workspace launch or terminate under the concealer: refresh
    /// the running universe and re-apply. The concealer's allowlist is
    /// monotonic — a first-seen app joins it and the union re-assert
    /// shows it without dropping anything; a quit changes nothing. No
    /// suspend: the bar never lifts for a launch — the steady-state
    /// `conceal: released` churn the old adoption beat caused several
    /// times an hour. Suspending survives only where a click must
    /// physically land: the bridged system items.
    func noteWorkspaceChange() {
        runningApps.invalidate()
        syncConcealer()
    }

    func stopConcealer() {
        guard let concealer else { return }
        iconMirrored = false
        iconMirror?.hide()
        iconMirror = nil
        lastMirrorSeat = nil
        // The real item is the icon again, at its natural width.
        host?.setFaceMirrored(false)
        runningApps.invalidate()
        // The drop lands now — a disable or quit must not leave the
        // run concealed for the drain; `releaseAll` invalidates the
        // live assertion synchronously, then unwinds queued work.
        Task { await concealer.releaseAll() }
        clickBridge?.stop()
        clickBridge = nil
        clickBridgeFailed = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        hider.shuttersSuppressed = false
        hider.externalPlan = nil
        self.concealer = nil
        menuHandleChanged()
        // The real extras are the faces again; the spacers come back.
        if running { syncExtras() }
    }

    /// The bundle identifiers of every running app — the allowlist's
    /// universe. An app that launches later is re-applied for by the
    /// workspace observers.
    private static func readRunningBundleIDs() -> Set<String> {
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
    /// Concealed bundle IDs whose items reported on the row at the
    /// last live scan — the baseline a re-registered item transitions
    /// out of. Frozen while concealment is lifted: under a reveal or
    /// a suspend everything may stand legitimately.
    @ObservationIgnored private var concealedStanding: Set<String> = []
    /// When the current live stretch began — the post-activation
    /// settle rides inside this grace so a mid-parking item is not
    /// mistaken for an escapee.
    @ObservationIgnored private var concealLiveSince: Date = .distantPast
    /// Last re-assert time — escape churn must not flap the bar.
    @ObservationIgnored private var lastReassert: Date = .distantPast
    /// First time each concealed bundle's item was seen standing —
    /// the clock a re-assert gets to park it before covers take over.
    @ObservationIgnored private var escapeFirstSeen: [String: Date] = [:]
    /// Escapees standing through a completed re-assert: the agent
    /// will not take them, so the cover fallback paints over them
    /// like the other agent-proof items.
    @ObservationIgnored private var resistantConcealed: Set<String> = []
    /// The frame each concealed app's item reported on the last pass.
    /// The agent takes a concealed item's pixels but not its
    /// Accessibility node — the ghost keeps answering with the frame
    /// it froze at, on-row and pressable but undrawn, pass after pass.
    @ObservationIgnored private var lastConcealedFrames: [String: CGRect] = [:]
    /// Every on-row frame an unproven concealed item has reported —
    /// the ghost's bookkeeping. The agent can relayout its ghosts
    /// (a MenuBarAgent restart moved the whole concealed run from
    /// frozen on-row frames to parked ones); a return to a reported
    /// slot is still the ghost, a novel on-row slot is a live item.
    @ObservationIgnored private var concealedGhostFrames: [String: Set<CGRect>] = [:]
    /// Concealed-bundle item ids that proved live, stamped with when
    /// the proof landed — a frame that moved to a slot the ghost never
    /// reported. Proof is NOT sticky: ten seconds without a novel
    /// slot, or a return to a ghost slot, and the item reads as the
    /// ghost again until pixels say otherwise.
    @ObservationIgnored private var liveConcealedItems: [String: Date] = [:]
    /// Re-assert stamps each standing escapee survived, ≥20 s apart —
    /// the no-permission path to `resistantConcealed` (three
    /// consecutive standings where the pixel test cannot reach).
    @ObservationIgnored private var escapeStandings: [String: [Date]] = [:]
    /// Escapees with a pixel probe in flight — one capture at a time.
    @ObservationIgnored private var pendingResistance: Set<String> = []
    /// Escapees the pixel test disproved — a flat capture means the
    /// rect is the ghost; cleared when the bundle leaves `standing`.
    @ObservationIgnored private var pixelDisproven: Set<String> = []
    /// The pixel-proof seam — the live-tile capture path while Screen
    /// Recording is granted. Tests stub it; a nil *answer* means the
    /// capture is unavailable and the standings rule decides.
    @ObservationIgnored var escapeeCapture: ((CGRect) async -> CGImage?)?
    @ObservationIgnored private var escapeeCaptureSource: DisplayFilterSource?

    /// The assertion only adopts items that exist when it activates —
    /// a concealed app that re-creates its status item afterwards
    /// stands on the row until the next activation (Tailscale's grid,
    /// ChatGPT's knot and cmux sat drawn in the "should be empty"
    /// stretch doing exactly that). A newly standing concealed bundle
    /// earns a fresh activation, rate-limited so churn cannot flap the
    /// bar; a throttled escape stays out of the baseline so the next
    /// scan retries it.
    private func watchConcealedEscapees(in listing: MenuBarHidePlan) {
        // A suspend is a lift, not a teardown — the assertion is off but
        // coming back, so the bookkeeping (first-seen clocks, standings,
        // pixel verdicts) must survive the window or every Item Bar open
        // restarts the ~60 s classification from zero.
        guard let concealer, concealer.isConcealing || concealer.isSuspended else {
            concealedStanding = []
            escapeFirstSeen = [:]
            escapeStandings = [:]
            resistantConcealed = []
            pendingResistance = []
            pixelDisproven = []
            concealLiveSince = .distantPast
            lastConcealedFrames = [:]
            concealedGhostFrames = [:]
            liveConcealedItems = [:]
            return
        }
        guard hider.revealed.isEmpty else { return }
        // Every display's bar counts — an item standing on a secondary
        // screen's strip is just as visible as one on the main row.
        let rows = MenuBarItemLister.menuBarRows()
        let all = listing.shown + listing.hidden + listing.alwaysHidden
        // Same on-row rule the hider plans by: an item parked under
        // the « control reports its frame, not a row position.
        let overflowFrames = all
            .filter { item in item.isNativeOverflowControl
                && rows.contains { $0.intersects(item.bounds) } }
            .map(\.bounds)
        // The live target, not the persisted setting: `trigger(_:)`
        // narrows the assertion for the scoped reveal, and the revealed
        // app must not classify as an escapee while the user reads it —
        // that re-conceals the item under its open menu. During a
        // suspend the live set is empty, so nothing counts as escaped
        // while everything legitimately stands.
        let concealedIDs = concealer.concealedApps
        let concealedItems = all.filter { item in
            item.bundleID.map { concealedIDs.contains($0) } ?? false
        }
        // What reads as "standing" is almost always the ghost: the
        // agent takes the item's pixels but not its Accessibility
        // node, so the node keeps reporting a frame — frozen, or one
        // it was relayouted to — pressable, undrawn. The only listing
        // evidence a live registration offers is a move to an on-row
        // slot the ghost never reported.
        let frames = Dictionary(concealedItems.map { ($0.id, $0.bounds) },
                                uniquingKeysWith: { first, _ in first })
        let onRowIDs = Set(concealedItems.filter { item in
            rows.contains { $0.intersects(item.bounds) }
                && !overflowFrames.contains(where: { $0.intersection(item.bounds).width >= 4 })
        }.map(\.id))
        let now = Date()
        // Ids mid-classification keep their proof past the decay window —
        // the standings rule takes ~60 s and must not be reset by it.
        let classifying = Set(escapeFirstSeen.keys)
            .union(escapeStandings.keys).union(pendingResistance)
        let triage = Self.concealedEscapees(
            onRow: onRowIDs, frames: frames, previous: lastConcealedFrames,
            ghostHistory: concealedGhostFrames, proven: liveConcealedItems, now: now,
            retain: classifying)
        liveConcealedItems = triage.proven
        concealedGhostFrames = triage.ghostHistory
        lastConcealedFrames = frames
        var standing = Set<String>()
        for item in concealedItems
            where liveConcealedItems[item.id] != nil && onRowIDs.contains(item.id) {
            if let id = item.bundleID { standing.insert(id) }
        }
        if concealLiveSince == .distantPast { concealLiveSince = now }
        // Still settling the last activation — keep the baseline stale
        // so the first post-grace scan catches whatever stood through it.
        guard now.timeIntervalSince(concealLiveSince) >= 1.2 else { return }
        let escaped = standing.subtracting(concealedStanding)
        let throttled = now.timeIntervalSince(lastReassert) <= 1.5
        concealedStanding = throttled ? standing.subtracting(escaped) : standing
        for id in standing where escapeFirstSeen[id] == nil {
            escapeFirstSeen[id] = now
        }
        for id in escapeFirstSeen.keys where !standing.contains(id) {
            escapeFirstSeen[id] = nil
        }
        for id in escapeStandings.keys where !standing.contains(id) {
            escapeStandings[id] = nil
        }
        for id in pixelDisproven where !standing.contains(id) {
            pixelDisproven.remove(id)
        }
        // `resistantConcealed` deliberately does NOT clear when an
        // escapee leaves the row: the agent holding it for a beat does
        // not make it takeable — it re-escapes on the same cadence
        // (cmux's ~20 s flap), and a cleared proof leaves every escape
        // window standing uncovered through a fresh 8-second wait.
        // Once an item proves agent-proof it keeps the cover for the
        // rest of this concealment session; the set resets wholesale
        // when the assertion lifts (the guard above).
        // Eight seconds standing through the re-assert it triggered —
        // the agent had its chance. Then PIXELS decide: a live item's
        // tile has real variance, the ghost's rect captures featureless
        // bar. Without Screen Recording the standings rule stands in.
        for (id, first) in escapeFirstSeen
            where standing.contains(id) && lastReassert >= first
                && now.timeIntervalSince(first) > 8
                && !resistantConcealed.contains(id)
                && !pendingResistance.contains(id)
                && !pixelDisproven.contains(id) {
            if let item = concealedItems.first(where: {
                $0.bundleID == id && onRowIDs.contains($0.id)
            }), let rect = MenuBarTileMath.captureRect(
                of: item, row: rows.first { $0.intersects(item.bounds) } ?? rows[0]) {
                pendingResistance.insert(id)
                let lastReassert = self.lastReassert
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.pendingResistance.remove(id) }
                    guard let image = await self.captureEscapee(rect) else {
                        // No Screen Recording — the standings rule.
                        self.noteEscapeStanding(id, lastReassert: lastReassert)
                        return
                    }
                    if Self.tileHasPixels(image) {
                        if self.resistantConcealed.insert(id).inserted {
                            MenuBarAssessmentBackend.log.notice("resistant: \(id, privacy: .public) — pixels prove the escape; covering")
                        }
                    } else {
                        // A flat capture is the ghost — not an escapee,
                        // and the standings rule must not promote it.
                        self.pixelDisproven.insert(id)
                    }
                }
            } else {
                noteEscapeStanding(id, lastReassert: lastReassert)
            }
        }
        // `lastReassert` is also the standings clock: it must keep
        // advancing while unresolved escapees stand, or a lone stubborn
        // escapee collects one stamp and the three-stamp proof never
        // completes. The ≥20 s cadence matches `recordEscapeStanding`'s
        // spacing — each sweep is one stamp, and the re-assert itself is
        // the retry the standing item exists to provoke.
        let unresolved = standing.subtracting(resistantConcealed).subtracting(pixelDisproven)
        let sweepDue = !unresolved.isEmpty && now.timeIntervalSince(lastReassert) >= 20
        guard (!escaped.isEmpty && !throttled) || sweepDue else { return }
        lastReassert = now
        MenuBarAssessmentBackend.log.notice("reassert: \(escaped.sorted().joined(separator: ", "), privacy: .public) standing while concealed")
        concealer.reassert()
    }

    /// The no-permission proof: an escapee that stands through three
    /// re-asserts, each ≥20 s after the last, earns the cover the
    /// pixel test would have settled in one. `resistant:` logs only
    /// when the state actually fires.
    private func noteEscapeStanding(_ id: String, lastReassert: Date) {
        escapeStandings[id] = Self.recordEscapeStanding(
            stamps: escapeStandings[id] ?? [], lastReassert: lastReassert)
        if (escapeStandings[id]?.count ?? 0) >= 3,
           resistantConcealed.insert(id).inserted {
            MenuBarAssessmentBackend.log.notice("resistant: \(id, privacy: .public) stood through three re-asserts — covering")
        }
    }

    /// One more standing on a re-assert's stamp — a new stamp per
    /// re-assert, ≥20 s apart, so a still-standing item accumulates
    /// exactly one per sweep. Pure so the test pins the cadence.
    nonisolated static func recordEscapeStanding(stamps: [Date], lastReassert: Date) -> [Date] {
        guard lastReassert > .distantPast, stamps.last != lastReassert,
              stamps.last.map({ lastReassert.timeIntervalSince($0) >= 20 }) ?? true
        else { return stamps }
        return stamps + [lastReassert]
    }

    /// Capture the rect an escapee reports — the same path the Item
    /// Bar's tiles take (the display filter excludes our windows, so
    /// what lands is the item, not a cover). nil means capture is
    /// unavailable — no Screen Recording grant.
    private func captureEscapee(_ rect: CGRect) async -> CGImage? {
        if let escapeeCapture { return await escapeeCapture(rect) }
        if escapeeCaptureSource == nil { escapeeCaptureSource = DisplayFilterSource() }
        return await escapeeCaptureSource?.capture(rect)
    }

    /// Whether a captured tile proves the item draws pixels — a live
    /// escapee's glyph spreads luma widely over the bar's material;
    /// the Accessibility ghost's rect captures a featureless strip.
    nonisolated static func tileHasPixels(_ image: CGImage?) -> Bool {
        guard let image else { return false }
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            lumas.append(0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                         + 0.0722 * Double(pixels[i + 2]))
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)
        // A real item's glyph deviates hard from the flat material —
        // a std dev over ~20 luma points; uniform bar reads ~0.
        return variance > 400
    }

    /// One pass of ghost triage over a concealed app's items. An item
    /// proves live only by moving to an on-row frame it never reported
    /// while concealed — a novel slot is a registration the assertion
    /// did not adopt. A frozen frame, an off-row report, or a return
    /// to a slot the ghost already showed is still the Accessibility
    /// ghost the agent leaves behind: pressable, undrawn, harmless.
    /// Proof is NOT sticky — an item un-proves when its frame returns
    /// to a ghost slot, or when ten seconds pass without a novel slot
    /// (a still-standing "escapee" is the ghost relayouted, and a live
    /// item that keeps moving re-proves on its own). Pure so the test
    /// pins the table.
    /// `retain` holds item ids with a classification in flight — the
    /// standings proof needs ~60 s to accumulate, so the 10 s decay must
    /// not pull the ground out from under it. A ghost-frame return still
    /// un-proves regardless.
    nonisolated static let proofSeconds: TimeInterval = 10
    nonisolated static func concealedEscapees(
        onRow: Set<String>, frames: [String: CGRect], previous: [String: CGRect],
        ghostHistory: [String: Set<CGRect>], proven: [String: Date], now: Date,
        retain: Set<String> = []
    ) -> (proven: [String: Date], ghostHistory: [String: Set<CGRect>]) {
        var proven = proven
        var history = ghostHistory
        for id in onRow {
            guard let frame = frames[id] else { continue }
            let seen = history[id] ?? []
            if let stamp = proven[id] {
                if seen.contains(frame)
                    || (now.timeIntervalSince(stamp) > proofSeconds && !retain.contains(id)) {
                    proven[id] = nil
                } else {
                    continue
                }
            }
            let moved = previous[id].map { $0 != frame } ?? false
            if moved && !seen.contains(frame) {
                proven[id] = now
            } else {
                history[id, default: []].insert(frame)
            }
        }
        // Decay applies off-row too — a proven item that left the row
        // ten seconds ago is the ghost again, unless its classification
        // is still being settled.
        for (id, stamp) in proven
            where now.timeIntervalSince(stamp) > proofSeconds && !retain.contains(id) {
            proven[id] = nil
        }
        return (proven, history)
    }

    /// Whether a listed item is a concealed app's Accessibility ghost —
    /// a node still reporting the frame it froze at while the agent
    /// owns its pixels. Only an item that proved live by moving may
    /// speak for its bundle; the ghost must not write sections, learn
    /// drags or earn covers.
    private func isConcealedGhost(_ item: MenuBarItem) -> Bool {
        guard let id = item.bundleID,
              let section = liveSettings().concealedApps[id], section != .shown
        else { return false }
        return liveConcealedItems[item.id] == nil
    }

    private func concealedPlan(from listing: MenuBarHidePlan) -> MenuBarHidePlan {
        let all = listing.shown + listing.hidden + listing.alwaysHidden
        var seen: [String: [MenuBarItem]] = [:]
        for item in all {
            guard let id = item.bundleID else { continue }
            seen[id, default: []].append(item)
        }
        for (id, items) in seen { knownItems[id] = items }
        // Ghost eviction: an app that quit takes its remembered bounds
        // with it — stale frames must not feed the plan, the covers, or
        // the card forever.
        let running = runningApps.snapshot()
        for id in knownItems.keys where seen[id] == nil && !running.contains(id) {
            knownItems[id] = nil
        }
        // The live maps — the curated ones with any overlay laid over.
        let live = liveSettings()
        let apps = live.concealedApps
        // The positional map, read only for items the agent cannot
        // target (no bundle identifier) — see the cover-fallback below.
        let sections = live.sections
        var plan = MenuBarHidePlan()
        // Standing means on ANY display's bar — a secondary-screen item
        // is visible exactly like a main-row one.
        let rows = MenuBarItemLister.menuBarRows()
        let onRow: (CGRect) -> Bool = { bounds in rows.contains { $0.intersects(bounds) } }
        plan.shown = all.filter { item in
            // Positional overrides win for anything the agent cannot
            // take (Apple extras, bare helpers) — the cover-fallback
            // below draws them.
            if let override = sections[item.id], override != .shown { return false }
            guard let id = item.bundleID, let section = apps[id] else { return true }
            return section == .shown
        }.filter { onRow($0.bounds) || MenuBarItemLister.isProtected($0) }
        // The Item Bar mirrors the row's order: each app's last known
        // on-row x — the remembered items' frames where they are on the
        // row, plus every ghost slot history reported — and bundle IDs
        // nobody ever saw placed sort after, by name.
        var lastX: [String: CGFloat] = [:]
        for (id, items) in knownItems {
            for item in items where onRow(item.bounds) {
                lastX[id] = min(lastX[id] ?? .infinity, item.bounds.minX)
            }
        }
        for item in all {
            guard let id = item.bundleID,
                  let ghosts = concealedGhostFrames[item.id] else { continue }
            for ghost in ghosts where onRow(ghost) {
                lastX[id] = min(lastX[id] ?? .infinity, ghost.minX)
            }
        }
        for (id, section) in Self.concealedOrder(apps: apps, lastX: lastX) {
            let items = knownItems[id] ?? []
            switch section {
            case .hidden: plan.hidden.append(contentsOf: items)
            case .alwaysHidden: plan.alwaysHidden.append(contentsOf: items)
            case .shown: break
            }
        }
        // macOS parks overflow items nobody mapped — same semantic as
        // the hider's own plan: parked is hidden, it just isn't ours.
        // Without them the card's list and the Item Bar go blind to
        // half of what is actually off the row.
        let accounted = Set(plan.shown.map(\.id) + plan.hidden.map(\.id)
                            + plan.alwaysHidden.map(\.id))
        for item in all where !accounted.contains(item.id)
            && !MenuBarItemLister.isProtected(item) && !item.isNativeOverflowControl {
            // Positional picks under the concealer (Apple extras, bare
            // helpers): Auto stays where the row puts it — which is the
            // shown run it was already filtered out of, so only Honest
            // hidden assignments land here.
            switch sections[item.id] {
            case .some(.alwaysHidden): plan.alwaysHidden.append(item)
            case .some(.shown): break
            default: plan.hidden.append(item)
            }
        }
        // Cover-fallback, Ice-style: a hidden item still standing on
        // the row — one the agent cannot or will not take (Apple
        // extras, bare helpers, unattributed scene items) — gets a
        // cover where it sits. Remembered items are NOT cover
        // candidates: `knownItems` bounds are where the item last stood
        // before the agent removed it, so covering them paints empty
        // bar — and whatever lives there now, ears included (the tinted
        // "blue block" and the paved-over wings this once caused).
        // Agent-concealed items are not candidates either: the agent
        // owns their hiding, and a concealed item leaves the
        // Accessibility tree or reports the frame it last stood at — a
        // ghost that intersects the row. Covering the ghost paved the
        // stretch the *shown* run reflowed into.
        let listedIDs = Set(all.map(\.id))
        let concealed = MenuBarConcealPlan.concealed(apps: apps, revealed: hider.revealed)
        let agentOwned = { (item: MenuBarItem) in
            // Resistant escapees proven standing through a re-assert
            // are agent-proof: covers paint over them like the other
            // items the agent cannot take — except mid-reveal, when
            // the row is supposed to show what it hides.
            item.bundleID.map {
                concealed.contains($0)
                    && !(self.resistantConcealed.contains($0) && self.hider.revealed.isEmpty)
            } ?? false
        }
        var coverHidden: [MenuBarItem] = []
        var coverAlways: [MenuBarItem] = []
        for item in plan.hidden where listedIDs.contains(item.id)
            && onRow(item.bounds) && !agentOwned(item) { coverHidden.append(item) }
        for item in plan.alwaysHidden where listedIDs.contains(item.id)
            && onRow(item.bounds) && !agentOwned(item) { coverAlways.append(item) }
        var blockers = plan.shown.map(\.bounds)
        if let boundary = host?.boundaryFrame { blockers.append(boundary) }
        // The island (notch plus shoulders — the ears' home), the icon's
        // mirror (its ‹ included) and the standalone chevron are ours: a
        // merged run must break at them or the cover paves a surface it
        // shares the window level with. Their frames are AppKit's beside
        // the items' Quartz ones — `coverRuns` reads only x, which the
        // two spaces share.
        if let island = ScreenBarGeometry.islandScreenRect { blockers.append(island) }
        // The mirror's frame from before this pass seats it: a seat
        // that then moves re-plans the covers (`recutCovers`).
        if let mirror = standingMirrorFrame { blockers.append(mirror) }
        if let chevron = chevronScreenFrame() { blockers.append(chevron) }
        plan.hiddenCovers = MenuBarItemHider.coverRuns(covered: coverHidden, blockers: blockers)
        plan.alwaysHiddenCovers = MenuBarItemHider.coverRuns(covered: coverAlways, blockers: blockers)
        return plan
    }

    /// The Item Bar's app order under the concealer: the system menu
    /// bar's own left-to-right. Apps with a remembered on-row x sort
    /// by it; apps never seen placed follow, bundle ID as tiebreak.
    /// Pure so the test pins the order.
    nonisolated static func concealedOrder(
        apps: [String: MenuBarItemSection],
        lastX: [String: CGFloat]
    ) -> [(id: String, section: MenuBarItemSection)] {
        apps.sorted { lhs, rhs in
            let lx = lastX[lhs.key] ?? .infinity
            let rx = lastX[rhs.key] ?? .infinity
            return lx == rx ? lhs.key < rhs.key : lx < rx
        }.map { ($0.key, $0.value) }
    }

    /// Nothing is concealed on its own: hiding starts only when the
    /// person picks a section — the card's picker, an Item Bar tile, the
    /// menu, the palette. Under the concealer position never writes one:
    /// the agent reorders the bar itself and a concealed item cannot be
    /// ⌘-dragged, so a drag or a reflow would only ever teach noise.
    /// The marker stays for file compatibility — old files that carry
    /// an auto-seeded map are cleared by `migrateSectionsIfNeeded`.
    func seedConcealedAppsIfNeeded(from listing: MenuBarHidePlan) -> Bool {
        guard !settings().concealSeeded else { return true }
        // A fresh install whose own icon is parked at the first scan
        // must not block the engine forever: past `adoptionTimeout` the
        // path just marks the map seeded; nothing is inferred from the
        // listing.
        let ownPresent = listing.shown.contains { !Self.isForeignOwner($0.ownerName) }
        guard ownPresent
                || Date().timeIntervalSince(concealerStartedAt) >= Self.adoptionTimeout
        else { return false }
        update { draft in draft.concealSeeded = true }
        return true
    }

    /// Hand the concealer its target for the current reveal state.
    private func syncConcealer() {
        guard let concealer else { return }
        // Nothing of ours grows under the agent — whatever the spacer
        // engine wrote on the seeding pass folds back.
        host?.setBoundarySpacer(0)
        // The icon follows the engine from its first pass, not from the
        // first assertion.
        updateIconMirror()
        // The first assertion waits out the grace: a relaunch's previous
        // assertion is still draining for a beat after the engine comes
        // up. Nothing else gates it — macOS never draws our own item
        // under our assertion, so there is no adoption to wait for.
        let inGrace = Date().timeIntervalSince(concealerStartedAt) < Self.adoptionGrace
        if prePhotographPending, !concealer.isConcealing {
            // The one moment every app about to be hidden is still drawn:
            // photograph them (and the shown ones) before the first
            // assertion takes their pixels.
            if !inGrace {
                prePhotographPending = false
            } else {
                let standing = onRowItems(in: listedItems)
                if !standing.isEmpty {
                    prePhotographPending = false
                    photograph(standing)
                }
            }
        }
        guard concealer.isConcealing || !inGrace else { return }
        let concealed = concealTarget()
        concealer.apply(concealed: concealed, running: runningApps.snapshot())
        clickBridge?.update(items: lastPlan.shown, concealing: !concealed.isEmpty)
    }

    private func concealerChanged() {
        clickBridge?.update(items: lastPlan.shown, concealing: concealer?.isConcealing ?? false)
        refreshChevron()
        updateIconMirror()
        engineVersion += 1
    }

    // MARK: The glyph camera

    /// Photographs items while they are legitimately drawn and files
    /// their glyphs for the Item Bar. Set by the app delegate — a test
    /// utility has none, so no test ever captures the screen or writes
    /// the cache.
    @ObservationIgnored var glyphCamera: MenuBarGlyphCamera? {
        didSet {
            glyphCamera?.dark = { [weak self] in self?.barIsDark() ?? false }
            glyphCamera?.onChange = { [weak self] item in
                // A picture that changed while tucked away — the next
                // Item Bar marks it.
                self?.bar.updatedIDs.insert(item.id)
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
    @ObservationIgnored private var prePhotographPending = false
    /// This reveal's photographs are taken (or under way).
    @ObservationIgnored private var revealPhotographed = false
    /// Waits out the moment this reveal may be photographed.
    @ObservationIgnored private var revealPhotoWatch: Task<Void, Never>?

    /// The menu bar's appearance — the icon's, which follows the
    /// wallpaper under the bar, not the app's.
    private func barIsDark() -> Bool {
        let appearance = host?.face.appearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The items among `items` that stand on a bar and are someone
    /// else's to photograph — never ours, never the protected system
    /// items, and never an app the live assertion conceals right now
    /// (its frame is a ghost that draws nothing). Before the first
    /// assertion, and for the apps a reveal or a lift narrowed out of
    /// it, the items are drawn.
    private func onRowItems(in items: [MenuBarItem]) -> [MenuBarItem] {
        let rows = MenuBarItemLister.menuBarRows()
        let concealedNow = concealer?.concealedApps ?? []
        return items.filter {
            Self.photographable($0, among: items, rows: rows, concealed: concealedNow)
        }
    }

    /// Whether `item` can be photographed as itself: someone else's
    /// (never ours, never a protected system item, never the «), on a
    /// row, not concealed by the live assertion, and alone in its rect.
    /// A concealed app's ghost keeps reporting its old frame after the
    /// row repacks, so two listed items sharing a stretch of bar means
    /// one of them is a ghost over the other — and a photograph of that
    /// rect could file one app's glyph under the other's name. Pure so a
    /// test pins it.
    nonisolated static func photographable(_ item: MenuBarItem, among items: [MenuBarItem],
                                           rows: [CGRect], concealed: Set<String>) -> Bool {
        guard !hideAllTargets([item]).isEmpty,
              rows.contains(where: { $0.intersects(item.bounds) }),
              !(item.bundleID.map(concealed.contains) ?? false) else { return false }
        return !items.contains { other in
            other.id != item.id && other.bounds.intersection(item.bounds).width >= 4
        }
    }

    /// Drop the photographs of apps long gone: an owner that neither
    /// runs nor resolves on disk, photographed more than a month ago. A
    /// helper bundled inside another app resolves neither lookup, so the
    /// age is what keeps its glyph through a quiet spell. Launch-time
    /// housekeeping, a beat after the camera is set.
    private func pruneGlyphs() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let camera = self?.glyphCamera else { return }
            let now = Date()
            camera.cache.prune { owner, capturedAt in
                now.timeIntervalSince(capturedAt) < MenuBarGlyphCache.pruneAge
                    || !owner.contains(".")
                    || !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty
                    || NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) != nil
            }
        }
    }

    /// The photographed glyph for an item in the bar's appearance — the
    /// card's layout editor wears the Item Bar's faces.
    func glyphFace(for item: MenuBarItem) -> MenuBarGlyphCache.Face? {
        glyphCamera?.cache.face(for: item, dark: barIsDark())
    }

    /// One photograph pass, off the caller's stack.
    private func photograph(_ items: [MenuBarItem]) {
        guard let camera = glyphCamera, !items.isEmpty else { return }
        Task { [weak self] in
            let stored = await camera.photograph(items, rows: MenuBarItemLister.menuBarRows())
            if !stored.isEmpty { self?.bar.glyphsChanged() }
        }
    }

    /// While a reveal holds the concealed apps on the row, photograph
    /// the stale ones once — after the fade-in, and only while nobody is
    /// using the row: the pointer off every surface the reveal serves
    /// and no listed item's menu open. Each frame lights the recording
    /// indicator and shifts the bar, which must never land under a
    /// pointer aiming at the items the reveal just brought back. The
    /// watch is a pointer read and a window list twice a second, for
    /// the life of one reveal, and stops once the pass is taken.
    private func photographReveal() {
        guard concealer != nil, glyphCamera != nil, !hider.revealed.isEmpty else {
            revealPhotographed = false
            revealPhotoWatch?.cancel()
            revealPhotoWatch = nil
            return
        }
        guard !revealPhotographed, revealPhotoWatch == nil else { return }
        revealPhotoWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                guard self.concealer != nil, !self.hider.revealed.isEmpty else {
                    // The reveal (or the engine) went first: the next
                    // one starts a watch of its own.
                    self.revealPhotoWatch = nil
                    return
                }
                if !self.reveal.pointerOnRevealSurface(), !self.listedItemMenuOpen() {
                    self.revealPhotographed = true
                    self.revealPhotoWatch = nil
                    let tucked = MenuBarConcealPlan.concealed(apps: self.curatedSettings().concealedApps,
                                                              revealed: [])
                    let standing = self.onRowItems(in: self.listedItems).filter {
                        $0.bundleID.map(tucked.contains) ?? false
                    }
                    self.photograph(standing)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: Engine health and rivals

    /// Bumped whenever the engine's state moves, so the card's line
    /// observes it — the concealer itself is not observable.
    private(set) var engineVersion = 0

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

    /// The card's enumeration with the utility parked: refresh the AX
    /// snapshot (off-actor — a slow app must not stall the card) and
    /// run the listing-only plan — a parked utility draws no covers,
    /// so everything on the row reports as it sits.
    func refreshListing() {
        probeAccessibility()
        guard !running else { return }
        guard accessibilityGranted else {
            lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.list(), rows: MenuBarItemLister.menuBarRows())
            return
        }
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self, !self.running else { return }
            self.lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.axItems, rows: MenuBarItemLister.menuBarRows())
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

    /// The `.bar` reveal surface for a gesture — a hover, a click on the
    /// blank stretch, a scroll. A gesture only ever opens: a scroll
    /// stream re-fires every half second and a hover re-entry lands
    /// while the bar is up, and a toggle here flapped the bar shut under
    /// the hand (161 scroll notices in two minutes, 2026-09-22). A click
    /// on the blank stretch still folds an open bar — the bar's own
    /// outside-click monitor closes it — so a gesture landing in the same
    /// beat as that close does not reopen it. The deliberate toggle is
    /// `toggleHiddenSection` (the ‹, the menu, the hotkey). When the item
    /// list is empty — the grant is gone or macOS stopped reporting — an
    /// empty bar would answer the gesture with nothing, so a deployed
    /// hidden section falls back to the inline reveal: the covers drop
    /// and the run is reachable without any listing at all.
    private func revealBarStyle() {
        guard !bar.isOpen,
              !Self.gestureRefolds(closedAt: barClosedAtUptime,
                                   now: ProcessInfo.processInfo.systemUptime) else { return }
        if !barItems().isEmpty {
            bar.open()
            return
        }
        let glyph = host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength
        if (hider.assignedLengths[.hidden] ?? glyph) > glyph + 1 {
            hider.reveal([.hidden, .alwaysHidden])
        }
    }

    /// When the Item Bar last folded, in system uptime.
    @ObservationIgnored private var barClosedAtUptime: TimeInterval = -.infinity
    /// How close behind a fold a gesture counts as the click that
    /// folded it: the bar's monitor and the reveal's arrive as two
    /// unordered main-actor hops of the same event.
    nonisolated static let gestureRefoldWindow: TimeInterval = 0.3

    /// Whether a gesture at `now` belongs to the fold at `closedAt`.
    /// Pure so a test pins the window.
    nonisolated static func gestureRefolds(closedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - closedAt < gestureRefoldWindow
    }

    /// Whether an owner of a covered item currently has a menu-layer
    /// window up — the reveal must not fold the run out from under a
    /// menu the person is reading.
    private func listedItemMenuOpen() -> Bool {
        let pids = Set((lastPlan.hidden + lastPlan.alwaysHidden).map(\.ownerPID))
        guard !pids.isEmpty else { return false }
        return MenuBarItemLister.menuOpen(ownerPIDs: pids,
                                          infos: MenuBarItemLister.windowInfos())
    }

    /// `concealedApps` entries whose bundle identifier no longer
    /// resolves — uninstalled apps the map still carries. A quit app's
    /// id still resolves on disk, so only genuinely gone entries are
    /// dropped; the user's choices survive an app merely not running.
    private func pruneUninstalledConcealedApps() {
        let apps = settings().concealedApps
        guard !apps.isEmpty else { return }
        let stale = apps.keys.filter { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil
                // A helper bundled inside another app resolves neither
                // lookup but is installed and will be back — an id that
                // owned an item this session is not "uninstalled".
                && knownItems[id] == nil
        }
        guard !stale.isEmpty else { return }
        update { draft in
            for id in stale { draft.concealedApps.removeValue(forKey: id) }
        }
    }

    /// Anyone's item but ours — the system's extras included: a gesture
    /// must respect the clock and Wi-Fi, never our own spacer.
    nonisolated static func isForeignOwner(_ owner: String) -> Bool {
        !["JR-Bar", "JRBarApp"].contains(owner)
    }

    /// Our own family's bundle identifiers — the app's
    /// (`com.jonathanreed.jrbar`) and every helper it ships, the daemon
    /// `com.jonathanreed.jrbar.core` included. Their items are never
    /// conceal candidates: the agent would take them, and hiding our
    /// own meter behind our own utility is exactly the self-inflicted
    /// wound the running-set sweep once caused.
    nonisolated static func isOwnFamily(_ id: String?) -> Bool {
        guard let id, let own = Bundle.main.bundleIdentifier else { return false }
        return id == own || id.hasPrefix(own + ".")
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
        var frames = lastPlan.shown.filter {
            !$0.isNativeOverflowControl && Self.isForeignOwner($0.ownerName)
        }.map {
            NSRect(x: $0.bounds.minX, y: height - $0.bounds.maxY,
                   width: $0.bounds.width, height: $0.bounds.height)
        }
        // The standalone chevron (no host): its own button
        // action is the toggle — a click there must not ALSO land as a
        // blank-stretch reveal or a hide click double-fires. The same
        // for the extra items (spacers, agent, combined): their own
        // actions answer the click.
        if let frame = chevronScreenFrame() { frames.append(frame) }
        for item in spacerItems.values + [agentItem, combinedItem.item].compactMap({ $0 }) {
            if let quartz = Self.quartzFrame(of: item) {
                let height = CGDisplayBounds(CGMainDisplayID()).height
                frames.append(NSRect(x: quartz.minX, y: height - quartz.maxY,
                                     width: quartz.width, height: quartz.height))
            }
        }
        return frames
    }

    // MARK: Tile actions

    /// A plain click on a tile: `AXPress` the item's element —
    /// Accessibility required. It reaches a covered item without
    /// dropping the shutter and a system-parked item a click could
    /// never hit. Without the grant the tile just raises the owning
    /// app, the posture the permissions row sets — and so does an
    /// element that can no longer be resolved (the app reordered its
    /// extras mid-relaunch).
    private func trigger(_ item: MenuBarItem) {
        let granted = probeAccessibility()
        bar.close()
        guard granted else {
            item.owner?.activate()
            return
        }
        if concealer != nil, let id = item.bundleID,
           MenuBarConcealPlan.concealed(apps: liveSettings().concealedApps, revealed: hider.revealed).contains(id) {
            // Concealed: only this app stands. The assertion's target
            // narrows by exactly this bundle — every other hidden app
            // stays concealed, so the bar never lifts — then the item
            // gets a beat to draw, the press lands on its fresh frame,
            // and the full target goes back up after the rehide window.
            let rehide = settings().rehideSeconds
            // Held past the press and the rehide window; `releaseLift`
            // ends it once the app's menu is closed.
            lift(id, until: Date().addingTimeInterval(3 + rehide))
            Task { [weak self] in
                guard let self else { return }
                var fresh = item
                // Poll up to ~600 ms for the item's real frame — the
                // agent needs a beat to draw a just-unconcealed item,
                // and its ghost's frozen frame is not where it lands.
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    _ = await MenuBarItemLister.refreshAXItems()
                    if let found = MenuBarItemLister.axItems.first(where: { $0.id == item.id }) {
                        fresh = found
                        if MenuBarItemLister.onAnyMenuBarRow(found.bounds) { break }
                    }
                }
                if !MenuBarAX.press(fresh) {
                    await MainActor.run { self.clickFallback(fresh) }
                }
                try? await Task.sleep(nanoseconds: UInt64(rehide * 1e9))
                await self.releaseLift(id, item: fresh)
            }
            return
        }
        Task.detached { [weak self] in
            if MenuBarAX.press(item) { return }
            await MainActor.run { self?.clickFallback(item) }
        }
    }

    /// The no-press fallback: raise the owning app, the answer the
    /// no-Accessibility path gives. A posted click at the item's frame
    /// would move the person's pointer there — synthetic input the
    /// utility never sends on its own.
    private func clickFallback(_ item: MenuBarItem) {
        item.owner?.activate()
    }

    /// A ⌘-click on a tile: pull the item up into the hidden run and
    /// drop the spacer so it shows — the always-hidden section's own
    /// reveal gesture.
    private func revealItem(_ item: MenuBarItem) {
        setSection(.hidden, for: item.id)
        hider.reveal([.hidden])
        reveal.rearm()
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
            // The item registers a beat later — without the sync the
            // write can sit in the in-memory cache and cfprefsd hands
            // the registrar nothing.
            UserDefaults.standard.synchronize()
        }
    }

    /// The boundary. With a host — the app's own status item — the
    /// boundary is the host's spacer (and, under the concealer, the
    /// mirror's ‹); without one (tests, a build that never wired it) the
    /// separate chevron stands in. With a host the chevron does not exist
    /// at all: JR-Bar registers one status item, and a registered-but-
    /// hidden second one still read frames into the hot zones, the cover
    /// blockers and the ear limits. A host arriving while it stands
    /// takes it down. Safe to call any time.
    func installChevron() {
        if host == nil {
            // Registered once, born visible — a born-hidden item's
            // surface parks where it was born and never re-composites.
            installChevronItem()
        } else {
            removeChevronItem()
        }
        // Under the agent the hider never sizes the control — and no
        // affordance is claimed: the width pushed our slot into the
        // notch dead zone and parked the item. Under the spacer engine
        // the plan's own writes floor the mark; this only makes it
        // immediate.
        host?.setBoundarySpacer(concealer == nil ? Self.boundaryAffordance : 0)
        // The always-hidden control of earlier builds left its slot in
        // our defaults; a stale key is harmless but says nothing true.
        UserDefaults.standard.removeObject(
            forKey: "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-ah-control")
    }

    /// The fallback chevron: a status item of its own.
    private func installChevronItem() {
        guard chevron == nil else { return }
        // A fresh autosave name: the old record accumulated a dead
        // slot across the remove/install churn, and every recreation
        // under it was born parked. "v2" registers clean.
        Self.seedPreferredPosition(470, autosaveName: "com.jonathanreed.jrbar.menubar-chevron-v2")
        let item = NSStatusBar.system.statusItem(withLength: MenuBarControlFrames.glyphLength)
        item.autosaveName = "com.jonathanreed.jrbar.menubar-chevron-v2"
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
        ScreenBarGeometry.earItemLimitLeft = nil
        ScreenBarGeometry.earItemLimitRight = nil
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
                // The row names the toggle hotkey when it is on — the
                // keyboard's own way to the same bar.
                if settings().revealStyle == .bar,
                   let hotkey = resolvedHotkeyBindings().first(where: { $0.action == .toggleReveal && $0.enabled }),
                   let key = Self.menuKeyEquivalent(for: hotkey) {
                    menuItem.keyEquivalent = key
                    menuItem.keyEquivalentModifierMask = MenuBarHotkeyBinding.eventModifiers(hotkey.modifiers)
                }
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
        // The menu that acts: the apps standing on the bar, each a click
        // from hidden. While nothing hides yet they lead as the teaching
        // list; once something does they wait in a submenu.
        if let (inline, hideRows) = Self.hideMenu(
            shown: lastPlan.shown, hiddenCount: lastPlan.hidden.count + lastPlan.alwaysHidden.count) {
            let target: NSMenu
            menu.addItem(.separator())
            if inline {
                let header = NSMenuItem(title: "Hide in the Menu Bar", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                target = menu
            } else {
                let parent = NSMenuItem(title: "Hide Another App", action: nil, keyEquivalent: "")
                target = NSMenu()
                parent.submenu = target
                menu.addItem(parent)
            }
            for row in hideRows {
                let menuItem = NSMenuItem(title: row.title,
                                          action: #selector(MenuBarChevronActions.menuHideApp(_:)),
                                          keyEquivalent: "")
                menuItem.target = chevronActions
                menuItem.representedObject = row.itemID
                if let listed = lastPlan.shown.first(where: { $0.id == row.itemID }) {
                    let icon = listed.owner?.icon.flatMap { $0.copy() as? NSImage }
                    icon?.size = NSSize(width: 16, height: 16)
                    menuItem.image = icon
                }
                target.addItem(menuItem)
            }
        }
        // Which profile is laid over the bar, and a click away from the
        // others — no trip to Settings to see or switch.
        let rows = MenuBarCombinedMenu.profileRows(profiles: settings().profiles,
                                                   activeID: settings().curation.activeProfileID)
        if !rows.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for row in rows {
                let menuItem = NSMenuItem(title: row.title,
                                          action: #selector(MenuBarChevronActions.menuApplyProfile(_:)),
                                          keyEquivalent: "")
                menuItem.target = chevronActions
                menuItem.representedObject = row.id
                menuItem.state = row.active ? .on : .off
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    /// The menu's profile rows land here.
    fileprivate func menuProfileActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyProfile(id: id)
    }

    /// The icon menu's hide list for a bar: the rows a click could hide
    /// (someone else's, never a protected system item), inline while
    /// nothing hides yet, else behind a submenu — nil when there is
    /// nothing to offer. Pure so a test pins it.
    nonisolated static func hideMenu(shown: [MenuBarItem],
                                     hiddenCount: Int) -> (inline: Bool, rows: [MenuBarCombinedMenu.HideRow])? {
        let rows = MenuBarCombinedMenu.hideRows(shown: hideAllTargets(shown))
        return rows.isEmpty ? nil : (hiddenCount == 0, rows)
    }

    /// The menu's hide rows land here: the same pick the card's picker
    /// makes, so a profile that speaks for the app takes it.
    fileprivate func menuHideActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setSection(.hidden, for: id)
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
    private func toggleHiddenSection(fromKeyboard: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastChevronToggleAt) > 0.3 else { return }
        lastChevronToggleAt = now
        // The click's state is the Item Bar's, not the run's: a hover
        // can leave the run revealed with no surface up, and keying the
        // toggle on `revealed` then folds it back — the click that
        // "does nothing". Gating on the bar means every click answers:
        // the run's surface opens, or it closes.
        if bar.isOpen {
            reveal.cancelReveal()
            hider.hide()
            bar.close()
        } else if !hider.revealed.isEmpty {
            // The run is out on a hover reveal with no surface up: the
            // click puts it back — this is "Hide Items Again".
            hider.hide()
        } else if (lastPlan.hidden + lastPlan.alwaysHidden).isEmpty {
            // A dead click is the bug report it reads as: nothing is
            // parked, so the menu carries how the run earns items and
            // where they would list.
            popHiddenItemsMenu()
        } else {
            // `.inline` reflows the run onto the row (Ice, Hidden Bar);
            // `.bar` leaves it parked and answers with the Item Bar
            // alone (Bartender). One surface per style — an inline
            // reveal empties the run, so the panel would open blank.
            switch settings().revealStyle {
            case .inline:
                hider.reveal([.hidden])
            case .bar:
                bar.open(keyboard: fromKeyboard)
            }
            reveal.rearm()
        }
        refreshChevron()
    }

    /// The "Hidden Menu Bar Items" menu popped at the control that was
    /// clicked — with a teach row when the run is empty, so a dead run
    /// still answers the click with how to fill it. The toggle row is
    /// stripped here: "Reveal Hidden Items" with nothing hidden would
    /// just pop this same menu again.
    private func popHiddenItemsMenu() {
        guard let menu = hiddenItemsMenu() else { return }
        // entries() emits [toggle, openBar, items…]; drop the toggle.
        if let toggle = menu.items.first(where: {
            $0.action == #selector(MenuBarChevronActions.menuToggleHidden(_:)) }) {
            menu.removeItem(toggle)
        }
        // The hide rows teach by acting; the hint speaks only when there
        // is nothing on the bar a click could hide. Under the concealer
        // position teaches nothing — the picker is the way in; under the
        // spacer the mark is the separator.
        if !menu.items.contains(where: { $0.action == #selector(MenuBarChevronActions.menuHideApp(_:))
                                          || $0.submenu != nil }) {
            let hint = NSMenuItem(
                title: concealer != nil
                    ? "Pick apps to hide in Settings › Utilities › Menu Bar"
                    : "⌘-drag an item left of the ‹ mark to hide it",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.insertItem(hint, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        // Anchor at the click itself — the ‹ lives in the host's spacer
        // and the › in the island; the ear's clicks arrive off the
        // monitor where no currentEvent exists, so screen coords it is.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 4),
                   in: nil)
    }

    /// The ear's ‹ handle — the hidden run's affordance while the agent
    /// conceals and the real item is the icon: non-nil (the glyph's
    /// direction) while it should stand. The screen bar reads it through
    /// `menuHandleProvider`. While the mirror carries the icon its own ‹
    /// is the handle, and a second one on the ear ~165 pt away would
    /// only split the job — the right ear keeps just its provider mark.
    var menuHandleRevealed: Bool? {
        // The concealer's presence, not its instant assertion — a
        // reveal lifts it for seconds, and the handle is exactly the ‹
        // rehide affordance while the run is out. Seeded keeps it off a
        // map-less fresh bar.
        guard concealer != nil, settings().concealSeeded, !iconMirrored else { return nil }
        return hider.revealed.contains(.hidden)
    }

    /// The island handle's click — the same toggle the chevron answers.
    func toggleMenuHandle() {
        MenuBarCombinedItem.log.notice("menu handle click: hidden=\(self.lastPlan.hidden.count) revealed=\(self.hider.revealed.contains(.hidden))")
        toggleHiddenSection()
    }

    /// The faces follow the run's state: the fallback chevron points at
    /// where the items are (left while they are packed off the left
    /// edge, right while the run is out); the host takes the counts and
    /// draws its own hint.
    private func refreshChevron() {
        let revealed = hider.revealed.contains(.hidden)
        if let host {
            host.hiddenCount = lastPlan.hidden.count + lastPlan.alwaysHidden.count
            host.hiddenRevealed = revealed
        }
        // The ear's ‹ turns to › with the run: say so while it can stand.
        if revealed != handleRevealedSeen {
            handleRevealedSeen = revealed
            if concealer != nil { menuHandleChanged() }
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
            // The agent hides; nothing of ours ever grows — the
            // affordance floor would push our slot into the notch dead
            // zone and park the item.
            host?.setBoundarySpacer(0)
            return
        }
        switch section {
        case .hidden:
            if let host {
                host.setBoundarySpacer(max(Self.boundaryAffordance,
                                         length - host.boundaryGlyphLength))
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

    /// The nearest on-row item edge on each notch flank — the x each ear
    /// stops short of, so a drawn wing never paves a real item (the « a
    /// hidden run keeps beside the notch, our own chevron, whatever
    /// macOS parks in the flank). Item bounds and the island share the
    /// x axis across the Quartz/AppKit flip — only x limits are read.
    /// nil per side while the flank is free.
    private func publishEarAvoidance(_ plan: MenuBarHidePlan) {
        guard let island = ScreenBarGeometry.islandScreenRect else {
            ScreenBarGeometry.earItemLimitLeft = nil
            ScreenBarGeometry.earItemLimitRight = nil
            return
        }
        let s = liveSettings()
        let (left, right) = Self.earLimits(
            items: plan.shown + plan.hidden + plan.alwaysHidden,
            island: island, row: MenuBarItemLister.menuBarRow(),
            concealedApps: s.concealedApps, sections: s.sections,
            revealed: hider.revealed, chevron: chevronScreenFrame(),
            ourPID: ProcessInfo.processInfo.processIdentifier)
        if ScreenBarGeometry.earItemLimitLeft != left {
            ScreenBarGeometry.earItemLimitLeft = left
        }
        if ScreenBarGeometry.earItemLimitRight != right {
            ScreenBarGeometry.earItemLimitRight = right
        }
    }

    /// The ear-limit classifier — pure so tests drive it without a notch
    /// window. The nearest on-row item edge on each flank is the limit;
    /// side is decided by centre, not edge clearance, because an item
    /// that merely straddles the island's edge — our own boundary icon
    /// seats that close — used to fail both tests and earn no limit at
    /// all, so the wing drew straight over it. A limit inside the
    /// island's span just suppresses the ear, which is the honest answer
    /// when the flank is already taken.
    ///
    /// Items our own process owns never earn a limit. Under the
    /// concealer none of them is drawn: macOS hides our own item under
    /// our own assertion, so the real item is slim and blank, and the
    /// icon is the mirror, our own surface right of the band. An
    /// undrawn slot of ours clamping an ear only took the ear off empty
    /// bar — the blank-face bug: the slim item beside the notch's edge,
    /// the ear yielding to it, and nothing visible where the icon sat.
    nonisolated static func earLimits(
        items: [MenuBarItem], island: CGRect, row: CGRect,
        concealedApps: [String: MenuBarItemSection],
        sections: [String: MenuBarItemSection],
        revealed: Set<MenuBarItemSection>, chevron: CGRect?,
        ourPID: pid_t
    ) -> (left: CGFloat?, right: CGFloat?) {
        var left: CGFloat? = nil
        var right: CGFloat? = nil
        for item in items {
            if item.ownerPID == ourPID { continue }
            let f = item.bounds
            guard f.intersects(row) else { continue }
            // A parked or covered item is already invisible — the wing
            // may stand on its slot without paving anything the person
            // can see. A revealed run stands for real and still counts.
            let section = item.bundleID.flatMap { concealedApps[$0] } ?? sections[item.id]
            if let section, section != .shown, !revealed.contains(section) { continue }
            if f.midX <= island.midX {
                left = max(left ?? -.infinity, f.maxX)
            } else {
                right = min(right ?? .infinity, f.minX)
            }
        }
        // The standalone chevron is ours — the lister keeps it out of
        // the plan, so its live frame joins the limits separately.
        if let chevron {
            if chevron.midX <= island.midX {
                left = max(left ?? -.infinity, chevron.maxX)
            } else {
                right = min(right ?? .infinity, chevron.minX)
            }
        }
        return (left, right)
    }

    /// The chevron's live frame in AppKit screen coordinates — nil until
    /// its button has a window.
    private func chevronScreenFrame() -> NSRect? {
        guard let button = chevron?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.frame)
    }

    /// The stretch a hover or an empty-space click reveals: from the
    /// region's edge to the boundary glyph's right edge, in AppKit
    /// screen coordinates. nil while no boundary stands.
    private func revealZone() -> NSRect? {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        if concealer != nil {
            // Under the concealer the zone is the blank run the hidden
            // apps leave left of the icon — from where nothing covers the
            // row (the notch, the band and its ears, the front app's
            // menus) to the mirror's left edge, on the row the mirror
            // stands on. A notch-less bar also keeps only its right half:
            // the menu edge is missing while the front app does not
            // answer AX, and a hover over the File menu must never pop
            // the run.
            let row = Self.primaryRow()
            var start = mirrorClearOf()
            if NSScreen.screens.first?.auxiliaryTopRightArea == nil { start = max(start, row.midX) }
            let mirrorMinX = iconMirrored ? standingMirrorFrame?.minX : nil
            let shown = lastPlan.shown.filter {
                $0.bounds.intersects(row) && Self.isForeignOwner($0.ownerName)
                    && !$0.isNativeOverflowControl
            }.map(\.bounds.minX)
            guard let span = Self.concealedRevealSpan(start: start, mirrorMinX: mirrorMinX,
                                                      shownMinXs: shown) else {
                // No computable stretch: the hot frames alone answer
                // the gesture — the whole row must never pop the run.
                return NSRect.zero
            }
            return NSRect(x: span.lowerBound, y: height - row.maxY,
                          width: span.upperBound - span.lowerBound, height: row.height)
        }
        let row = MenuBarItemLister.menuBarRow()
        let frames = controlFrames()
        guard let boundary = frames.hidden, boundary.intersects(row) else { return nil }
        // The blank stretch starts where the spacer may land, less the
        // room the « takes — a gesture on the « is a gesture on the run.
        let edge = (hider.fitEdge ?? boundary.minX) - 30
        let minX = min(edge, boundary.minX)
        return NSRect(x: minX, y: height - row.maxY,
                      width: max(0, boundary.maxX - minX), height: row.height)
    }

    /// The concealer's reveal span on x: from `start` to the mirror's
    /// left edge — or, while no mirror stands, the leftmost foreign
    /// shown item right of `start`. Our own items never bound it (the
    /// slim real item sits wherever macOS keeps it), and the icon itself
    /// is never inside it. nil when there is no stretch. Pure so a test
    /// pins it.
    nonisolated static func concealedRevealSpan(start: CGFloat, mirrorMinX: CGFloat?,
                                                shownMinXs: [CGFloat]) -> ClosedRange<CGFloat>? {
        guard let end = mirrorMinX ?? shownMinXs.filter({ $0 > start }).min(),
              end > start else { return nil }
        return start...end
    }

    /// The last scan's hidden-item titles for "show for updates" —
    /// empty while the feature is off or unseeded.
    @ObservationIgnored private var updateSignatures: [String: String] = [:]
    /// The pending re-hide an update reveal scheduled.
    @ObservationIgnored private var updateHideTask: Task<Void, Never>?

    /// Bartender's "show for updates": a hidden item that rewrote its
    /// title — a clock's minute, a VPN's "Connected" — reveals its run
    /// for the re-hide interval so the change is seen, then parks
    /// again. Seeded silently on the first plan and skipped while a
    /// reveal is open, so the feature never announces its own motion.
    private func noticeUpdates(in plan: MenuBarHidePlan) {
        guard settings().showForUpdates else {
            updateSignatures = [:]
            updateHideTask?.cancel()
            updateHideTask = nil
            return
        }
        let result = MenuBarItemHider.updatedHidden(
            previous: updateSignatures,
            hidden: plan.hidden,
            alwaysHidden: plan.alwaysHidden)
        let seeded = !updateSignatures.isEmpty
        let previous = updateSignatures
        updateSignatures = result.signatures
        guard seeded, !result.sections.isEmpty, hider.revealed.isEmpty else { return }
        let changed = plan.hidden.map { ($0, MenuBarItemSection.hidden) }
            + plan.alwaysHidden.map { ($0, MenuBarItemSection.alwaysHidden) }
        let reveal = Self.updateReveal(
            changed: changed.filter { item, _ in
                previous[item.id].map { $0 != result.signatures[item.id] } ?? false
            },
            watch: Set(settings().curation.updateWatch),
            concealing: concealer != nil)
        let seconds = settings().rehideSeconds
        // Under the concealer the changed app stands alone for the clock
        // — one item joins the row, not the whole run.
        for app in reveal.lifts {
            lift(app, until: Date().addingTimeInterval(seconds))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                self?.syncConcealer()
            }
        }
        guard !reveal.sections.isEmpty else { return }
        hider.reveal(reveal.sections)
        updateHideTask?.cancel()
        updateHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.hider.hide()
        }
    }

    /// The combined popover's agents line: the feed's combined state,
    /// its detail, its tint.
    func combinedAgentLine() -> MenuBarSystemModel.AgentLine {
        let read = agentState()
        return MenuBarSystemModel.AgentLine(label: "Agents — \(read.state.label)",
                                            detail: read.detail, tintHex: read.state.tintHex)
    }

    /// The owner key "show for updates" watches an item by: its bundle,
    /// or its own id for a helper without one.
    nonisolated static func updateWatchKey(_ item: MenuBarItem) -> String {
        item.bundleID ?? item.id
    }

    /// What one show-for-updates pass acts on: the changed hidden items
    /// the watch list lets through (all of them while it is empty). An
    /// app the concealer takes is lifted alone; anything else — a covered
    /// extra, any item under the spacer engine — reveals its section.
    /// Pure so a test pins it.
    nonisolated static func updateReveal(changed: [(MenuBarItem, MenuBarItemSection)],
                                         watch: Set<String>,
                                         concealing: Bool) -> (lifts: Set<String>, sections: Set<MenuBarItemSection>) {
        var lifts = Set<String>()
        var sections = Set<MenuBarItemSection>()
        for (item, section) in changed where watch.isEmpty || watch.contains(updateWatchKey(item)) {
            if concealing, let app = item.bundleID, MenuBarConcealPlan.canConcealApp(app) {
                lifts.insert(app)
            } else {
                sections.insert(section)
            }
        }
        return (lifts, sections)
    }

    /// Whether "show for updates" watches `item` by name — false while
    /// the watch list is empty (then it watches everything).
    func watchesUpdates(of item: MenuBarItem) -> Bool {
        settings().curation.updateWatch.contains(Self.updateWatchKey(item))
    }

    /// Mark or unmark an item's owner for "show for updates".
    func setWatchesUpdates(_ on: Bool, for item: MenuBarItem) {
        let key = Self.updateWatchKey(item)
        update { draft in
            draft.curation.updateWatch.removeAll { $0 == key }
            if on { draft.curation.updateWatch.append(key) }
        }
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
        // The palette's truth is the effective section: under the
        // concealer a concealed item reads hidden, so its row offers
        // "Show" and "Open" — never "Hide".
        var map: [String: MenuBarItemSection] = [:]
        for item in listedItems { map[item.id] = effectiveSection(for: item) }
        return map
    }

    /// Empty under the concealer — the palette's "Arrange…" row then has
    /// no order to drive and never moves the cursor (see
    /// `arrangeAvailable`).
    func menuBarArrangeOrder(for _: MenuBarActions) -> [String] {
        arrangeAvailable ? settings().arrangeOrder : []
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

    /// The `toggleReveal` hotkey is the chevron's click: whatever the
    /// transition is — reveal when the run is parked, re-hide when a
    /// reveal is out — it happens.
    func menuBarActionsToggleReveal(_: MenuBarActions) {
        // The hotkey's bar is the keyboard's: it takes key, and the
        // arrows, a typed filter and Return reach every hidden item
        // without the pointer.
        toggleHiddenSection(fromKeyboard: true)
    }

    /// The dedicated always-hidden gesture: drop that run's covers on
    /// the rehide clock. Under the concealer the reveal set narrows
    /// the assertion the same way — the deeper apps stand back on the
    /// row for the window.
    func menuBarActionsRevealAlwaysHidden(_: MenuBarActions) {
        hider.reveal([.alwaysHidden])
        reveal.rearm()
    }

    func menuBarActions(_: MenuBarActions, revealFor seconds: Double) {
        hider.reveal([.hidden])
        reveal.rearm(for: seconds)
    }

    func menuBarActionsHideAll(_: MenuBarActions) {
        hideAllListed()
    }

    func menuBarActionsShowAll(_: MenuBarActions) {
        showAllListed()
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

    /// The hotkeys' step through the profiles — from the active one,
    /// persisted, so the cycle picks up where the card or a rule left it.
    /// The built-in "None" sits first.
    func menuBarActions(_: MenuBarActions, cycleProfile direction: Int) {
        let profiles = settings().profiles
        guard !profiles.isEmpty else { return }
        applyProfile(id: MenuBarProfiles.cycled(from: settings().curation.activeProfileID,
                                                profiles: profiles, direction: direction))
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

/// The boundary's host: what the Menu Bar utility needs from the app's
/// own status item to make it the hidden run's edge — its frame, its
/// icon's width, a spacer write, the reveal click, the hidden-items
/// submenu, and the counts it draws its hint from — and, under the
/// concealer, what the mirror needs to stand in for it.
@MainActor
protocol MenuBarBoundaryHost: AnyObject {
    /// The icon's frame in Quartz coordinates — the mirror's face while
    /// it carries the icon; nil before the item has a window.
    var boundaryFrame: CGRect? { get }
    /// The icon's own width — the part that is not spacer.
    var boundaryGlyphLength: CGFloat { get }
    /// Claim `length` points of blank bar left of the icon (0 folds).
    func setBoundarySpacer(_ length: CGFloat)
    /// Whether the configured style draws an icon at all — every style
    /// but `.hidden`. Only a drawn icon gets a mirror.
    var anchorWantsVisibleSeat: Bool { get }
    /// Hand the icon to the mirror (true) or take it back. While
    /// mirrored the real item wears nothing and keeps a slim slot — the
    /// single owner of both, so no other path can un-blank it.
    func setFaceMirrored(_ mirrored: Bool)
    /// The mirror's face frame in AppKit screen coordinates while it
    /// carries the icon — the panel anchors on it. The utility writes it
    /// on every move and nils it when the mirror goes down.
    var mirroredFaceFrame: NSRect? { get set }
    /// What the icon wears, for the mirror.
    var face: MenuBarIconFace { get }
    /// Fires whenever `face` changes — the mirror is pushed, never polls.
    var onFaceChange: (@MainActor () -> Void)? { get set }
    /// The icon's ordinary click — the panel toggle.
    func faceClicked()
    /// The icon's right/Option click — the item's full menu, popped
    /// under `view`.
    func popUpMenu(in view: NSView)
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

    @objc func menuApplyProfile(_ sender: NSMenuItem) {
        utility?.menuProfileActivated(sender)
    }

    @objc func menuHideApp(_ sender: NSMenuItem) {
        utility?.menuHideActivated(sender)
    }
}
