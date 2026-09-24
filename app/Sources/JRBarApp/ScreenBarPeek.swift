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
/// items are tucked away and nothing else claims the side, a resting
/// mark holds the ear — the peek's home — so the reveal surface is there
/// whenever there is something to reveal. When hiding stops working the
/// ear says so in the alert tone, and its peek says why.
struct ScreenBarMenuBarMarks: Equatable {
    /// How many hidden items the feed tiles.
    var hiddenCount = 0
    /// Why hiding stopped — the alert mark's VoiceOver words; nil while
    /// the engine is healthy.
    var failure: String?
    /// The standing nudge's mark, while its beat on the ear lasts.
    var nudge: ScreenBarWingSlot?

    /// The alert mark: the menu bar itself, in the failed tone — the
    /// subject, not a generic warning, so it never reads as the band's
    /// refused program.
    static let failureSymbol = "menubar.rectangle"
    /// The resting mark: one ellipsis, the ‹'s "more here" — the same
    /// for two items or twenty, so it never reads as a meter. How many
    /// is VoiceOver's and the peek's to say.
    static let restingSymbol = "ellipsis"

    init(hiddenCount: Int = 0, failure: String? = nil, nudge: ScreenBarWingSlot? = nil) {
        self.hiddenCount = hiddenCount
        self.failure = failure
        self.nudge = nudge
    }

    /// The marks `feed` makes; `showsNudge` is whether its nudge's beat
    /// on the ear still lasts.
    init(feed: MenuBarEarFeed?, showsNudge: Bool = true) {
        hiddenCount = feed?.hidden.count ?? 0
        failure = feed?.failure
        nudge = showsNudge ? feed?.nudge.map(Self.nudgeSlot) : nil
    }

    /// A nudge's mark: the item's photographed glyph while it is only an
    /// icon, else its app's icon, else a sparkle — never its name, and
    /// never a photograph of words: a face wider than the glyph cache's
    /// icon width carries text (a title, a VPN's "Connected", a clock),
    /// so the ear draws the app's icon instead. The name, the change and
    /// the wide face are VoiceOver's and the peek's.
    static func nudgeSlot(_ nudge: MenuBarEarFeed.Nudge) -> ScreenBarWingSlot {
        let photo = nudge.tile.face.flatMap { face in
            MenuBarGlyphCache.persists(width: Double(face.width))
                ? ScreenBarWingGlyph(image: face.image, template: face.template) : nil
        }
        let glyph = photo ?? nudge.icon.map { ScreenBarWingGlyph(image: $0, template: false) }
        var slot = ScreenBarWingSlot(text: nudge.words, symbol: glyph == nil ? "sparkle" : nil)
        slot.glyph = glyph
        slot.markID = nudge.id
        return slot
    }

    /// VoiceOver's words for the resting mark.
    static func hiddenWords(_ count: Int) -> String {
        count == 1 ? "1 menu bar item tucked away" : "\(count) menu bar items tucked away"
    }

