import AppKit
import Carbon
import JRBarCore
import SwiftUI

/// The Screen Bar's right ear as the menu bar's surface: hovering or
/// scrolling on it hangs a black peek from the notch — the hidden apps'
/// photographed glyphs, one click from open — and the ear itself carries
/// the menu bar's marks. The ear never moves with the bar's reflow, so
/// the reveal lands where the eye already goes; no standalone manager
/// has a notch to ask from. The ear draws marks only; the peek is where
/// the words live.

/// What the pointer asked of the peek.
enum ScreenBarPeekIntent: Equatable {
    /// The pointer rests on the ear, or a scroll landed there: hang it
    /// for as long as the pointer stays on the ear or the peek.
    case hover
    /// A click or a pull: hang it until an outside click or Esc.
    case pin
    /// A click on the ear: pin a peek that hangs or is down, fold a
    /// pinned one.
    case toggle
    case close
}

// MARK: - The ear's marks

/// The menu bar's say on the right ear, read off `MenuBarEarFeed`: while
/// items are tucked away and nothing else claims the side, a resting mark
/// of one to three dots holds the ear — the peek's home — so the reveal
/// surface is there whenever there is something to reveal. When hiding
/// stops working the ear says so in the alert tone, and its peek says why.
struct ScreenBarMenuBarMarks: Equatable {
    /// How many hidden items the feed tiles.
    var hiddenCount = 0
    /// Why hiding stopped — the alert mark's VoiceOver words; nil while
    /// the engine is healthy.
    var failure: String?

    /// The alert mark: the menu bar itself, in the failed tone — the
    /// subject, not a generic warning, so it never reads as the band's
    /// refused program.
    static let failureSymbol = "menubar.rectangle"

    init(hiddenCount: Int = 0, failure: String? = nil) {
        self.hiddenCount = hiddenCount
        self.failure = failure
    }

    init(feed: MenuBarEarFeed?) {
        hiddenCount = feed?.hidden.count ?? 0
        failure = feed?.failure
    }

    /// The resting mark's weight: one dot for a few, two for a handful,
    /// three past that — how much, never how many.
    static func dots(hiddenCount: Int) -> Int {
        switch hiddenCount {
        case ..<1: return 0
        case 1...3: return 1
        case 4...8: return 2
        default: return 3
        }
    }

    /// VoiceOver's words for the resting mark.
    static func hiddenWords(_ count: Int) -> String {
        count == 1 ? "1 menu bar item tucked away" : "\(count) menu bar items tucked away"
    }

    /// `wings` with the menu bar's marks on the right ear. A failure
    /// takes the side from whatever ambient mark held it — hiding
    /// stopped, and the person should see that where they look. The
    /// resting dots only fill an empty side: the meter, the media ear
    /// and a device beat all keep it, and their ear still opens the peek.
    static func apply(_ marks: ScreenBarMenuBarMarks, to wings: ScreenBarWings) -> ScreenBarWings {
        var dressed = wings
        if let failure = marks.failure {
            dressed.right = ScreenBarWingSlot(text: failure, symbol: failureSymbol, tone: .alert)
        } else if dressed.right == nil, marks.hiddenCount > 0 {
            dressed.right = ScreenBarWingSlot(text: hiddenWords(marks.hiddenCount),
                                              dots: dots(hiddenCount: marks.hiddenCount))
        }
        return dressed
    }
}

// MARK: - Geometry

/// Where the peek stands and how wide it is — pure, so a test pins it.
/// It hangs below the band, never over it: the light under the notch
/// stays one unbroken strip. Its right edge lines up with the right
/// ear's outer edge, so it reads as that ear's lobe grown down; a wide
/// row grows it toward the notch and past it, never off the screen.
enum ScreenBarPeekLayout {
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    /// A tile's height on the black — the Item Bar's glyph line.
    static let tileHeight: CGFloat = 28
    /// The widest the peek grows; a longer row scrolls.
    static let maxContentWidth: CGFloat = 420
    /// The narrowest a peek with words in it reads well at.
    static let wordsWidth: CGFloat = 250
    /// The narrowest at all — a lone tile still reads as a lobe.
    static let minContentWidth: CGFloat = 44
    /// The air between the band's halo and the peek's top.
    static let gapBelowBand: CGFloat = 4
    static let edgeMargin: CGFloat = 6
    /// The lobe's corners: slight where it hangs, the notch's own
    /// softness where it ends.
    static let topCornerRadius: CGFloat = 6
    static let bottomCornerRadius: CGFloat = 14

    /// The content's width: the tile row's own, or the words' floor when
    /// the peek has sentences to say, capped.
    static func contentWidth(tileWidths: [CGFloat], hasWords: Bool) -> CGFloat {
        let row = tileWidths.isEmpty ? 0 : MenuBarBarLayout.rowWidth(widths: tileWidths)
        return min(maxContentWidth, max(hasWords ? wordsWidth : minContentWidth, row))
    }

