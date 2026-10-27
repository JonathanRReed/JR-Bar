import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import OSLog
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
/// gesture, and the boundary's click toggles the run by hand. Tile
/// clicks go through `AXPress`; an element that cannot be resolved
/// raises its app instead — the pointer never moves.
@MainActor
@Observable
final class MenuBarUtility: Toy {
    /// The menu bar's log (`devin.jrbar`, category `menubar`): the engine,
    /// drag and record lines the owner's tools read.
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

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
    /// connects the daemon leases.
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

    /// The latest layout — the card's count row and item list read it.
    /// While the utility runs the hider keeps it fresh; while it is
    /// parked the card's `refreshListing()` fills it once, spacers down.
    var lastPlan = MenuBarHidePlan() {
        didSet { reconcileItemHotkeys() }
    }
    @ObservationIgnored var itemShortcutNative = MenuBarItemShortcutNative.live
    /// Spacers parked, monitors up.
    private(set) var running = false
    /// Accessibility, re-polled at most every `accessibilityPollSeconds`
    /// and probed on a listing refresh, a tile click, and each start —
    /// never per render, per event, or on the reconcile cadence. That is
    /// plain thrift; TCC does not need it: `AXIsProcessTrusted` sends
    /// one `TCCAccessRequest` IPC on its first call only (measured
    /// 2026-09-22; see `MenuBarItemLister.axTrusted`).
    private(set) var accessibilityGranted = false {
        didSet { refreshInventoryState() }
    }
    private(set) var inventoryState: MenuBarInventoryState = .checking
    @ObservationIgnored var readAccessibilityTrust: @MainActor () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored var readInventoryEvidence: @MainActor () -> (generation: Int, complete: Bool) = {
        (MenuBarItemLister.axGeneration, MenuBarItemLister.axInventoryComplete)
    }

    func refreshInventoryState() {
        let evidence = readInventoryEvidence()
        inventoryState = MenuBarInventoryState.assess(
            granted: accessibilityGranted, generation: evidence.generation, complete: evidence.complete)
    }
    @ObservationIgnored private var accessibilityCheckedAt = Date.distantPast
    /// The minimum gap between TCC polls.
    nonisolated static let accessibilityPollSeconds: TimeInterval = 3

    /// The cached grant, refreshed when the cache is stale. A parked
    /// utility asks nothing of TCC at all — the probe only runs on
    /// demand.
    @discardableResult
    func probeAccessibility(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(accessibilityCheckedAt) > Self.accessibilityPollSeconds {
            accessibilityCheckedAt = now
            accessibilityGranted = readAccessibilityTrust()
            reconcileItemHotkeys()
        }
        return accessibilityGranted
    }

    /// The hidden-items submenu's target: target/action needs an
    /// `NSObject`, so its rows' clicks land on this box and forward.
    @ObservationIgnored let menuActions = MenuBarMenuActions()
    /// The full-bar tint underlay.
    @ObservationIgnored let underlay = MenuBarUnderlay()
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
    /// The prune's installed-app answers (`pruneUninstalledConcealedApps`).
    @ObservationIgnored var installedApps = InstalledBundleCache()

    // MARK: The divider
    // The pure parts are in MenuBarDividerRoom.swift; the wiring is in
    // MenuBarUtilityEngine.swift.

    /// Whether the divider's icon holds a place on this bar.
    @ObservationIgnored var dividerRoom = MenuBarDividerRoomWatch()
    /// The clock the engine choice and the pointer gate read; a test
    /// cranks it by hand.
    @ObservationIgnored var engineClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Holds the bar still while a ⌘-drag moves an item and for a beat
    /// after the drop (`MenuBarPointerGate`).
    @ObservationIgnored var pointerGate = MenuBarPointerGate()
    /// The live left button; a test hands its own.
    @ObservationIgnored var leftButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// The plan at the ⌘-press, to read what the drop changed against.
    @ObservationIgnored var dividerDragBefore: MenuBarHidePlan?
    /// A drop happened and its result has not been read yet.
    @ObservationIgnored var dividerDropPending = false
    /// What the last drop changed, in words — the card's "Last change".
    @ObservationIgnored var lastPositionChange: String?
    /// The positional list a divider run is about to write, and how many
    /// passes in a row agreed on it.
    @ObservationIgnored var pendingPositionalList: (list: [String: MenuBarItemSection], seen: Int, since: TimeInterval)?
    /// The check after an inline reveal for hidden items that did not fit.
    @ObservationIgnored var remainderTask: Task<Void, Never>?

