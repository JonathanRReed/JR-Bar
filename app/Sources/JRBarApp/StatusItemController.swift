import AppKit
import JRBarCore
import JRBarUI
import OSLog
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
///
/// Under the macOS 27 concealer macOS draws none of this — it will not
/// draw the asserting identity's own item — so the utility's
/// `MenuBarIconMirror` carries the icon instead: this item goes slim
/// and blank (`setFaceMirrored`), pushes its face to the mirror, and
/// anchors the panel on the mirror's frame.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, MenuBarBoundaryHost {
    /// The `AXIdentifier` JR-Bar's own status item carries.
    nonisolated static let accessibilityIdentifier = "com.jonathanreed.jrbar.status-item"
    /// The one autosave name the item registers under — the key macOS
    /// files the person's ⌘-drag placement under.
    nonisolated static let autosaveName = "com.jonathanreed.jrbar.status-item"
    private static let log = Logger(subsystem: "devin.jrbar", category: "status-item")

    private let statusItem: NSStatusItem
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
    /// What the button wears when it is the icon — the natural image, or
    /// the folded composite with a spacer out. `dressButton` decides
    /// whether it actually goes on.
    private var wornImage: NSImage?
    /// Whether the panel is open — the button's highlight, and the
    /// mirror's.
    private var panelOpen = false
    /// Whether the mirror's menu is up: a status item highlights while
    /// its menu is open, and the button does that for itself.
    private var mirrorMenuOpen = false
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
    /// The catalog's Creator Micro row, shown once a pad has been seen.
    private var creatorMicroItem: NSMenuItem?
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
    /// The ⇧⌘K palette.
    var onOpenPalette: (@MainActor () -> Void)?
    /// What's New, through the same route `jrbar://window/whats-new` takes.
    var onOpenWhatsNew: (@MainActor () -> Void)? = { AppCommandRouter.shared.perform(.window(.whatsNew)) }
    /// Sparkle's check, through the delegate.
    var onCheckForUpdates: (@MainActor () -> Void)?
    /// Whether a Creator Micro has been seen, read as the menu opens:
    /// its item is listed only then (`PanelStore.hasCreatorMicro`).
    var showsCreatorMicro: (@MainActor () -> Bool)?
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
    /// The breathing clock: two frames a second, only while the dot moves.
    private static let breathingInterval: TimeInterval = 0.5
    private var breathing: Timer?
    private var phase: Double = 0
    /// A strip's own width as the plan last gave it; 0 for the square
    /// and label styles. `syncLength` writes the item's length only when
    /// it changes, so a same-width redraw never churns the bar's layout.
    private var currentWidth: CGFloat = 0

    override init() {
        Self.seedPreferredPosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        showBarItem = NSMenuItem(title: "Show Screen Bar", action: #selector(toggleScreenBar(_:)), keyEquivalent: "")
        super.init()
        wireStatusItem()
        wornImage = renderer.image(for: StatusIconSpec(style: .agents))
        dressButton()

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

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(coreItem)
        menu.addItem(feedItem)
        menu.addItem(snoozedItem)
        menu.addItem(escalationItem)
        // The verbs come from the catalog the panel's More menu shares;
        // the item's own rows — Open Panel, Show Screen Bar, the hidden
        // items — sit among them.
        let sections = AppMenuCatalog.sections(creatorMicro: true)
        for (index, verbs) in sections.enumerated() {
            menu.addItem(.separator())
            for verb in verbs {
                let item = verb.menuItem(action: #selector(performVerb(_:)), target: self)
                if verb == .creatorMicro {
                    item.isHidden = true
                    creatorMicroItem = item
                }
                menu.addItem(item)
            }
            if index == 0 {
                let open = NSMenuItem(title: "Open Panel", action: #selector(openPanel(_:)), keyEquivalent: "")
                open.target = self
                menu.addItem(open)
            }
            if index == 1 {
                menu.addItem(showBarItem)
                hiddenItemsMenuItem.isHidden = true
                menu.addItem(hiddenItemsMenuItem)
            }
        }
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

    /// The `NSStatusItem Preferred Position` record macOS files the
    /// item's slot under. It is a sort key, not a measure — larger sorts
    /// further left (measured 2026-09-22: 300 → x 1062, 420 → 916, 440
    /// and up → the leftmost slot under the notch). It only decides
    /// anything while the item itself is the icon: the concealer off,
    /// another provider, the spacer engine. Under the concealer the
    /// mirror carries the face wherever macOS puts the item.
    nonisolated static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Marks the one-time sweep of the records the retired seat walk
    /// left: it overwrote the primary record at every step and
    /// registered `-rN` generations, none of them a placement the person
    /// chose.
    nonisolated static let seatMigrationKey = "jrbar.statusItemSeat.v2"

    /// Seeds the record before the item registers — best effort, since
    /// macOS offers no placement API. Once, the walk's records go; then,
    /// only while no record exists, a key that sorts just left of
    /// Wi-Fi's is written. A record that exists is the person's ⌘-drag
    /// and is never overwritten. The key is a hint, not a seat: with key
    /// 250 a signed probe landed flush left of Wi-Fi but JR-Bar at the
    /// leftmost visible slot (x 975, measured 2026-09-22), so nothing
    /// should rely on where the real item lands.
    ///
    /// The write is synchronised before returning: `UserDefaults.set`
    /// only updates the in-memory cache, and an item registered in the
    /// same run-loop turn reads cfprefsd before the seed lands there
    /// (measured 2026-09-21).
    static func seedPreferredPosition(defaults: UserDefaults = .standard,
                                      wifi: () -> Double? = wifiPreferredPosition) {
        var wrote = false
        if !defaults.bool(forKey: seatMigrationKey) {
            for key in defaults.dictionaryRepresentation().keys
                where key == preferredPositionKey || key.hasPrefix(preferredPositionKey + "-r") {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: seatMigrationKey)
            wrote = true
        }
        if defaults.object(forKey: preferredPositionKey) == nil {
            defaults.set(rightSideSeedKey(wifi: wifi()), forKey: preferredPositionKey)
            wrote = true
        }
        if wrote { defaults.synchronize() }
    }

    /// The fresh seed: just left of Wi-Fi when Control Center keeps a
    /// record for it (a slightly larger key sorts just left of it), else
    /// a key that sorts into the right-hand run of a typical bar.
    nonisolated static func rightSideSeedKey(wifi: Double?) -> Double {
        wifi.map { $0 + 4 } ?? 250
    }

    /// Control Center's own record for Wi-Fi — the right-hand run's
    /// anchor. nil when it has none.
    nonisolated static func wifiPreferredPosition() -> Double? {
        let value = CFPreferencesCopyAppValue("NSStatusItem Preferred Position WiFi" as CFString,
                                              "com.apple.controlcenter" as CFString)
        return (value as? NSNumber)?.doubleValue
    }

    /// The identity and wiring the item needs — autosave name, AX
    /// identifier, button target/action, the appearance watch.
    private func wireStatusItem() {
        // Where the item sits is the person's to choose (Command-drag);
        // macOS gives no API to ask for a slot. A stable autosave name is
        // the one thing the app can do: it is the key macOS remembers that
        // choice under, so a rebuild does not send the item back to the
        // middle of a busy menu bar.
        statusItem.autosaveName = Self.autosaveName
        // The Menu Bar utility finds this item in the AX listing by the
        // identifier.
        statusItem.button?.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "JR-Bar"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The bar's appearance follows the wallpaper under it; the
            // mirror resolves its template glyph against the same one.
            appearanceWatch = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onFaceChange?() }
            }
        }
    }

    /// Where the icon is on screen, for anchoring the panel: the
    /// mirror's face while it carries the icon, else the button. The
    /// panel's click-through test reads the same rect, so a second click
    /// on the visible icon closes the panel rather than closing and
    /// reopening it.
    var anchorRect: NSRect? {
        if faceMirrored, let mirroredFaceFrame { return mirroredFaceFrame }
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: MenuBarBoundaryHost

    /// The icon's frame in Quartz coordinates (top-left origin), the
    /// space the Menu Bar utility measures in — the mirror's face while
    /// it carries the icon.
    var boundaryFrame: CGRect? {
        guard let rect = anchorRect else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

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

    /// Every style but `.hidden` draws an icon — only a drawn icon is
    /// worth a mirror under the concealer.
    var anchorWantsVisibleSeat: Bool { iconStyle != .hidden }
    /// The slot the item keeps while the mirror carries its face.
    nonisolated static let anchorSlimLength: CGFloat = 28

    /// Whether the concealer's mirror carries the icon. While it does
    /// the button wears nothing and keeps the slim slot: under the
    /// assertion macOS draws no pixels of ours anyway, and a lift of it
    /// (a bridged clock or Wi-Fi click, 0.45 s) would otherwise flash a
    /// second icon wherever macOS keeps the real item.
    private(set) var faceMirrored = false
    /// The mirror's face frame in AppKit screen coordinates — written by
    /// the utility on every move, nil while the mirror is down.
    var mirroredFaceFrame: NSRect?
    /// Fires whenever `face` changes — the mirror's feed.
    var onFaceChange: (@MainActor () -> Void)?
    private var appearanceWatch: NSKeyValueObservation?

    /// Hand the icon to the mirror or take it back — the one owner of
    /// the slim clamp and of the blank face.
    func setFaceMirrored(_ mirrored: Bool) {
        guard mirrored != faceMirrored else { return }
        faceMirrored = mirrored
        if !mirrored { mirroredFaceFrame = nil }
        dressButton()
        syncLength()
    }

    /// What the icon wears, for the mirror — built from the model, never
    /// read off the button's pixels, which are blank while mirrored.
    var face: MenuBarIconFace {
        let button = statusItem.button
        return MenuBarIconFace(
            image: naturalImage ?? wornImage,
            tint: button?.contentTintColor,
            title: currentLabel.map(Self.labelTitle),
            length: currentWidth > 0 ? currentWidth
                : (currentLabel == nil ? NSStatusBar.system.thickness : 0),
            highlighted: panelOpen || mirrorMenuOpen,
            pulsing: pulseDrawsOnLayer,
            toolTip: button?.toolTip,
            accessibilityLabel: button?.accessibilityLabel(),
            appearance: button?.effectiveAppearance,
            hiddenCount: hiddenCount,
            hiddenRevealed: hiddenRevealed)
    }

    /// The mirror's ordinary click — the button's left click.
    func faceClicked() {
        onTogglePanel?()
    }

    /// The mirror's right/Option click: the item's full menu, Hidden
    /// Items prepared as the button's own secondary click prepares it,
    /// dropped from the bar's bottom edge at the face's left — where a
    /// status item's menu opens.
    func popUpMenu(in view: NSView) {
        guard let window = view.window else { return }
        prepareMenu()
        let face = window.convertToScreen(view.convert(view.bounds, to: nil))
        let barBottom = (window.screen ?? NSScreen.screens.first)?.visibleFrame.maxY ?? face.minY
        // `popUp` tracks the menu until it closes — the face highlights
        // for exactly that long.
        mirrorMenuOpen = true
        onFaceChange?()
        menu.popUp(positioning: nil, at: NSPoint(x: face.minX, y: min(face.minY, barBottom)), in: nil)
        mirrorMenuOpen = false
        onFaceChange?()
    }

    /// The one place the button's pixels are written — image and label
    /// alike — so the blank face while mirrored cannot be bypassed.
    private func dressButton() {
        guard let button = statusItem.button else { return }
        let worn = Self.worn(image: wornImage, label: currentLabel, mirrored: faceMirrored)
        if button.image !== worn.image { button.image = worn.image }
        if let label = worn.label {
            if button.attributedTitle.string != label || button.imagePosition != .imageLeading {
                button.attributedTitle = Self.labelTitle(label)
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
        } else if !button.title.isEmpty || button.imagePosition != .imageOnly {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// What the button wears: nothing while the mirror carries the
    /// face, its own image and label otherwise. Pure so a test pins the
    /// blank.
    nonisolated static func worn(image: NSImage?, label: String?,
                                 mirrored: Bool) -> (image: NSImage?, label: String?) {
        mirrored ? (nil, nil) : (image, label)
    }

    /// Every slot-width write goes through here, so the slim clamp is
    /// impossible to bypass and every path back from it lands on the
    /// same natural width.
    private func syncLength() {
        let length = Self.itemLength(mirrored: faceMirrored, hasLabel: currentLabel != nil,
                                     spacer: boundarySpacer, stripWidth: currentWidth,
                                     glyphWidth: naturalWidth)
        if statusItem.length != length { statusItem.length = length }
    }

    /// The item's length: the slim slot while mirrored; otherwise a
    /// label's variable length, the folded width with a spacer out, a
    /// strip's own width, or the square.
    static func itemLength(mirrored: Bool, hasLabel: Bool, spacer: CGFloat,
                           stripWidth: CGFloat, glyphWidth: CGFloat) -> CGFloat {
        if mirrored { return anchorSlimLength }
        if hasLabel { return NSStatusItem.variableLength }
        if spacer > 0 { return (stripWidth > 0 ? stripWidth : glyphWidth) + spacer }
        if stripWidth > 0 { return stripWidth }
        return NSStatusItem.squareLength
    }

    /// The label style's title, as the button and the mirror draw it.
    static func labelTitle(_ label: String) -> NSAttributedString {
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
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
            wornImage = source
            button.imageScaling = .scaleProportionallyDown
        } else {
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
            wornImage = folded
            button.imageScaling = .scaleNone
        }
        dressButton()
        syncLength()
        onFaceChange?()
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
        onFaceChange?()
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        statusItem.button?.highlight(open)
        onFaceChange?()
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
            // A template image takes the tint from the button; a coloured
            // one carries its own. A strip is never tinted whole:
            // its dots and meters carry the only colour that means anything.
            button.contentTintColor = image.isTemplate && !strip ? tint : nil
            if let width = plan.stripWidth {
                if width != currentWidth {
                    currentWidth = width
                    logFrame(width: width)
                }
            } else {
                currentWidth = 0
            }
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
        currentLabel = label
        // The fold wears the new image (folded or plain), then the label
        // and the length follow through the same choke points.
        refold()
    }

    /// Every width change logs where the item is, the way the panel
    /// logs its frame: `screencapture -R` can then crop exactly the
    /// status item, which is the only way to photograph it on a menu bar
    /// that collapses its extras.
    private func logFrame(width: CGFloat) {
        guard let rect = anchorRect, let screen = NSScreen.screens.first else { return }
        let top = screen.frame.maxY - rect.maxY
        let line = String(format: "status item: %@ %d meters (+%d) %d sessions dot=%@ x=%.0f y=%.0f w=%.0f h=%.0f top=%.0f (screencapture -R%.0f,%.0f,%.0f,%.0f)",
                          iconStyle.rawValue, meters.count, meterOverflow, sessionDots.count, dotState.rawValue,
                          rect.minX, rect.minY, width, rect.height, top, rect.minX, top, width, rect.height)
        Self.log.debug("\(line, privacy: .public)")
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
        button.layer?.removeAnimation(forKey: MenuBarIconFace.pulseKey)
        if pulseDrawsOnLayer {
            button.layer?.add(MenuBarIconFace.pulseAnimation(), forKey: MenuBarIconFace.pulseKey)
        }
        button.layer?.opacity = 1
        onFaceChange?()
    }

    /// Whether the escalation fades the whole icon — the glyph styles
    /// only, and never under Reduce Motion.
    private var pulseDrawsOnLayer: Bool {
        let dotsPulse = iconStyle == .agents && !sessionDots.isEmpty
        return isPulsing && !iconStyle.isMeters && !dotsPulse
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            Self.log.debug("status click: x=\(x, privacy: .public) spacer=\(self.boundarySpacer, privacy: .public) win=\(event.locationInWindow.x, privacy: .public) type=\(event.type.rawValue, privacy: .public)")
            if Self.clickIsOnSpacer(x: x, spacer: boundarySpacer) {
                onBoundaryClick?()
                return
            }
        }
        if secondary {
            prepareMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onTogglePanel?()
        }
    }

    /// The rows that depend on the moment: the hidden items, and Creator
    /// Micro once a pad has been seen.
    private func prepareMenu() {
        prepareHiddenItemsRow()
        creatorMicroItem?.isHidden = showsCreatorMicro?() != true
    }

    /// The menu's "Hidden Menu Bar Items" row: the utility's submenu
    /// while it runs, gone while it is parked. Both secondary clicks —
    /// the button's and the mirror's — prepare it, through prepareMenu.
    private func prepareHiddenItemsRow() {
        if let submenu = hiddenItemsMenu?() {
            hiddenItemsMenuItem.submenu = submenu
            hiddenItemsMenuItem.isHidden = false
        } else {
            hiddenItemsMenuItem.submenu = nil
            hiddenItemsMenuItem.isHidden = true
        }
    }

    @objc private func openPanel(_ sender: Any?) {
        onTogglePanel?()
    }

    @objc private func unsnoozeAll(_ sender: Any?) {
        onUnsnoozeAll?()
    }

    /// One of the catalog's verbs, named by the item's `representedObject`.
    @objc private func performVerb(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let verb = AppMenuVerb(rawValue: raw) else { return }
        perform(verb)
    }

    func perform(_ verb: AppMenuVerb) {
        switch verb {
        case .commandPalette: onOpenPalette?()
        case .history: onOpenHistory?()
        case .events: onOpenReplay?()
        case .overview: onOpenOverview?()
        case .usageCenter: onOpenUsageCenter?()
        case .effects: onOpenEffects?()
        case .creatorMicro: onOpenControlCenter?()
        case .whatsNew: onOpenWhatsNew?()
        case .checkForUpdates: onCheckForUpdates?()
        case .settings: onOpenSettings?()
        case .quit: NSApp.terminate(nil)
        }
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