    /// The panel's width for that content.
    static func width(tileWidths: [CGFloat], hasWords: Bool) -> CGFloat {
        contentWidth(tileWidths: tileWidths, hasWords: hasWords) + 2 * padding
    }

    /// The peek's frame for a panel of `size`: its top below the band
    /// (or the ear, where no band stands under it), its right edge on
    /// the ear's outer edge, kept inside the screen. AppKit coordinates.
    static func frame(size: CGSize, ear: CGRect, band: CGRect?, screen: CGRect) -> CGRect {
        let top = band.map { min(ear.minY, $0.minY - gapBelowBand) } ?? ear.minY
        let rightmost = screen.maxX - edgeMargin
        let leftmost = screen.minX + edgeMargin
        let x = max(leftmost, min(ear.maxX, rightmost) - size.width)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}

// MARK: - The peek

/// What the peek shows — pushed by the controller from the menu bar's
/// feed, observed by the view.
@MainActor
@Observable
final class ScreenBarPeekModel {
    var tiles: [MenuBarEarFeed.Tile] = []
    /// Why hiding stopped, when it has — the alert mark's reason.
    var failure: String?
    var width: CGFloat = ScreenBarPeekLayout.width(tileWidths: [], hasWords: false)
    /// A glyph was clicked: open that item the Item Bar's way.
    @ObservationIgnored var onOpen: @MainActor (String) -> Void = { _ in }

    /// Whether the peek carries sentences, which set its floor width.
    var hasWords: Bool { failure != nil }
}

/// The peek's face: notch black — the reason hiding stopped, when it
/// has, then the hidden glyphs in a row. Template glyphs are drawn
/// white, as the bar would draw them on a dark wallpaper; a glyph never
/// photographed shows its app's icon.
struct ScreenBarPeekView: View {
    let model: ScreenBarPeekModel

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenBarPeekLayout.spacing) {
            if let failure = model.failure {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ScreenBarMenuBarMarks.failureSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if !model.tiles.isEmpty {
                tileRow
            }
        }
        .padding(ScreenBarPeekLayout.padding)
        .frame(width: model.width, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: ScreenBarPeekLayout.topCornerRadius,
                                   bottomLeadingRadius: ScreenBarPeekLayout.bottomCornerRadius,
                                   bottomTrailingRadius: ScreenBarPeekLayout.bottomCornerRadius,
                                   topTrailingRadius: ScreenBarPeekLayout.topCornerRadius,
                                   style: .continuous)
                .fill(.black))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hidden menu bar items")
    }

    private var tileRow: some View {
        let widths = model.tiles.map(\.width)
        let content = ScreenBarPeekLayout.contentWidth(tileWidths: widths, hasWords: model.hasWords)
        return ScrollView(.horizontal) {
            HStack(spacing: MenuBarBarLayout.tileGap) {
                ForEach(model.tiles) { tile in
                    ScreenBarPeekTile(tile: tile) { model.onOpen(tile.id) }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: content, height: ScreenBarPeekLayout.tileHeight, alignment: .leading)
    }
}

/// One glyph in the peek: its face, a light wash under the pointer, the
/// change dot the Item Bar draws too.
struct ScreenBarPeekTile: View {
    let tile: MenuBarEarFeed.Tile
    let open: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: open) {
            face
                .frame(width: tile.width, height: ScreenBarPeekLayout.tileHeight)
                .background {
                    if hovered {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.14))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if tile.changed {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tile.name + " — click to open")
        .accessibilityLabel(tile.name)
        .accessibilityHint("Opens its menu")
    }

    @ViewBuilder
    private var face: some View {
        if let glyph = tile.face {
            Image(nsImage: glyph.image)
                .renderingMode(glyph.template ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white.opacity(0.92))
                .frame(height: 20)
        } else {
            Image(nsImage: tile.item.owner?.icon
                  ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
                  ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        }
    }
}

/// The peek's window: borderless and nonactivating, at the band's own
/// level so it hangs in the same layer as the ear it grows from. Unlike
/// the band it takes clicks — the glyphs are buttons — but it never
/// becomes key, so the front app keeps its focus.
@MainActor
final class ScreenBarPeekPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        title = "JR-Bar Screen Bar Peek"
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        // Fold's warp captures the desktop — the peek is not in it, the
        // same exclusion the Item Bar and the notch card claim.
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps ordinary windows below the menu bar; this one hangs
    /// from it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Where the peek hangs, in screen coordinates: the right ear it grows
/// from, the band it keeps clear of, the screen it stays on.
struct ScreenBarPeekAnchor: Equatable {
    var ear: CGRect
    var band: CGRect?
    var screen: CGRect
}

/// Owns the peek's panel: shows it (a hover's, or a pinned one), fits it
/// to its content, hangs it under the ear, and folds it. Built lazily —
/// a bar that is never peeked at never pays for a SwiftUI tree.
@MainActor
final class ScreenBarPeek {
    let model = ScreenBarPeekModel()
    /// Where it hangs now; nil when the ear is gone.
    var anchor: @MainActor () -> ScreenBarPeekAnchor? = { nil }
    private(set) var isShown = false
    private(set) var isPinned = false
    private var panel: ScreenBarPeekPanel?
    private var hosting: NSHostingView<ScreenBarPeekView>?
    private var keyMonitors: [Any] = []

    /// The panel's frame while it hangs.
    var frame: NSRect? { isShown ? panel?.frame : nil }

    /// The peek eases in and out like the band (0.18 s); Reduce Motion
    /// keeps the instant swap.
    private static let fadeSeconds: TimeInterval = 0.18
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(pinned: Bool) {
        guard anchor() != nil else { return }
        let panel = self.panel ?? makePanel()
        if pinned, !isPinned { installKeyMonitors() }
        isPinned = isPinned || pinned
        guard !isShown else { relayout(); return }
        isShown = true
        relayout()
        if Self.reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        removeKeyMonitors()
        isPinned = false
        guard isShown, let panel else { isShown = false; return }
        isShown = false
        if Self.reduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel?.orderOut(nil)
                }
            })
        }
    }

    /// Fit the panel to its content and hang it under the ear — after a
    /// content change or a move of the ear. A peek whose ear went away
    /// folds.
    func relayout() {
        guard isShown, let panel, let hosting else { return }
        guard let anchor = anchor() else { hide(); return }
        let size = hosting.fittingSize
        let frame = ScreenBarPeekLayout.frame(size: CGSize(width: model.width, height: size.height),
                                              ear: anchor.ear, band: anchor.band, screen: anchor.screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> ScreenBarPeekPanel {
        let panel = ScreenBarPeekPanel()
        let hosting = NSHostingView(rootView: ScreenBarPeekView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// A pinned peek folds on Esc, whichever app is in front — the
    /// Item Bar's own key; an outside click is the interaction's.
    private func installKeyMonitors() {
        removeKeyMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in self?.hide() }
        }) { keyMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), let self, self.isShown else { return event }
            self.hide()
            return nil
        }) { keyMonitors.append(local) }
    }

    private func removeKeyMonitors() {
        for monitor in keyMonitors { NSEvent.removeMonitor(monitor) }
        keyMonitors = []
    }

    isolated deinit {
        for monitor in keyMonitors { NSEvent.removeMonitor(monitor) }
        panel?.orderOut(nil)
    }
}