    // MARK: Provider — who renders

    /// Re-resolved on every workspace launch/terminate so an external
    /// pick's running/installed state flips live in the card — the
    /// notch's pattern; stored so Observation tracks the read.
    private(set) var workspaceVersion = 0
    /// The provider watch's observers — installed for the object's life.
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
                set: { provider in
                    let probe: ExternalAppProbe?
                    switch provider {
                    case .jrbar: probe = nil
                    case .bartender: probe = ExternalProviders.bartender
                    case .ice: probe = ExternalProviders.ice
                    case .hiddenBar: probe = ExternalProviders.hiddenBar
                    }
                    guard probe?.installed != false else { return }
                    self.update { $0.provider = provider }
                    probe?.open()
                })
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

    /// The drop zone the boundary always claims while the utility is
    /// on — wide enough for the ‹ mark the host draws inside it. An
    /// invisible stretch of bar is no affordance; Bartender keeps its
    /// separator on the row permanently too.
    nonisolated static let boundaryAffordance: CGFloat = 30

    /// "Open Shortcuts" on the card's Hotkeys row: the page that holds
    /// this utility's keys. The Utilities store wires it to Settings.
    @ObservationIgnored var onOpenShortcuts: (@MainActor () -> Void)?

    /// The boundary's host — the app's own status item. Everything
    /// left of it is the hidden run; it grows the spacer, draws the
    /// hint, takes the reveal click and carries the hidden-items
    /// submenu. Without a host there is no boundary.
    @ObservationIgnored weak var host: (any MenuBarBoundaryHost)? {
        didSet {
            host?.onBoundaryClick = { [weak self] in self?.boundaryClicked() }
            host?.onBoundaryWidthChange = { [weak self] in
                guard let self, self.settings().enabled, self.settings().provider == .jrbar,
                      let host = self.host else { return }
                self.hider.glyphWidthChanged(to: host.boundaryGlyphLength)
                self.installBoundary()
                self.hider.reconcile()
            }
            host?.hiddenItemsMenu = { [weak self] in self?.hiddenItemsMenu() }
            if running { hider.controlsReinstalled(); installBoundary() }
        }
    }

    init() {
        // The hider plans against the live map — the curated one with
        // Hide all / Show all laid over it — never the stored copy.
        hider.settings = { [weak self] in self?.liveSettings() ?? MenuBarSettings() }
        hider.listingIsComplete = {
            !MenuBarItemLister.axTrusted() || MenuBarItemLister.axInventoryComplete
        }
        hider.onInventoryUpdate = { [weak self] in self?.refreshInventoryState() }
        actions.itemHotkeys.activate = { [weak self] target, lease in
            guard let self else { return .utilityOff }
            return await self.openShortcutTarget(target, lease: lease)
        }
        hider.onPlan = { [weak self] plan in
            guard let self else { return }
            self.lastPlan = plan
            self.refreshBoundary()
            self.publishEarAvoidance(plan)
            self.pollDisplayProfile()
            self.bar.syncItems()
            // The writing passes land off the plan's stack — a settings
            // write inside `onPlan` would nest a whole reconcile inside
            // one, and the updates pass can itself reveal. Deferred like
            // `pollDisplayProfile`'s apply.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notePositions(in: plan)
                self.noticeUpdates(in: self.lastPlan)
                self.pruneUninstalledConcealedApps()
                self.noticeNewcomers()
                self.refreshEarFeed()
            }
        }
        // Our own control is never covered — its live frame splits
        // cover runs even on the no-AX path where it cannot list.
        hider.protectedFrames = { [weak self] in
            guard let self, let frame = self.host?.boundaryOccupiedFrame else { return [] }
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
            if settings.hideUnderNotch, let screen = MenuBarItemLister.managedScreen,
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
        // A standing "Show everything" folds the divider away: every item
        // drawn is the way out that always works.
        hider.forcedReveal = { [weak self] in
            guard let self, self.activeOverlay == .showEverything else { return [] }
            return [.hidden, .alwaysHidden]
        }
        hider.onParkedLesson = { [weak self] in
            guard let self else { return }
            self.dividerRoom.noteParkedLesson(now: self.engineClock())
        }
        reveal.settings = { [weak self] in self?.settings() ?? MenuBarSettings() }
        // The reveal zone is the row minus the *visible* items — the
        // covered stretch is exactly the space a gesture lands on.
        reveal.itemFrames = { [weak self] in self?.shownItemFrames() ?? [] }
        reveal.revealZone = { [weak self] in self?.revealZone() }
        reveal.gestureOwnedElsewhere = { [weak self] point in self?.earAnswersGesture(point) ?? false }
        // Only blank space left of the chevron reveals; the icon opens its own panel.
        reveal.hotFrames = { [weak self] in
            [self?.host?.boundaryHoverFrame].compactMap { $0 }
        }
        // The native button owns every click, including its icon's panel action.
        reveal.clickHandledFrames = { [weak self] in
            guard let frame = self?.controlFrames().hidden else { return [] }
            let height = CGDisplayBounds(CGMainDisplayID()).height
            return [NSRect(x: frame.minX, y: height - frame.maxY,
                           width: frame.width, height: frame.height)]
        }
        reveal.barFrame = { [weak self] in self?.bar.panelFrame }
        reveal.itemMenuOpen = { [weak self] in self?.listedItemMenuOpen() ?? false }
        // A held button — a ⌘-drag in flight, or the beat after one — is
        // never a hover: the drop lands in the blank stretch, and the
        // Item Bar popped under the hand there (2026-09-24 12:17:18).
        reveal.suppressed = { [weak self] in
            NSEvent.pressedMouseButtons & 1 != 0 || (self?.pointerHolds() ?? false)
        }
        // A ⌘-drag moves items under the divider: the hider reads and
        // writes nothing until the drop has settled, then once.
        hider.pointerHolds = { [weak self] in self?.pointerHolds() ?? false }
        // The reveal's own discrete monitor reports the ⌘-press and the
        // release that ends it; the divider only holds the bar still.
        reveal.onCommandDown = { [weak self] point, _ in
            self?.dividerDragPressed(at: Self.quartzPoint(point))
        }
        reveal.onPointerUp = { [weak self] _, _ in
            self?.dividerDragReleased()
        }
        // The reveal style picks the surface: `.bar` opens the Item
        // Bar — Bartender's model, the row stays as it is — while
        // `.inline` reflows the run onto the row, Ice and Hidden Bar's
        // model.
        reveal.onReveal = { [weak self] in
            guard let self else { return }
            switch self.settings().revealStyle {
            case .inline:
                self.hider.reveal([.hidden])
                self.openBarForRemainder()
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
        // The bar hangs under the real icon.
        bar.anchorFrame = { [weak self] in
            guard let self else { return nil }
            // Bartender Golden Gate's default: the bar under the pointer.
            if self.settings().curation.itemBarAt == .pointer {
                let point = NSEvent.mouseLocation
                return NSRect(x: point.x, y: point.y, width: 0, height: 0)
            }
            return self.dividerGlyphFrame()
        }
        bar.centersOnAnchor = { [weak self] in self?.settings().curation.itemBarAt == .pointer }
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
        // A tile dragged out of the bar onto the menu bar: right of the
        // icon shows its app.
        bar.onDragOut = { [weak self] item, point in self?.tileDropped(item, at: point) }
        // A drop's note hangs under the icon, like the bar.
        bar.noteAnchorFrame = { [weak self] in self?.dividerGlyphFrame() }
        // "Show when it changes" — offered only while show for updates is
        // on, so the menu never promises what the feature won't do.
        bar.updateWatch = { [weak self] item in
            guard let self, self.settings().showForUpdates else { return nil }
            return self.watchesUpdates(of: item)
        }
        bar.onUpdateWatch = { [weak self] item, on in self?.setWatchesUpdates(on, for: item) }
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
            } else {
                // A covered item still renders under our shutter:
                // photograph the stale ones for the tiles.
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
        // A stopped hider is never re-planned: its reconcile would put
        // covers back over a bar the utility just gave up.
        stateRules.onLayersChange = { [weak self] in
            guard let self, self.running else { return }
            self.hider.reconcile()
        }
        stateRules.onOutcomeChange = { [weak self] in self?.stateOutcomeVersion += 1 }
        menuActions.utility = self
        // Provider watch: a counterpart launching or quitting flips
        // the card's note live; this pair rides for the object's life.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            providerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
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
        underlay.hide()
    }

    // MARK: Toy

    let id = "menuBar"
    let name = "Menu Bar"
    let blurb = "Menu bar item hiding and reveal controls."
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

    /// The card's per-item picker: the write is the single mapping and
    /// the cover lands where the item already sits — nothing is ever
    /// dragged anywhere.
    func setSection(_ section: MenuBarItemSection, for itemID: String) {
        // The divider's sections are positions. Always hidden is an
        // override (a cover where the item sits) and so is clearing one;
        // anything else is a ⌘-drag only the person can make.
        let overridden = settings().sections[itemID].map { $0 != .shown } ?? false
        if section == .alwaysHidden || overridden {
            writeCoverPick(section, for: itemID)
            return
        }
        let known = listedItems + lastPlan.hidden + lastPlan.alwaysHidden
        guard let item = known.first(where: { $0.id == itemID }) else {
            writeCoverPick(section, for: itemID)
            return
        }
        guideDrag(item: item, to: section)
    }

    /// The Overrides rows' write: an explicit cover where the item sits
    /// (the person asked for exactly that), through the same path the
    /// always-hidden pick takes.
    func setCoverOverride(_ section: MenuBarItemSection, for itemID: String) {
        writeCoverPick(section, for: itemID)
    }

    /// Whether an app can be on the positional record: any but Apple's
    /// own, whose extras and system items stay where macOS puts them.
    nonisolated static func recordsApp(_ bundleID: String) -> Bool {
        !bundleID.hasPrefix("com.apple.")
    }

    /// A positional pick: into the active profile's delta when it speaks
    /// for the item (kept explicit — a delta's Shown must outrank the
    /// base), else onto the base map. Returns where it landed.
    @discardableResult
    private func writeCoverPick(_ section: MenuBarItemSection, for itemID: String) -> String {
        var landed = "cover"
        update { draft in
            if MenuBarProfiles.pickTargetsProfile(itemID: itemID, in: draft),
               let profileID = draft.curation.activeProfileID {
                MenuBarProfiles.setDelta(itemID: itemID, to: section,
                                         profileID: profileID, in: &draft)
                landed = "cover, profile \(profileID)"
            } else {
                draft.sections = MenuBarItemHider.updatedSections(
                    items: listedItems, sections: draft.sections,
                    changedID: itemID, target: section)
            }
        }
        return landed
    }

    /// The cover override an item carries — the curated map, the base with
    /// the active profile laid over it. A standing Hide all / Show all is
    /// not a pick and never shows in the pickers. Where an item sits left
    /// or right of the icon is position, and reads as shown here.
    func effectiveSection(for item: MenuBarItem) -> MenuBarItemSection {
        curatedSettings().sections[item.id] ?? .shown
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
        let standing = settings().curation.overlay.flatMap { $0.isLive() ? $0 : nil }
        // "Show everything" is the way out, so no rule outvotes it — it
        // stands until the person restores, or its clock runs out.
        if standing?.kind == .showEverything { return false }
        let manual = standing.map { Date(timeIntervalSince1970: $0.sinceEpoch) }
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

    /// Every app with an item on the bar — what the quiet bar tucks away
    /// on the record, less ours and Apple's.
    private func overlayApps() -> Set<String> {
        Set(listedItems.compactMap(\.bundleID)).filter {
            Self.recordsApp($0) && !Self.isOwnFamily($0)
        }
    }

    /// Every item the quiet bar covers in place: every listed foreign
    /// item. Protected items — the clock, Control Center — never.
    private func overlayItemIDs() -> Set<String> {
        Set(Self.hideAllTargets(listedItems).map(\.id))
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

    /// The escape hatch: every item back, whatever stood before. Unlike
    /// `showAllListed`, which is the second half of a Hide all / Show all
    /// pair and so *restores* over a quiet bar, this always shows
    /// everything — a person who pressed Show all to get out of a
    /// tucked-away bar must never land on a bar still hiding their picks.
    /// The picks are kept; Restore (or `.restoreBar`) puts them back.
    func showEverythingNow(for duration: TimeInterval? = nil) {
        update { draft in
            draft.curation.overlay = MenuBarOverlay(
                kind: .showEverything,
                untilEpoch: duration.map { Date().addingTimeInterval($0).timeIntervalSince1970 })
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
    /// item covered in place (or every cover cleared), then the overlay
    /// drops. Only ever on this explicit ask.
    func keepOverlay() {
        guard let kind = activeOverlay else { return }
        let targets = Self.hideAllTargets(listedItems)
        update { draft in
            switch kind {
            case .hideEverything:
                for item in targets where draft.sections[item.id] != .alwaysHidden {
                    draft.sections[item.id] = .hidden
                }
            case .showEverything:
                draft.concealedApps = draft.concealedApps.mapValues { _ in .shown }
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

    /// The profile editor's rows: every listed item is its own row, covered
    /// in place. Protected items and our own family never.
    var profileSubjects: [MenuBarProfileSubject] {
        Self.hideAllTargets(listedItems).map { item in
            MenuBarProfileSubject(
                key: item.id,
                title: item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName, item: item)
        }
    }

    /// The profile editor's write for a covered item — nil makes the item
    /// follow the base.
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
        guard let onSettingsChange else { return }
        var draft = settings()
        guard let oldName = draft.profiles.first(where: { $0.id == id })?.name else { return }
        let mapping = MenuBarProfiles.rename(id: id, to: name, in: &draft)
        guard let newName = draft.profiles.first(where: { $0.id == id })?.name,
              newName != oldName else { return }
        if let mapping {
            stateRules.renameProfile(from: mapping.from, to: mapping.to)
        }
        onSettingsChange(draft)
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
        if facts.live, settings().curation.sceneBeforeRule != nil {
            update { $0.curation.sceneBeforeRule = nil }
        }
        guard running else {
            // A stopped utility — disabled, or handed over to another
            // manager — holds nothing and writes nothing: the one-shot
            // engine hears the samples against no rules, and the "while"
            // levels are seeded afresh on the next start.
            let day = MenuBarSystemTriggerSource.dayStamp()
            for sample in samples {
                _ = actions.triggerEngine.matchedRules(for: sample, rules: [], dayStamp: day)
            }
            return
        }
        for sample in samples { systemTriggerSource.emit(sample) }
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
        actions.scripts.synchronize(settings().triggerRules)
        migrateSectionsIfNeeded()
        migratePositionModel()
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
            hider.reconcile()
            syncActions()
            syncExtras()
        }
    }

    /// The spacing value this run already pushed into the global
    /// domain — a re-apply with the same setting is a no-op.
    private var lastSpacingApplied = -1
    @ObservationIgnored private var lastSpacingAttempted = -1
    private let spacingWriter = MenuBarSpacing.Writer()
    @ObservationIgnored var spacingWrite: ((Int, Bool) -> Bool)?
    private(set) var spacingError: String?

    func retrySpacing() {
        lastSpacingAttempted = -1
        syncSpacing()
    }

    /// The card's item-spacing picker → the current-host global
    /// domain. Writing a value marks the setting managed so picking
    /// the default later removes the keys; a value never written
    /// leaves whatever the system (or a `defaults` user) has alone.
    func syncSpacing() {
        let s = settings()
        guard s.itemSpacing != lastSpacingApplied else {
            lastSpacingAttempted = s.itemSpacing
            spacingError = nil
            return
        }
        guard s.itemSpacing != lastSpacingAttempted else { return }
        lastSpacingAttempted = s.itemSpacing
        spacingError = nil
        let saved = spacingWrite?(s.itemSpacing, s.itemSpacingManaged)
            ?? spacingWriter.write(spacing: s.itemSpacing, managed: s.itemSpacingManaged)
        guard saved else {
            lastSpacingApplied = -1
            spacingError = "Could not save spacing. Retry before relaunching apps."
            Self.log.error("spacing: could not save preferences")
            return
        }
        if s.itemSpacing > 0 {
            lastSpacingApplied = s.itemSpacing
            if !s.itemSpacingManaged {
                update { $0.itemSpacingManaged = true }
            }
        } else if s.itemSpacingManaged {
            lastSpacingApplied = 0
            update { $0.itemSpacingManaged = false }
        } else {
            lastSpacingApplied = 0
        }
    }

    /// A file from the cover era assigned every item hidden — under
    /// the position model that map would cover every item right of the
    /// chevron in place. Hiding is opt-in: the person's ⌘-drag layout and
    /// the pickers are the arrangement now. The record keeps only the
    /// apps it can speak for (`recordsApp`).
    func migrateSectionsIfNeeded() {
        let current = settings()
        let legacy = current.layoutModel < MenuBarSettings.currentLayoutModel
        let supported = current.concealedApps.filter { Self.recordsApp($0.key) }
        let snapshots = current.curation.profileModel < MenuBarCuration.currentProfileModel
        let moved = supported != current.concealedApps
        guard legacy || snapshots || moved else { return }
        update { draft in
            // Profiles move to deltas against today's base first, so
            // each keeps exactly the layout it had.
            MenuBarProfiles.migrateToDeltas(&draft)
            if legacy {
                draft.sections = [:]
                // Keep explicit app picks before retiring the cover-era map.
                // The divider cannot move them, so retain them as placement
                // suggestions as well as in the saved record.
                let picks = supported.filter { $0.value != .shown }.keys
                if draft.curation.positionModel < MenuBarCuration.currentPositionModel {
                    draft.curation.dividerSuggestions = Array(
                        Set(draft.curation.dividerSuggestions).union(picks)).sorted()
                }
                draft.concealedApps = supported
                draft.layoutModel = MenuBarSettings.currentLayoutModel
            } else if moved {
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

    @ObservationIgnored private var startGeneration = 0

    private func start() {
        guard !running else { return }
        running = true
        startGeneration += 1
        let generation = startGeneration
        startSettleUntil = Date().addingTimeInterval(Self.startSettle)
        probeAccessibility()
        Self.forgetRetiredItems()
        installBoundary()
        hider.start()
        reveal.start()
        // The divider is the engine: it stands from the first moment and
        // takes no assertion.
        Self.log.notice("engine: divider — positionsHold")
        hider.reconcile()
        engineVersion += 1
        // Bindings land before start so registration uses the persisted
        // set, not the defaults the actions object was built with.
        syncActions()
        actions.start()
        reconcileItemHotkeys(force: true)
        failedHotkeyActions = actions.hotkeys.failedActions
        syncExtras()
        startDeskWatch()
        // First AX fill — a no-op without the grant — then reconcile
        // against real frames.
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self, self.running, self.startGeneration == generation else { return }
            self.hider.reconcile()
        }
    }

    /// Close the bar and release its observers and controls. The daemon
    /// expires any automatic leases that cannot be released during quit.
    func stop(forQuit: Bool = false) {
        guard running else { return }
        bar.close()
        reveal.stop()
        hider.stop()
        actions.stop()
        dividerRoom.reset()
        pointerGate = MenuBarPointerGate()
        dividerDragBefore = nil
        dividerDropPending = false
        pendingPositionalList = nil
        remainderTask?.cancel()
        remainderTask = nil
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
            MainActor.assumeIsolated {
                self?.displaysChanged()
                self?.scheduleDeskRead(after: Self.deskSettle)
            }
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

    // MARK: The glyph camera
    // Its code is in MenuBarUtilityGlyphs.swift.

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
            glyphCamera?.locate = { item in
                guard let listed = await MenuBarItemLister.freshAXItems(),
                      let fresh = listed.first(where: { $0.id == item.id }) else { return nil }
                return Self.photographable(fresh, among: listed, rows: MenuBarItemLister.menuBarRows())
                    ? fresh : nil
            }
            pruneGlyphs()
        }
    }

    // MARK: Engine health and rivals

    /// Bumped whenever the divider's state moves, so the card's line
    /// observes it.
    var engineVersion = 0

    /// Whether the divider is hiding the bar.
    var engineHealth: MenuBarEngineHealth {
        _ = engineVersion
        return .assess(running: running)
    }

    /// The page's single answer to "is hiding working, and if not, why".
    var hidingStatus: MenuBarHidingStatus {
        MenuBarHidingStatus.assess(hidingStatusInputs)
    }

    var hidingStatusInputs: MenuBarHidingStatus.Inputs {
        _ = engineVersion
        _ = workspaceVersion
        let current = settings()
        var inputs = MenuBarHidingStatus.Inputs()
        inputs.enabled = current.enabled
        if current.provider != .jrbar {
            inputs.externalProvider = providerName
            inputs.externalProviderRunning = externalProbe?.running ?? false
        }
        inputs.engine = engineHealth
        inputs.overlay = activeOverlay
        inputs.overlayNote = overlayNote
        inputs.accessibilityGranted = accessibilityGranted
        inputs.inventoryComplete = inventoryState == .complete
        inputs.rivals = runningRivals.map(\.name)
        inputs.dividerHidden = dividerHiddenCount
        inputs.revealed = hider.revealed.contains(.hidden) || hider.revealed.contains(.alwaysHidden)
        inputs.recovery = hider.wake.verdict
        inputs.noRoom = dividerRoom.room == .noRoom
        inputs.noRoomHelp = dividerRoomHelp
        inputs.iconLeftmost = dividerIconLeftmost
        return inputs
    }

    /// Whether the Item Bar's tiles are app icons for want of Screen
    /// Recording: the glyph camera photographs each item while it is still
    /// drawn, and macOS has not allowed it to. Says why a tile looks plain.
    var glyphsNeedScreenRecording: Bool {
        guard let glyphCamera else { return false }
        return !glyphCamera.permitted()
    }

    /// A banner button's action. Every one is the person's click.
    func perform(_ fix: MenuBarHidingStatus.Fix) {
        switch fix {
        case .showEverything: showEverythingNow()
        case .restoreBar: restoreCuratedBar()
        case .openAccessibility: openAccessibilitySettings()
        case .quitRival(let name):
            if let rival = runningRivals.first(where: { $0.name == name }) { quitRival(rival) }
        case .turnOff: isOn = false
        case .openProvider: openExternal()
        }
        engineVersion += 1
    }

    /// The card's "Right now" line.
    var engineLine: String {
        engineHealth.line(fitEdge: hider.fitEdge)
    }

    /// Other menu-bar managers running while ours renders — their
    /// hiding fights ours. Empty while a counterpart
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

    /// The fit-edge dial for the spacer engine — a nudge, a reset.
    func nudgeFitEdge(by delta: CGFloat) { hider.nudgeFitEdge(by: delta) }
    func resetFitEdge() { hider.forgetFitEdge() }

    /// Keep the actions object's moving parts in step with the
    /// persisted settings: the hotkey list (the empty file means the
    /// shipping set — toggling one materializes the whole list) and
    /// the trigger feed, which runs only while a rule can fire.
    private func syncActions() {
        reconcileItemHotkeys()
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

    /// Whether the Notch, a drawn wing or its attached menu owns the
    /// current pointer gesture. Native reveal stands down there.
    @ObservationIgnored var earAnswersGesture: @MainActor (NSPoint) -> Bool = { _ in false }

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

    // MARK: ⌘-drag across the icon
    // Its code is in MenuBarUtilityDrag.swift.

    /// The icon's span on x as the person sees it. A test hands its own.
    @ObservationIgnored var dragIconSpan: (@MainActor () -> ClosedRange<CGFloat>)?
    /// Every display's menu bar row, the main one first — a test hands
    /// its own.
    @ObservationIgnored var dragRows: (@MainActor () -> [CGRect])?
    /// Where a drop's note is said — the Item Bar's glass under the icon
    /// by default; a test records it instead of standing a panel.
    @ObservationIgnored var presentDropNote: (@MainActor (String) -> Void)?

    /// Menu bar apps quitting and reopening for the spacing, in flight.
    var relaunchingApps: [String] = []

    /// A rule's keep-awake hold — the app's own hold by default; a test
    /// records it.
    @ObservationIgnored var holdAwake: @MainActor (Int?) -> Void = { seconds in
        _ = Task { await AppCommandRouter.shared.perform(.keepAwake(seconds: seconds)) }
    }

    // MARK: Permissions

    /// The card's "Open Settings" for the click-through row.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        DesktopServices.automatic.open(url)
    }
}

/// One row of a profile's editor: an item (keyed by its identity) that
/// covers in place.
struct MenuBarProfileSubject: Identifiable, Equatable {
    var key: String
    var title: String
    /// A listed item of the subject's, for the row's icon.
    var item: MenuBarItem
    var id: String { "item:" + key }
}
