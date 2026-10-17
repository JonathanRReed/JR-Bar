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
    case leave
    case resumeHover
}

// MARK: - The ear's marks

/// The menu bar's say on the right ear, read off `MenuBarEarFeed`: while
/// items are tucked away and nothing else claims the side, a resting
/// mark holds the ear — the peek's home — so the reveal surface is there
/// whenever there is something to reveal.
struct ScreenBarMenuBarMarks: Equatable {
    /// How many hidden items the feed tiles.
    var hiddenCount = 0
    /// The standing nudge's mark, while its beat on the ear lasts.
    var nudge: ScreenBarWingSlot?

    /// The resting mark: one ellipsis, the ‹'s "more here" — the same
    /// for two items or twenty, so it never reads as a meter. How many
    /// is VoiceOver's and the peek's to say.
    static let restingSymbol = "ellipsis"

    init(hiddenCount: Int = 0, nudge: ScreenBarWingSlot? = nil) {
        self.hiddenCount = hiddenCount
        self.nudge = nudge
    }

    /// The marks `feed` makes; `showsNudge` is whether its nudge's beat
    /// on the ear still lasts.
    init(feed: MenuBarEarFeed?, showsNudge: Bool = true) {
        hiddenCount = feed?.hidden.count ?? 0
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

    /// `wings` with the menu bar's marks on the right ear. A nudge takes
    /// the side from whatever ambient mark held it, for its beat. The
    /// resting mark only fills an empty side: the meter, the media ear
    /// and a device beat all keep it, and their ear still opens the
    /// peek.
    static func apply(_ marks: ScreenBarMenuBarMarks, to wings: ScreenBarWings) -> ScreenBarWings {
        var dressed = wings
        if let nudge = marks.nudge {
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
/// It hangs below the band when there is room, and flips up on a short
/// display. Its right edge lines up with the right
/// ear's outer edge, so it reads as that ear's lobe grown down; a wide
/// row grows it toward the notch and past it, never off the screen.
enum ScreenBarPeekLayout {
    static func corridorContains(_ point: CGPoint, popup: CGRect, ear: CGRect) -> Bool {
        if popup.contains(point) || ear.contains(point) { return true }
        // Only the gap below the ear belongs to the popup. A bounding
        // union also claims the notch above a wide row and steals hover.
        let gap = CGRect(x: ear.minX, y: popup.maxY, width: ear.width,
                         height: max(0, ear.minY - popup.maxY))
        return gap.contains(point)
    }

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

    /// Prefer below the band, flip up when needed, and keep content
    /// below the hardware. AppKit coordinates.
    static func frame(size: CGSize, ear: CGRect, band: CGRect?, screen: CGRect) -> CGRect {
        let top = band.map { min(ear.minY, $0.minY - gapBelowBand) } ?? ear.minY
        let rightmost = screen.maxX - edgeMargin
        let leftmost = screen.minX + edgeMargin
        let x = max(leftmost, min(ear.maxX, rightmost) - size.width)
        let floor = screen.minY + edgeMargin
        let ceiling = min(ear.minY, screen.maxY - edgeMargin)
        let height = min(size.height, max(0, ceiling - floor))
        let below = top - height
        let above = (band?.maxY ?? ear.maxY) + gapBelowBand
        let y = min(ceiling - height, max(floor, below >= floor ? below : above))
        return CGRect(x: x, y: y, width: size.width, height: height)
    }
}

// MARK: - The peek

/// What the peek shows — pushed by the controller from the menu bar's
/// feed, observed by the view.
@MainActor
@Observable
final class ScreenBarPeekModel {
    @ObservationIgnored private(set) var layoutRevision = 0
    var tiles: [MenuBarEarFeed.Tile] = [] {
        didSet { if tiles != oldValue { layoutRevision &+= 1 } }
    }
    /// The newcomer or change on offer, with its three answers.
    var nudge: MenuBarEarFeed.Nudge? {
        didSet { if nudge != oldValue { layoutRevision &+= 1 } }
    }
    var width: CGFloat = ScreenBarPeekLayout.width(tileWidths: [], hasWords: false) {
        didSet { if width != oldValue { layoutRevision &+= 1 } }
    }
    /// A glyph was clicked: open that item the Item Bar's way.
    @ObservationIgnored var onOpen: @MainActor (String) -> Void = { _ in }
    /// A nudge's answer was clicked — the only way one is ever answered.
    @ObservationIgnored var onChoose: @MainActor (MenuBarEarChoice, String) -> Void = { _, _ in }
    /// The keep-awake hold the ear's cup or laptop stands for — its words
    /// at the peek's foot, since the ear itself never spells them.
    var awake: ScreenBarEarMarks.Awake? {
        didSet { if awake != oldValue { layoutRevision &+= 1 } }
    }

    /// Whether the peek carries sentences, which set its floor width.
    var hasWords: Bool { nudge != nil || awake != nil }
}

/// The peek's face, top to bottom in notch black: the nudge standing,
/// with its three answers; the hidden glyphs in a row; the keep-awake
/// hold in words. Template glyphs
/// are drawn white, as the bar would draw them on a dark wallpaper; a
/// glyph never photographed shows its app's icon.
struct ScreenBarPeekView: View {
    let model: ScreenBarPeekModel
    let viewportHeight: CGFloat?

    init(model: ScreenBarPeekModel, viewportHeight: CGFloat? = nil) {
        self.model = model
        self.viewportHeight = viewportHeight
    }

    var body: some View {
        fittedContent
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

    @ViewBuilder private var fittedContent: some View {
        if let viewportHeight {
            ScrollView(.vertical) { contents }
                .frame(height: viewportHeight)
        } else {
            contents
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: ScreenBarPeekLayout.spacing) {
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
        .accessibilityLabel(Self.spokenName(tile))
        .accessibilityHint("Opens its menu")
    }

    /// The tile's name for VoiceOver. The unseen dot is the only sign an
    /// item changed since you looked, so the name carries it in words.
    nonisolated static func spokenName(_ tile: MenuBarEarFeed.Tile) -> String {
        tile.changed ? "\(tile.name), changed since you last looked" : tile.name
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
            Image(nsImage: icon ?? MenuBarAppIcons.icon(for: tile.item)
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
    private(set) var isShown = false {
        didSet { if isShown != oldValue { onVisibilityChange(isShown) } }
    }
    var onVisibilityChange: @MainActor (Bool) -> Void = { _ in }
    private(set) var isPinned = false
    private var panel: ScreenBarPeekPanel?
    private var hosting: NSHostingView<ScreenBarPeekView>?
    private var sizeProbe: NSHostingView<ScreenBarPeekView>?
    private var naturalSize: (revision: Int, size: NSSize)?
    private var displayedRevision: Int?
    var measureNaturalSize: @MainActor (NSHostingView<ScreenBarPeekView>) -> NSSize = { probe in
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize
    }
    private var hoverDismissAnchor: ScreenBarPeekAnchor?
    /// Esc while the peek is pinned (`CardEscapeWatch`): only an Esc no
    /// other JR-Bar window owns is taken.
    private var escape: CardEscapeWatch?
    /// Where the Esc presses come from — AppKit's monitors; a test hands
    /// in a fake.
    var keySource: CardEscapeWatch.Source = .system
    /// Esc is being listened for — only while the peek is pinned.
    var listensForEscape: Bool { escape?.isListening == true }

    /// The panel's frame while it hangs.
    var frame: NSRect? { isShown ? panel?.frame : nil }
    var canResumeHover: Bool {
        guard let hoverDismissAnchor, panel?.isVisible == true else { return false }
        return !isShown && anchor() == hoverDismissAnchor
    }
    var hoverFrame: NSRect? { isShown || canResumeHover ? panel?.frame : nil }

    /// Entry remains a soft fade; dismissal leaves faster. Reduce Motion swaps immediately.
    private static let revealSeconds: TimeInterval = 0.18
    private static let dismissSeconds: TimeInterval = 0.10
    var presentPanel: @MainActor (ScreenBarPeekPanel, CGFloat?) -> Void = { panel, start in
        NotchSurfaceMotion.present(panel, from: start, duration: ScreenBarPeek.revealSeconds,
                                   reducedDuration: nil, curve: nil)
    }

    func show(pinned: Bool) {
        guard anchor() != nil else { hide(); return }
        let panel = self.panel ?? makePanel()
        if pinned, !isPinned { installKeyMonitors() }
        isPinned = isPinned || pinned
        guard !isShown else { relayout(); return }
        hoverDismissAnchor = nil
        isShown = true
        panel.ignoresMouseEvents = false
        relayout()
        guard isShown else { return }
        presentPanel(panel, panel.isVisible ? nil : 0)
    }

    func hide(resumable: Bool = false) {
        hoverDismissAnchor = resumable && isShown && !isPinned ? anchor() : nil
        removeKeyMonitors()
        isPinned = false
        guard isShown, let panel else { isShown = false; return }
        isShown = false
        // A folding peek answers nothing: the second click of a double
        // click on a glyph lands on a fading panel and must not open the
        // item twice.
        panel.ignoresMouseEvents = true
        NotchSurfaceMotion.dismiss(panel, duration: Self.dismissSeconds, reducedDuration: nil, curve: nil,
                                   stillGone: { [weak self] in self.map { !$0.isShown } ?? false })
    }

    /// Fit the panel to its content and hang it under the ear — after a
    /// content change or a move of the ear. A peek whose ear went away
    /// folds.
    func relayout() {
        guard isShown, let panel, let hosting else { return }
        guard let anchor = anchor() else { hide(); return }
        let revision = model.layoutRevision
        let size: NSSize
        if let cached = naturalSize, cached.revision == revision {
            size = cached.size
        } else {
            let view = ScreenBarPeekView(model: model)
            let probe = sizeProbe ?? NSHostingView(rootView: view)
            probe.sizingOptions = [.intrinsicContentSize]
            sizeProbe = probe
            probe.rootView = view
            size = measureNaturalSize(probe)
            naturalSize = (revision, size)
        }
        let frame = ScreenBarPeekLayout.frame(size: CGSize(width: model.width, height: size.height),
                                              ear: anchor.ear, band: anchor.band, screen: anchor.screen)
        let viewportHeight = frame.height < size.height ? frame.height : nil
        if displayedRevision != revision || hosting.rootView.viewportHeight != viewportHeight {
            hosting.rootView = ScreenBarPeekView(model: model, viewportHeight: viewportHeight)
            hosting.layoutSubtreeIfNeeded()
            displayedRevision = revision
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func makePanel() -> ScreenBarPeekPanel {
        let panel = ScreenBarPeekPanel()
        let hosting = NSHostingView(rootView: ScreenBarPeekView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// A pinned peek folds on Esc, whichever app is in front — the
    /// Item Bar's own key; an outside click is the interaction's. The
    /// local monitor takes only an Esc the peek's own window or no window
    /// owns: Esc in a Settings sheet or a field stays that window's.
    func installKeyMonitors() {
        removeKeyMonitors()
        let watch = CardEscapeWatch(
            source: keySource,
            ownWindows: { [weak self] in [self?.panel] },
            onEscape: { [weak self] in self?.hide() })
        escape = watch
        watch.start()
    }

    private func removeKeyMonitors() {
        escape?.stop()
        escape = nil
    }

    isolated deinit {
        escape?.stop()
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
        menuBar.earAnswersGesture = { [weak self] point in
            guard let self else { return false }
            return self.peekZone(atScreenPoint: point) || self.peekCorridor(contains: point)
                || self.hoverScreenRects.contains(where: { $0.contains(point) })
                || self.shoulderContains(point)
                || ScreenBarGeometry.islandScreenRect?.contains(point) == true
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
        interaction.peekCanResume = { [weak self] in self?.peek.canResumeHover ?? false }
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