// MARK: - Wiring

extension ScreenBarController {
    /// Hand the right ear to the menu bar: its feed becomes the ear's
    /// marks and the peek's glyphs, the pointer's hover, scroll and
    /// click on the ear open the peek, and a glyph's click opens its
    /// item the Item Bar's way. The utility hears when the ears are up,
    /// and when a gesture is the ear's rather than the bar's.
    func attachMenuBar(_ menuBar: MenuBarUtility, interaction: ScreenBarInteraction) {
        menuBar.earAvailable = { [weak self] in self?.carriesMenuBarMarks ?? false }
        menuBar.earAnswersGesture = { [weak self] in
            guard let self else { return false }
            let point = NSEvent.mouseLocation
            return self.peekZone(atScreenPoint: point)
                || (self.peekRegion?.corridor.contains(point) ?? false)
        }
        peek.model.onOpen = { [weak self, weak menuBar] id in
            self?.peek.hide()
            menuBar?.openFromEar(itemID: id)
        }
        interaction.peekZoneAt = { [weak self] point in self?.peekZone(atScreenPoint: point) ?? false }
        interaction.peekRegion = { [weak self] in self?.peekRegion }
        interaction.peekState = { [weak self] in
            (shown: self?.peek.isShown ?? false, pinned: self?.peek.isPinned ?? false)
        }
        interaction.onPeek = { [weak self] intent in self?.handlePeek(intent) }
        observeMenuBarFeed(menuBar)
    }

    /// Follow the utility's feed for the life of the app, re-armed after
    /// every change the way the delegate follows the core.
    private func observeMenuBarFeed(_ menuBar: MenuBarUtility) {
        menuBarFeed = menuBar.earFeed
        withObservationTracking {
            _ = menuBar.earFeed
        } onChange: { [weak self, weak menuBar] in
            Task { @MainActor [weak self, weak menuBar] in
                guard let self, let menuBar else { return }
                self.observeMenuBarFeed(menuBar)
            }
        }
    }
}
