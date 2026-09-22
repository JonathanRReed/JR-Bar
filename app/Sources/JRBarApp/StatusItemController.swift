import AppKit
import JRBarCore
import JRBarUI
import QuartzCore

/// `redraw`'s decision, computed pure so the reconciliation rules are
/// testable: the spec the renderer draws, the label the button carries
/// (only the glyph-and-label style has one), and the width a strip
/// claims for `statusItem.length`. A nil width means the item keeps the
/// square size — or the label's variable length.
struct StatusItemPlan: Equatable {
    var spec: StatusIconSpec
    var label: String?
    /// The strip's width when the style is a strip (meters or session
    /// dots), nil for the square styles and the label style.
    var stripWidth: CGFloat?
    /// Whether the style owns the item's length.
    var isStrip: Bool { stripWidth != nil }
}

/// The menu-bar item: the `menu_bar_icon_style` look — a dot per live
/// session (the default), a meter per provider, or the glyph alone, in a
/// usage ring, or beside a label. Left click opens the panel; right click
/// (or Option-click) shows a small utility menu. Stage-2 escalation
/// pulses the icon amber.
///
/// It is also the Menu Bar utility's boundary: everything left of this
/// icon is the hidden run, and hiding is the item growing a blank
/// spacer to its left (`boundarySpacer`) that packs those items off the
/// row. The icon keeps its place at the spacer's right end, with a
/// small chevron beside it while anything is tucked away; a click on
/// the blank part is the reveal, a click on the icon is the panel as
/// ever.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, MenuBarBoundaryHost {
    /// The `AXIdentifier` JR-Bar's own status item carries.
    nonisolated static let accessibilityIdentifier = "com.jonathanreed.jrbar.status-item"

    /// `var`, not `let`: the item is re-created by `reseatStatusItem`
    /// when the menu-bar agent leaves it a ghost — registered while an
    /// assertion held, it keeps a stale slot and draws nothing until a
    /// fresh registration lands inside a suspend window.
    private var statusItem: NSStatusItem
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let feedItem = NSMenuItem()
    private let coreItem = NSMenuItem()
    private let snoozedItem = NSMenuItem()
    private let escalationItem = NSMenuItem()
    private let showBarItem: NSMenuItem
    private let renderer = StatusIconRenderer.shared
    private var currentSpec: StatusIconSpec?
    private var currentLabel: String?
    /// The icon's own image and width before the boundary spacer is
    /// folded in — what `redraw` decided, kept so a spacer change can
    /// re-fold without re-deciding.
    private var naturalImage: NSImage?
    private var naturalWidth: CGFloat = 0
    /// Points of blank bar the item claims left of its icon — the Menu
    /// Bar utility's spacer. 0 is the plain icon.
    private(set) var boundarySpacer: CGFloat = 0
    /// The composite face for the current spacer, memoised on the
    /// natural image's identity: the breathing dot redraws twice a
    /// second and must not re-rasterise a 200-point image each time.
    private var foldedCache: (source: NSImage, spacer: CGFloat, chevron: Bool, appearance: String, image: NSImage)?
    /// The Menu Bar utility's hooks: a click on the blank part of the
    /// item, and the "Hidden Items" submenu it builds for the menu.
    var onBoundaryClick: (@MainActor () -> Void)?
    var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
    /// The hidden run's state for the tooltip and the chevron: how many
    /// items are tucked away and whether they are out right now.
    var hiddenCount = 0 { didSet { if hiddenCount != oldValue { syncTooltip(); refold() } } }
    var hiddenRevealed = false { didSet { if hiddenRevealed != oldValue { refold() } } }
    private let hiddenItemsMenuItem = NSMenuItem(title: "Hidden Menu Bar Items", action: nil, keyEquivalent: "")
    private var aggregateTint: NSColor?
    private(set) var isPulsing = false
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var onTogglePanel: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    var onOpenOverview: (@MainActor () -> Void)?
    var onOpenReplay: (@MainActor () -> Void)?
    var onOpenUsageCenter: (@MainActor () -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    var onOpenControlCenter: (@MainActor () -> Void)?
    var onUnsnoozeAll: (@MainActor () -> Void)?
    var isScreenBarShown = true { didSet { showBarItem.state = isScreenBarShown ? .on : .off } }
    /// The style and ring the next `update` draws with.
    var iconStyle: StatusIconStyle = .agents {
        didSet {
            guard iconStyle != oldValue else { return }
            syncBreathing()
            applyPulseAnimation()
            redraw()
        }
    }
    var ringFraction: Double? { didSet { if ringFraction != oldValue { redraw() } } }
    var labelText: String? { didSet { if labelText != oldValue { redraw() } } }
    /// One meter per provider shown in the panel, in the panel's order,
    /// already capped by the renderer's `maxMeters` with the rest in `overflow`.
    var meters: [StatusMeter] = [] { didSet { if meters != oldValue { redraw() } } }
    var meterOverflow = 0 { didSet { if meterOverflow != oldValue { redraw() } } }
    /// The state dot; `.working` and `.ask` run the 2 Hz breathing timer,
    /// the other two are still pictures.
    var dotState: StatusDotState = .idle {
        didSet {
            guard dotState != oldValue else { return }
            syncBreathing()
            redraw()
        }
    }
    /// The `agents` style: one dot per live session, in the panel's order.
    /// An ask or a failure in the list runs the same breathing timer the
    /// meters' dot does.
    var sessionDots: [SessionDot] = [] {
        didSet {
            guard sessionDots != oldValue else { return }
            syncBreathing()
            applyPulseAnimation()
            redraw()
        }
    }
    /// One tooltip line per session for the `agents` style
    /// ("docs-sweep · waiting on you 2h 31m · Gemini"), same order.
    var sessionLines: [String] = [] { didSet { if sessionLines != oldValue { redraw() } } }
    private static let pulseKey = "jrbar.escalationPulse"
    /// The breathing clock: two frames a second, only while the dot moves.
    private static let breathingInterval: TimeInterval = 0.5
    private var breathing: Timer?
    private var phase: Double = 0
    /// The width the status item was last given, so a same-width redraw
    /// does not churn the menu bar's layout.
    private var currentWidth: CGFloat = 0

    override init() {
        Self.seedPreferredPosition(for: "com.jonathanreed.jrbar.status-item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        showBarItem = NSMenuItem(title: "Show Screen Bar", action: #selector(toggleScreenBar(_:)), keyEquivalent: "")
        super.init()
        wireStatusItem()

        if let button = statusItem.button {
            button.image = renderer.image(for: StatusIconSpec(style: .agents))
        }

        headerItem.isEnabled = false
        detailItem.isEnabled = false
        feedItem.isEnabled = false
        coreItem.isEnabled = false
        snoozedItem.isHidden = true
        snoozedItem.target = self
        snoozedItem.action = #selector(unsnoozeAll(_:))
        escalationItem.isHidden = true
        escalationItem.isEnabled = false
        showBarItem.target = self
        showBarItem.state = .on

        let open = NSMenuItem(title: "Open Panel", action: #selector(openPanel(_:)), keyEquivalent: "")
        open.target = self
        let history = NSMenuItem(title: "History…", action: #selector(openHistory(_:)), keyEquivalent: "y")
        history.target = self
        let overview = NSMenuItem(title: "Overview…", action: #selector(openOverview(_:)), keyEquivalent: "o")
        overview.target = self
        let replay = NSMenuItem(title: "Event Replay…", action: #selector(openReplay(_:)), keyEquivalent: "r")
        replay.target = self
        let usage = NSMenuItem(title: "Usage Center…", action: #selector(openUsageCenter(_:)), keyEquivalent: "u")
        usage.target = self
        let effects = NSMenuItem(title: "Effect Studio…", action: #selector(openEffects(_:)), keyEquivalent: "")
        effects.target = self
        let controlCenter = NSMenuItem(title: "Control Center…", action: #selector(openControlCenter(_:)), keyEquivalent: "k")
        controlCenter.target = self

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(coreItem)
        menu.addItem(feedItem)
        menu.addItem(snoozedItem)
        menu.addItem(escalationItem)
        menu.addItem(.separator())
        menu.addItem(open)
        menu.addItem(history)
        menu.addItem(overview)
        menu.addItem(replay)
        menu.addItem(usage)
        menu.addItem(effects)
        menu.addItem(controlCenter)
        menu.addItem(showBarItem)
        hiddenItemsMenuItem.isHidden = true
        menu.addItem(hiddenItemsMenuItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit JR-Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false
        menu.delegate = self
        update(state: .idle, detail: "Starting")
        setFeed(description: "resolving")
        setCore(description: "connecting")
    }

    /// Fires when the status item's menu opens — the app uses it to poke
    /// the daemon's menu-open refresh so the meters shown are fresh
    /// rather than the idle cadence's last reading.
    var onMenuWillOpen: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuWillOpen?()
    }

    /// The identity and wiring a fresh status item needs — autosave name,
    /// AX identifier, button target/action. Runs at init and again on
    /// every re-seat.
    /// How many times this process has re-seated the item — each re-seat
    /// registers under a fresh autosave name because the parked generation's
    /// record re-parks any recreation that reuses it (the wound the chevron
    /// fix documented under `menubar-chevron-v2`).
    private var reseatCount = 0

    /// Writes the `NSStatusItem Preferred Position` record a fresh
    /// autosave name needs before it registers — the value a Command-drag
    /// would store. macOS reads it as the distance from the screen's
    /// right edge to the item's centre (measured 2026-09-21: a seed of
    /// 640 landed a probe at x≈861; the seed is a preference, so the
    /// nearest legal slot wins when the target is taken). With no record
    /// a new item seeds at the bar's leftmost free run — the notch dead
    /// zone on this hardware — and parks there, which is how an unseeded
    /// re-seat kept recreating the ghost. An existing record is the
    /// person's own placement and is never overwritten unless `overwrite`
    /// is passed — re-seat names are our own transient records, and a
    /// poisoned one must never survive into the next registration.
    ///
    /// The write is synchronised before returning: `UserDefaults.set`
    /// only updates the in-memory cache and flushes on its own schedule,
    /// and an item registered in the same run loop turn reads cfprefsd
    /// before the seed lands there — measured 2026-09-21: every in-process
    /// seeded re-seat still parked until the write was forced down.
    static func seedPreferredPosition(for name: String,
                                      desiredMidX: CGFloat? = nil,
                                      overwrite: Bool = false) {
        let key = "NSStatusItem Preferred Position \(name)"
        if !overwrite, UserDefaults.standard.object(forKey: key) != nil { return }
        let screenW = NSScreen.main?.frame.width
            ?? CGDisplayBounds(CGMainDisplayID()).width
        let midX = desiredMidX ?? visibleSeatMidX(screenW: screenW)
        UserDefaults.standard.set(Float(screenW - midX), forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// The seat the icon wants when nothing says otherwise: the first
    /// slot clear of the band's covering surface — the leftmost
    /// position of the *visible* extras run. The Screen Bar window
    /// overhangs the physical notch by the wings' claim (up to
    /// `wingContentMaxExtent`, measured 132 pt live), so the old target
    /// of "just right of the notch" (screenW/2 + 115 → x≈871) seated the
    /// item under the band's right wing where its housing and tray paint
    /// black over it — the invisible-icon wound of 2026-09-22. The live
    /// window frame wins once the band is up; before layout the notch's
    /// right edge plus the wings' maximum claim is the estimate, and on
    /// a notch-less screen it falls back to the old centre-right guess —
    /// no surface is covering anything there anyway.
    static func visibleSeatMidX(screenW: CGFloat) -> CGFloat {
        visibleSeatMidX(coveringRight: ScreenBarGeometry.coveringScreenRect?.maxX,
                        notchEdge: NSScreen.main?.auxiliaryTopRightArea?.minX,
                        screenW: screenW)
    }

    /// The seat's pure math: the covering surface's live right edge wins
    /// (the band window outreaches the island — its wings' claims carry
    /// it past the notch), the notch edge plus the wings' maximum claim
    /// is the pre-layout estimate, and a notch-less screen keeps the old
    /// centre-right guess — nothing covers an item there.
    nonisolated static func visibleSeatMidX(coveringRight: CGFloat?,
                                            notchEdge: CGFloat?,
                                            screenW: CGFloat) -> CGFloat {
        if let coveringRight { return coveringRight + visibleSeatMargin }
        if let notchEdge {
            return notchEdge + ScreenBarGeometry.wingContentMaxExtent + visibleSeatMargin
        }
        return screenW / 2 + 115
    }

    /// How far past the island's right edge the icon's centre sits —
    /// half the widest style plus a gap, so even a full-width meters
    /// strip lands entirely clear of the face.
    nonisolated static let visibleSeatMargin: CGFloat = 30

    private func wireStatusItem() {
        // Where the item sits is the person's to choose (Command-drag);
        // macOS gives no API to ask for a slot. A stable autosave name is
        // the one thing the app can do: it is the key macOS remembers that
        // choice under, so a rebuild does not send the item back to the
        // middle of a busy menu bar.
        statusItem.autosaveName = reseatCount == 0
            ? "com.jonathanreed.jrbar.status-item"
            : "com.jonathanreed.jrbar.status-item-r\(reseatCount)"
        logProbeOnce()
        // The Menu Bar utility finds this item in the AX listing by the
        // identifier — its slot is where a migrated chevron seats.
        statusItem.button?.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "JR-Bar"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// The Menu Bar utility's adoption repair: drop the ghosted item and
    /// register a fresh one (inside the agent's suspend window, where the
    /// re-registration is adopted). The parked slot's saved position would
    /// re-park the fresh item, so its defaults key goes first.
    func reseatStatusItem(desiredMidX: CGFloat?) {
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        // Seed the fresh name at the item's *intended* slot, not the
        // frame it reports now: a re-seat only ever runs against a
        // parked item, and a parked window's screen frame is the
        // off-row park slot — seeding from it re-parks the recreation
        // (measured 2026-09-21: parked frames fed midX≈18, every
        // re-seat landed at (7,970) again). The caller's target is the
        // left end of the visible run; with none, the default sits
        // just clear of the band, the slot a healthy layout gives us.
        let midX = desiredMidX
        NSStatusBar.system.removeStatusItem(statusItem)
        reseatCount += 1
        // Re-seat names repeat across launches (reseatCount restarts at
        // 0), so a poisoned record from an earlier session would outlive
        // the guard — overwrite is the only honest write here.
        Self.seedPreferredPosition(
            for: "com.jonathanreed.jrbar.status-item-r\(reseatCount)",
            desiredMidX: midX, overwrite: true)
        // The primary record put the item where a re-seat was needed —
        // under the band's face or off the row — so it was never a
        // placement the person chose. Move it to the seat this re-seat
        // takes, so the next launch registers there directly instead of
        // repeating the covered beat and the re-seat.
        Self.seedPreferredPosition(
            for: "com.jonathanreed.jrbar.status-item",
            desiredMidX: midX, overwrite: true)
        // Born slim under the agent — a variable-length birth would
        // claim the icon's full width for a beat and could park before
        // the clamp lands.
        statusItem = NSStatusBar.system.statusItem(
            withLength: anchorSlim ? Self.anchorSlimLength : NSStatusItem.variableLength)
        wireStatusItem()
        // Re-apply the face the old item wore: force the redraw past the
        // spec cache, then fold the boundary spacer back into the length.
        currentSpec = nil
        redraw()
        refold()
    }

    /// The button's frame in screen coordinates, for anchoring the panel.
    var anchorRect: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: MenuBarBoundaryHost

    /// The item's frame in Quartz coordinates (top-left origin), the
    /// space the Menu Bar utility measures in.
    var boundaryFrame: CGRect? {
        guard let rect = anchorRect else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The item window's occlusion state — the honest read on whether the
    /// surface composites. A parked item's window reports its logical
    /// frame forever; only the occlusion says nothing is on the glass.
    var boundaryOcclusion: NSWindow.OcclusionState? {
        statusItem.button?.window?.occlusionState
    }

    func logProbeOnce() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self else { return }
            NSLog("JRBAR-PROBE healthy-read: \(self.boundaryWindowProbe)")
        }
    }

    var boundaryWindowProbe: String {
        guard let w = statusItem.button?.window else { return "window=nil" }
        let num = w.windowNumber
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ours = onScreen.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == Int32(ProcessInfo.processInfo.processIdentifier) }
        let bounds = ours.compactMap { $0[kCGWindowBounds as String] as? [String: Double] }
            .map { "(\($0["X"]!),\($0["Y"]!),\($0["Width"]!)x\($0["Height"]!))" }
        return "isVis=\(w.isVisible) space=\(w.isOnActiveSpace) screen=\(w.screen != nil) alpha=\(w.alphaValue) num=\(num) cgwindows=\(bounds)"
    }

    /// The face the item currently draws — read straight off the button
    /// so the concealer's mirror shows whatever style is live, meters
    /// and all.
    var boundaryIconImage: NSImage? { statusItem.button?.image }

    /// The icon's own width — the part of the item that is not spacer.
    var boundaryGlyphLength: CGFloat {
        naturalWidth > 0 ? naturalWidth : NSStatusBar.system.thickness
    }

    /// The utility's write: claim `length` points of blank bar left of
    /// the icon (0 collapses to the plain icon).
    func setBoundarySpacer(_ length: CGFloat) {
        let rounded = max(0, length.rounded())
        guard rounded != boundarySpacer else { return }
        boundarySpacer = rounded
        refold()
    }

    /// Under the agent a `.hidden` icon asks for no bar seat at all —
    /// the slim clamp holds its slot to `anchorSlimLength` inside the
    /// notch-adjacent niche under the island face. A visible style seats
    /// in the open extras run instead, where its natural width has room.
    private var anchorSlim = false

    /// The seat contract: `.hidden` draws nothing and keeps the free
    /// niche under the island; every other style is a real icon and
    /// belongs in the visible extras run — the utility reads this to
    /// decide slimming and whether a face-covered anchor needs reseating.
    var anchorWantsVisibleSeat: Bool { iconStyle != .hidden }
    nonisolated static let anchorSlimLength: CGFloat = 28

    func setAnchorSlim(_ slim: Bool) {
        guard slim != anchorSlim else { return }
        anchorSlim = slim
        refold()
        if slim { statusItem.length = Self.anchorSlimLength }
    }

    /// Every slot-width write goes through here so the slim clamp is
    /// impossible to bypass.
    private func applyItemLength(_ length: CGFloat) {
        statusItem.length = anchorSlim ? Self.anchorSlimLength : length
    }

    /// The face the button wears: the natural image, or — with a spacer
    /// out — a wider template composite with the icon at its right end
    /// and a ‹ mark in the spacer's last points. The spacer is always
    /// at least the affordance floor while the Menu Bar utility is on,
    /// so the mark is the standing "drag items behind here" sign —
    /// a blank stretch nobody can see was no affordance.
    private func refold() {
        guard let button = statusItem.button, let source = naturalImage else { return }
        let chevron = boundarySpacer > 0
        if boundarySpacer <= 0 {
            if button.image !== source { button.image = source }
            button.imageScaling = .scaleProportionallyDown
            if currentWidth > 0, statusItem.length != currentWidth { applyItemLength(currentWidth) }
            return
        }
        // A template strip tints itself; a coloured strip (the session
        // dots) does not, so the hint takes the bar's own label colour
        // resolved under the button's appearance — black on a dark bar
        // is no hint at all.
        let appearance = button.effectiveAppearance
        var tint = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            tint = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let folded: NSImage
        if let cache = foldedCache, cache.source === source, cache.spacer == boundarySpacer,
           cache.chevron == chevron, cache.appearance == appearance.name.rawValue {
            folded = cache.image
        } else {
            folded = Self.folded(source, spacer: boundarySpacer, chevron: chevron,
                                 hintTint: source.isTemplate ? nil : tint)
            foldedCache = (source, boundarySpacer, chevron, appearance.name.rawValue, folded)
        }
        if button.image !== folded { button.image = folded }
        button.imageScaling = .scaleNone
        let width = (currentWidth > 0 ? currentWidth : naturalWidth) + boundarySpacer
        if statusItem.length != width { applyItemLength(width) }
    }

    /// The composite: `spacer` points of nothing, then the icon, drawn
    /// as a template so the bar tints it. The chevron sits in the last
    /// points of the spacer — a whisper that the blank stretch holds
    /// something. Pure over its inputs; a test pins the size.
    nonisolated static func folded(_ source: NSImage, spacer: CGFloat, chevron: Bool,
                                   hintTint: NSColor? = nil) -> NSImage {
        let iconSize = source.size
        let size = NSSize(width: iconSize.width + spacer, height: max(iconSize.height, 18))
        let mark = chevron
            ? NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            : nil
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - iconSize.height) / 2
            source.draw(in: NSRect(x: spacer, y: y, width: iconSize.width, height: iconSize.height))
            if let mark, spacer >= 20 {
                let m = mark.size
                let rect = NSRect(x: spacer - m.width - 6, y: (size.height - m.height) / 2,
                                  width: m.width, height: m.height)
                mark.draw(in: rect)
                // A symbol drawn into a non-template composite lands
                // black; the tint makes it the bar's label colour.
                if let hintTint {
                    hintTint.withAlphaComponent(0.7).setFill()
                    rect.fill(using: .sourceAtop)
                }
            }
            return true
        }
        image.isTemplate = source.isTemplate
        return image
    }

    /// Whether a click's location falls in the blank part of the item —
    /// the Menu Bar utility's reveal — rather than on the icon.
    nonisolated static func clickIsOnSpacer(x: CGFloat, spacer: CGFloat) -> Bool {
        spacer > 0 && x < spacer
    }

    private func syncTooltip() {
        guard let button = statusItem.button else { return }
        var tip = stateSummary
        if hiddenCount > 0 {
            tip += " · \(hiddenCount) menu bar item\(hiddenCount == 1 ? "" : "s") tucked away to the left — hover or click the blank stretch to reveal"
        }
        button.toolTip = tip
    }

    func setPanelOpen(_ open: Bool) {
        statusItem.button?.highlight(open)
    }

    func update(state: AgentAggregateState, detail: String) {
        headerItem.attributedTitle = NSAttributedString(string: "JR-Bar · \(state.label)", attributes: [
            .font: NSFont.menuBarFont(ofSize: 0).withWeight(.semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        detailItem.attributedTitle = NSAttributedString(string: detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        aggregateTint = state.tint
        stateSummary = "JR-Bar · \(state.label)" + (detail.isEmpty ? "" : " · \(detail)")
        syncTooltip()
        redraw()
    }

    /// "JR-Bar · Working · 2 working · 1 needs you", the tooltip's first half.
    private var stateSummary = "JR-Bar"

    /// The redraw decision for a state, without the button: which spec the
    /// renderer draws, which label the button shows, whether a strip owns
    /// the item's width. The same rules `redraw` applies — a failure keeps
    /// its red through the escalation pulse, a strip carries no whole-item
    /// tint, the label style alone shows a title.
    nonisolated static func plan(style: StatusIconStyle, ringFraction: Double? = nil, tint: NSColor? = nil,
                     isPulsing: Bool = false, meters: [StatusMeter] = [], meterOverflow: Int = 0,
                     dotState: StatusDotState = .idle, sessionDots: [SessionDot] = [],
                     labelText: String? = nil, phase: Double = 0) -> StatusItemPlan {
        // The ring tracks the leading provider — the same provider the
        // first meter meters whenever it reports a window — and that
        // provider's meter now leads with its MOST-EXHAUSTED window, not
        // the 5h one. The ring takes the same figure so a weekly lane at
        // 100 % cannot leave a calm 5 h ring on the bar; when the leading
        // provider reports no window at all, the first metered provider's
        // constraint still fills the ring rather than drawing nothing.
        var ring = ringFraction
        if style == .glyphRing || style == .orbit, let lead = meters.first?.fraction {
            ring = max(ring ?? lead, lead)
        }
        let spec = StatusIconSpec(style: style,
                                  ringFraction: style == .glyphRing || style == .orbit ? ring : nil,
                                  tintHex: tint?.statusHex,
                                  // The compact readout meters the tightest
                                  // window off the same list the columns
                                  // draw; it just renders none of them.
                                  meters: style.isMeters || style == .compactPercent ? meters : [],
                                  overflow: style.isMeters ? meterOverflow : 0,
                                  // A failure keeps its red even while the
                                  // stage-2 escalation is pulsing: repainting
                                  // a dead session's dot amber made it read
                                  // as a live ask.
                                  dot: style.isMeters ? (dotState == .error ? .error : (isPulsing ? .ask : dotState)) : .idle,
                                  sessions: style == .agents || style == .orbit ? sessionDots : [],
                                  phase: phase)
        // `hidden` is a strip too: the spec's own width owns the item,
        // which is how the invisible slot stays a thin 8 pt instead of
        // the square styles' 22.
        let strip = style.isMeters || style == .agents || style == .orbit
            || style == .compactPercent || style == .hidden
        return StatusItemPlan(spec: spec,
                              label: style == .glyphLabel ? labelText : nil,
                              // The meter strip and the session strip size
                              // themselves -- agents included while empty,
                              // or the last session ending never shrank the
                              // item back (size(for:) already answers the
                              // square for that spec).
                              stripWidth: strip ? StatusIconRenderer.size(for: spec).width : nil)
    }

    /// Redraws only when the spec or the label actually changed; the
    /// renderer hands back the cached image for a repeated spec.
    private func redraw() {
        guard let button = statusItem.button else { return }
        let tint: NSColor? = isPulsing ? .systemOrange : aggregateTint
        let plan = Self.plan(style: iconStyle, ringFraction: ringFraction, tint: tint, isPulsing: isPulsing,
                             meters: meters, meterOverflow: meterOverflow, dotState: dotState,
                             sessionDots: sessionDots, labelText: labelText, phase: phase)
        let spec = plan.spec
        let strip = plan.isStrip
        let label = plan.label
        if spec != currentSpec {
            currentSpec = spec
            let image = renderer.image(for: spec)
            naturalImage = image
            naturalWidth = plan.stripWidth ?? StatusIconRenderer.size(for: spec).width
            if boundarySpacer <= 0, button.image !== image { button.image = image }
            // A template image takes the tint from the button; a coloured
            // one carries its own. A strip is never tinted whole:
            // its dots and meters carry the only colour that means anything.
            button.contentTintColor = image.isTemplate && !strip ? tint : nil
            if let width = plan.stripWidth {
                if width != currentWidth {
                    currentWidth = width
                    if boundarySpacer <= 0 { applyItemLength(width) }
                    logFrame(width: width)
                }
            } else {
                currentWidth = 0
            }
            if boundarySpacer > 0 { refold() }
        }
        if strip {
            var tip = StatusIconRenderer.tooltip(spec, headline: stateSummary,
                                                 sessionLines: iconStyle == .agents ? sessionLines : [])
            if hiddenCount > 0 {
                tip += "\n\(hiddenCount) menu bar item\(hiddenCount == 1 ? "" : "s") tucked away to the left — hover or click the blank stretch to reveal"
            }
            button.toolTip = tip
            button.setAccessibilityLabel(StatusIconRenderer.accessibilityLabel(spec))
        }
        if label != currentLabel || (strip && button.imagePosition != .imageOnly) {
            currentLabel = label
            if let label {
                button.attributedTitle = NSAttributedString(string: label, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                applyItemLength(NSStatusItem.variableLength)
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
                // A strip sets its own width above; the square styles are
                // square — unless the boundary spacer owns the width.
                if !strip, boundarySpacer <= 0 { applyItemLength(NSStatusItem.squareLength) }
            }
        }
    }

    /// Every width change prints where the item is, the way the panel
    /// prints its frame: `screencapture -R` can then crop exactly the
    /// status item, which is the only way to photograph it on a menu bar
    /// that collapses its extras.
    private func logFrame(width: CGFloat) {
        guard let rect = anchorRect, let screen = NSScreen.screens.first else { return }
        let top = screen.frame.maxY - rect.maxY
        print(String(format: "status item: %@ %d meters (+%d) %d sessions dot=%@ x=%.0f y=%.0f w=%.0f h=%.0f top=%.0f (screencapture -R%.0f,%.0f,%.0f,%.0f)",
                     iconStyle.rawValue, meters.count, meterOverflow, sessionDots.count, dotState.rawValue,
                     rect.minX, rect.minY, width, rect.height, top, rect.minX, top, width, rect.height))
    }

    /// The 2 Hz clock behind the breathing dots: it runs only while a dot
    /// actually moves (a working or open-ask dot in the meter styles, an
    /// ask or failure in the session strip), so a quiet menu bar costs
    /// nothing. Reduce Motion holds the dot at its brightest instead of
    /// breathing.
    private func syncBreathing() {
        let moving = (iconStyle.isMeters && dotState.animates)
            || (iconStyle == .agents && sessionDots.contains { $0.state.breathes && !$0.dimmed })
        let wanted = moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wanted, breathing == nil {
            phase = 0.5
            let timer = Timer(timeInterval: Self.breathingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.phase = (self.phase + 0.25).truncatingRemainder(dividingBy: 1)
                    self.redraw()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            breathing = timer
        } else if !wanted, breathing != nil {
            breathing?.invalidate()
            breathing = nil
            phase = 0.5
        }
    }

    /// Stage-2 escalation: the icon breathes amber until the ask resolves.
    /// With Reduce Motion the icon holds amber without animating.
    func setEscalationPulse(_ on: Bool) {
        guard on != isPulsing else { return }
        isPulsing = on
        applyPulseAnimation()
        redraw()
    }

    /// While an unanswered ask is escalating, the menu names what is
    /// happening — a pulsing icon or a recurring chime is otherwise a
    /// mystery with no off switch in sight.
    func setEscalation(stage: Int, asksOpen: Bool) {
        setEscalationPulse(stage >= 2 && asksOpen)
        let active = stage >= 2 && asksOpen
        escalationItem.isHidden = !active
        guard active else { return }
        let what = stage >= 3 ? "Chime" : "Menu bar"
        escalationItem.attributedTitle = NSAttributedString(
            string: "Escalating: \(what.lowercased()) — an ask is unanswered", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.systemOrange,
            ])
    }

    /// The whole-item fade is for the glyph styles, which have nowhere else
    /// to put the escalation. In the strips a dot is already pulsing amber,
    /// and fading the strip on top of that only makes it unreadable — so
    /// the layer animation is left off there.
    private func applyPulseAnimation() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.pulseKey)
        let dotsPulse = iconStyle == .agents && !sessionDots.isEmpty
        if isPulsing, !iconStyle.isMeters, !dotsPulse,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(pulse, forKey: Self.pulseKey)
        }
        button.layer?.opacity = 1
    }

    func setFeed(description: String) {
        feedItem.attributedTitle = NSAttributedString(string: "Lights: \(description)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    func setCore(description: String) {
        coreItem.attributedTitle = NSAttributedString(string: "Monitor: \(description)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    /// Snooze is a right-click gesture on a row, so its only reminder lives
    /// here: while any family is snoozed the menu says how many and offers
    /// the lift-all. Hidden at zero — a quiet menu is the default.
    func setSnoozed(_ count: Int) {
        snoozedItem.isHidden = count <= 0
        guard count > 0 else { return }
        let noun = count == 1 ? "1 session snoozed" : "\(count) sessions snoozed"
        snoozedItem.attributedTitle = NSAttributedString(string: "\(noun) — unsnooze all", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        // A click on the blank stretch left of the icon is the Menu Bar
        // utility's reveal, whichever button.
        if let event, let button = statusItem.button, boundarySpacer > 0 {
            let x = button.convert(event.locationInWindow, from: nil).x
            MenuBarCombinedItem.log.notice("status click: x=\(x, privacy: .public) spacer=\(self.boundarySpacer, privacy: .public) win=\(event.locationInWindow.x, privacy: .public) type=\(event.type.rawValue, privacy: .public)")
            if Self.clickIsOnSpacer(x: x, spacer: boundarySpacer) {
                onBoundaryClick?()
                return
            }
        }
        if secondary {
            if let submenu = hiddenItemsMenu?() {
                hiddenItemsMenuItem.submenu = submenu
                hiddenItemsMenuItem.isHidden = false
            } else {
                hiddenItemsMenuItem.submenu = nil
                hiddenItemsMenuItem.isHidden = true
            }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onTogglePanel?()
        }
    }

    @objc private func openPanel(_ sender: Any?) {
        onTogglePanel?()
    }

    @objc private func unsnoozeAll(_ sender: Any?) {
        onUnsnoozeAll?()
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    @objc private func openHistory(_ sender: Any?) {
        onOpenHistory?()
    }

    @objc private func openOverview(_ sender: Any?) {
        onOpenOverview?()
    }

    @objc private func openReplay(_ sender: Any?) {
        onOpenReplay?()
    }

    @objc private func openUsageCenter(_ sender: Any?) {
        onOpenUsageCenter?()
    }

    @objc private func openEffects(_ sender: Any?) {
        onOpenEffects?()
    }

    @objc private func openControlCenter(_ sender: Any?) {
        onOpenControlCenter?()
    }

    @objc private func toggleScreenBar(_ sender: NSMenuItem) {
        isScreenBarShown.toggle()
        onToggleScreenBar?(isScreenBarShown)
    }

    /// The plain glyph, for places that draw the app's mark inline.
    static func glyph() -> NSImage {
        StatusIconRenderer.shared.image(for: StatusIconSpec(style: .glyph))
    }

    /// Writes every style at 8× into `directory` (a menu-bar mock-up: dark
    /// bar, the icon, the label beside it where the style has one).
    /// `live` is the item's own meters when the core has answered, so a
    /// design review is of the reader's real providers rather than of a
    /// sample nobody has; empty falls back to the sample.
    static func renderStyles(to directory: String, live: [StatusMeter] = [], liveDots: [SessionDot] = []) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let scale: CGFloat = 8
        let sample = live.isEmpty ? StatusItemController.sampleMeters : live
        let dots = liveDots.isEmpty ? StatusItemController.sampleSessionDots : liveDots
        let manyDots = dots + [
            SessionDot(id: "extra-1", state: .working, accentHex: "#34C759"),
            SessionDot(id: "extra-2", state: .idle),
            SessionDot(id: "extra-3", state: .done),
        ]
        let samples: [(String, StatusIconSpec, String?)] = [
            ("agents", StatusIconSpec(style: .agents, sessions: dots, phase: 0.4), nil),
            ("agents_empty", StatusIconSpec(style: .agents), nil),
            ("agents_overflow", StatusIconSpec(style: .agents, sessions: manyDots, phase: 0.4), nil),
            ("meters_idle", StatusIconSpec(style: .meters, meters: sample, dot: .idle), nil),
            ("meters_working", StatusIconSpec(style: .meters, tintHex: "#00E5FF", meters: sample, dot: .working, phase: 0.5), nil),
            ("meters_ask", StatusIconSpec(style: .meters, meters: sample, dot: .ask, phase: 0.4), nil),
            ("meters_error", StatusIconSpec(style: .meters, meters: sample, dot: .error, phase: 0.2), nil),
            ("meters_done", StatusIconSpec(style: .meters, meters: sample, dot: .done), nil),
            ("meters_overflow", StatusIconSpec(style: .meters, meters: sample, overflow: 2, dot: .working, phase: 0.5), nil),
            ("meters_percent", StatusIconSpec(style: .metersPercent, meters: sample, dot: .working, phase: 0.5), nil),
            ("compact_percent", StatusIconSpec(style: .compactPercent, meters: sample), nil),
            ("glyph", StatusIconSpec(style: .glyph), nil),
            ("glyph_working", StatusIconSpec(style: .glyph, tintHex: "#00E5FF"), nil),
            ("glyph_ring_42", StatusIconSpec(style: .glyphRing, ringFraction: 0.42), nil),
            ("glyph_ring_85", StatusIconSpec(style: .glyphRing, ringFraction: 0.85), nil),
            ("glyph_ring_97", StatusIconSpec(style: .glyphRing, ringFraction: 0.97), nil),
            ("glyph_label", StatusIconSpec(style: .glyphLabel), StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0)),
        ]
        for (name, spec, label) in samples {
            let image = StatusIconRenderer.shared.image(for: spec)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let textWidth = label.map { ($0 as NSString).size(withAttributes: attributes).width + 6 * scale } ?? 0
            let iconSize = StatusIconRenderer.size(for: spec)
            let size = NSSize(width: (iconSize.width + 8) * scale + textWidth, height: 24 * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let tinted: NSImage
            if image.isTemplate, let tint = spec.tintHex.flatMap({ NSColor(hex: $0) }) ?? Optional(NSColor.white) {
                tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    tint.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
            } else {
                tinted = image
            }
            tinted.draw(in: NSRect(x: 4 * scale, y: (24 - iconSize.height) / 2 * scale,
                                   width: iconSize.width * scale, height: iconSize.height * scale))
            if let label {
                (label as NSString).draw(at: NSPoint(x: 26 * scale, y: 5.5 * scale), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }

    /// Four believable providers for the icon previews and the Settings
    /// picker, used whenever the daemon has nothing to meter yet.
    static var sampleMeters: [StatusMeter] {
        [
            StatusMeter(id: "claude", name: "Claude", glyph: .symbol("asterisk"), fraction: 0.16),
            StatusMeter(id: "codex", name: "Codex", glyph: .symbol("chevron.left.forwardslash.chevron.right"), fraction: 0.83),
            StatusMeter(id: "gemini", name: "Gemini", glyph: .symbol("sparkle"), fraction: 0.97),
            StatusMeter(id: "devin", name: "Devin", glyph: .symbol("hammer.fill"), fraction: 0.41, approximate: true),
        ]
    }

    /// Five believable sessions for the `agents` previews, in the panel's
    /// order (asks first, done last), used whenever the daemon has none.
    static var sampleSessionDots: [SessionDot] {
        [
            SessionDot(id: "s-ask", state: .ask),
            SessionDot(id: "s-claude", state: .working, accentHex: "#D97757"),
            SessionDot(id: "s-codex", state: .working, accentHex: "#2B8FFF"),
            SessionDot(id: "s-done", state: .done),
            SessionDot(id: "s-idle", state: .idle),
        ]
    }

    /// A provider's panel style as a menu-bar meter. `fraction` is nil
    /// when the provider reports its primary window without a number; the
    /// strip marks that column as unread. `document` carries the
    /// configured `colors.agent_colors.<id>` accent, when one validates.
    /// `resetsAt`/`verdict` feed the percent styles' countdown swap and
    /// the compact style's pace tint.
    static func meter(for provider: String, fraction: Double?, approximate: Bool,
                      document: SettingsDocument? = nil,
                      resetsAt: Double? = nil, verdict: UsageForecast.Verdict? = nil) -> StatusMeter {
        let style = ProviderStyle.style(for: provider, document: document)
        let glyph: StatusMeter.Glyph
        switch style.glyph {
        case .symbol(let name): glyph = .symbol(name)
        case .text(let text): glyph = .text(text)
        }
        return StatusMeter(id: style.id, name: style.name, glyph: glyph, fraction: fraction,
                           approximate: approximate,
                           accentHex: document?.agentColorHex(provider),
                           resetsAt: resetsAt, paceVerdict: paceVerdict(for: verdict))
    }

    /// The app-side verdict collapsed onto the meter's tint vocabulary.
    static func paceVerdict(for verdict: UsageForecast.Verdict?) -> StatusMeter.PaceVerdict {
        switch verdict {
        case .exhausted: return .exhausted
        case .runsOut: return .runsOut
        case .comfortable: return .comfortable
        case .guarded: return .guarded
        case .unknown, .unmeasured, nil: return .unknown
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