    /// `wings` with the menu bar's marks on the right ear. A failure
    /// takes the side from whatever ambient mark held it — hiding
    /// stopped, and the person should see that where they look — then a
    /// nudge, for its beat. The resting mark only fills an empty side:
    /// the meter, the media ear and a device beat all keep it, and their
    /// ear still opens the peek.
    static func apply(_ marks: ScreenBarMenuBarMarks, to wings: ScreenBarWings) -> ScreenBarWings {
        var dressed = wings
        if let failure = marks.failure {
            dressed.right = ScreenBarWingSlot(text: failure, symbol: failureSymbol, tone: .alert)
        } else if let nudge = marks.nudge {
            // A newcomer or a change holds the side for its beat, then
            // the side goes back to what it showed.
            dressed.right = nudge
        } else if dressed.right == nil, marks.hiddenCount > 0 {
            dressed.right = ScreenBarWingSlot(text: hiddenWords(marks.hiddenCount),
                                              symbol: restingSymbol)
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
    /// The newcomer or change on offer, with its three answers.
    var nudge: MenuBarEarFeed.Nudge?
    var width: CGFloat = ScreenBarPeekLayout.width(tileWidths: [], hasWords: false)
    /// A glyph was clicked: open that item the Item Bar's way.
    @ObservationIgnored var onOpen: @MainActor (String) -> Void = { _ in }
    /// A nudge's answer was clicked — the only way one is ever answered.
    @ObservationIgnored var onChoose: @MainActor (MenuBarEarChoice, String) -> Void = { _, _ in }
    /// The keep-awake hold the ear's cup or laptop stands for — its words
    /// at the peek's foot, since the ear itself never spells them.
    var awake: ScreenBarEarMarks.Awake?

    /// Whether the peek carries sentences, which set its floor width.
    var hasWords: Bool { failure != nil || nudge != nil || awake != nil }
}

/// The peek's face, top to bottom in notch black: the reason hiding
/// stopped, when it has; the nudge standing, with its three answers; the
/// hidden glyphs in a row; the keep-awake hold in words. Template glyphs
/// are drawn white, as the bar would draw them on a dark wallpaper; a
/// glyph never photographed shows its app's icon.
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
            if let nudge = model.nudge {
                ScreenBarPeekNudge(nudge: nudge,
                                   open: { model.onOpen(nudge.tile.id) },
                                   choose: { model.onChoose($0, nudge.id) })
            }
            if !model.tiles.isEmpty {
                tileRow
            }
            if let awake = model.awake {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: awake.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ScreenBarWingSlot(text: "", tone: awake.tone).textColor)
                        .accessibilityHidden(true)
                    Text(awake.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
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
        .accessibilityLabel(model.tiles.isEmpty ? "Menu bar" : "Hidden menu bar items")
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

/// A nudge in the peek: the item's glyph (a click opens it), what
/// happened and to whom, and the three answers — the section it sits in
/// now shown as the current one. Nothing here is answered by a hover or
/// a timeout: only a click on one of the three.
struct ScreenBarPeekNudge: View {
    let nudge: MenuBarEarFeed.Nudge
    let open: () -> Void
    let choose: (MenuBarEarChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ScreenBarPeekTile(tile: nudge.tile, icon: nudge.icon, action: open)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nudge.heading)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(nudge.tile.item.ownerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if let detail = nudge.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 6) {
                ForEach(MenuBarEarChoice.allCases, id: \.self) { choice in
                    let current = choice.section == nudge.section
                    Button { choose(choice) } label: {
                        Text(choice.title)
                            .font(.system(size: 12, weight: current ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(current ? 0.95 : 0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous)
                                .fill(.white.opacity(current ? 0.22 : 0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(choice.help)
                    .accessibilityLabel(choice.title)
                    .accessibilityHint(choice.help)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
        }
    }
}

/// One glyph in the peek: its face, a light wash under the pointer, and
/// the one unseen dot (`UnseenDot`) while it changed since you looked.
struct ScreenBarPeekTile: View {
    let tile: MenuBarEarFeed.Tile
    /// The app's icon when the glyph was never photographed — read once
    /// by the caller, or here from the running app.
    var icon: NSImage? = nil
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
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
                        UnseenDot().padding(2)
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
            Image(nsImage: icon ?? tile.item.owner?.icon
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

    /// The peek eases in and out like the band (0.18 s, the context's
    /// own curve); Reduce Motion keeps the instant swap.
    private static let fadeSeconds: TimeInterval = 0.18

    func show(pinned: Bool) {
        guard anchor() != nil else { return }
        let panel = self.panel ?? makePanel()
        if pinned, !isPinned { installKeyMonitors() }
        isPinned = isPinned || pinned
        guard !isShown else { relayout(); return }
        isShown = true
        panel.ignoresMouseEvents = false
        relayout()
        NotchSurfaceMotion.present(panel, from: 0, duration: Self.fadeSeconds, reducedDuration: nil, curve: nil)
    }

    func hide() {
        removeKeyMonitors()
        isPinned = false
        guard isShown, let panel else { isShown = false; return }
        isShown = false
        // A folding peek answers nothing: the second click of a double
        // click on a glyph lands on a fading panel and must not open the
        // item twice.
        panel.ignoresMouseEvents = true
        NotchSurfaceMotion.dismiss(panel, duration: Self.fadeSeconds, reducedDuration: nil, curve: nil,
                                   stillGone: { [weak self] in self.map { !$0.isShown } ?? false })
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
            return self.peekZone(atScreenPoint: point) || self.peekCorridor(contains: point)
        }
        peek.model.onOpen = { [weak self, weak menuBar] id in
            self?.peek.hide()
            menuBar?.openFromEar(itemID: id)
        }
        peek.model.onChoose = { [weak self, weak menuBar] choice, nudgeID in
            self?.peek.hide()
            menuBar?.chooseFromEar(choice, nudgeID: nudgeID)
        }
        interaction.peekZoneAt = { [weak self] point in self?.peekZone(atScreenPoint: point) ?? false }
        interaction.peekPanel = { [weak self] in self?.peekFrame }
        interaction.peekCorridorAt = { [weak self] point in self?.peekCorridor(contains: point) ?? false }
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
