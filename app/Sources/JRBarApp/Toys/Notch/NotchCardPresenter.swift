import AppKit
import JRBarCore

/// The glass card under the notch — the band's peek and pinned card.
/// It is the fallback surface: while the Notch island is drawn the
/// island itself grows into the card instead, and this panel stays
/// dark, so the two can never both be up. The band's
/// `ScreenBarInteraction` decides when a peek or pin happens and the
/// presenter owns what the card hangs from — the band, else the notch
/// itself — and what is in it.
@MainActor
final class NotchCardPresenter {
    private let panel: NotchCardPanel
    var model: NotchCardModel { panel.model }

    private(set) var isShown = false
    var isPinned: Bool { panel.isPinned }

    /// The shown card's frame — both owners' hover regions union it in,
    /// so crossing band, island and card never counts as leaving.
    var cardFrame: NSRect? { isShown ? panel.frame : nil }

    /// The focus the header names (`PanelStore.screenBarFocus`).
    var focus: @MainActor () -> ScreenBarFocus? = { nil }
    /// The live session rows (`NotchIsland.summarize`); the focus's own
    /// session is dropped here so it is never listed twice.
    var sessionRows: @MainActor () -> [NotchIslandRow] = { [] }
    /// The headline meters — `NotchIsland.meters` while `showUsage`.
    var meters: @MainActor () -> [NotchIslandMeter] = { [] }
    /// What the card hangs from: the island's frame while it shows, the
    /// band's rect, or `NotchCardPresenter.notchAnchor`.
    var anchor: @MainActor () -> NSRect? = { nil }
    /// Room under the anchor another surface already claims — the
    /// docked buddy's HUD panel — so the card drops below it.
    var clearance: @MainActor () -> CGFloat = { 0 }
    /// The notch system's current card surface, published by `NotchToy`
    /// on every reconcile. `NotchIsland.surface` is the single answer
    /// the island and this card both read, so the two surfaces can
    /// never disagree about whose turn it is — and `.none` until the
    /// first publish, so a card can never draw before ownership is
    /// decided. Written and read on the main actor alone.
    nonisolated(unsafe) static var publishedSurface: NotchSurface = .none

    /// The notch system's current card surface (`NotchIsland.surface`).
    /// Defaults to the toy's published answer; tests override the
    /// closure directly. This panel may draw only on `.glass`:
    /// `.island` means the grown island IS the card and a `present`
    /// that slips past the gesture layer must stay dark; `.none` — the
    /// utility switched off — means nothing notch-related draws at all.
    var surface: @MainActor () -> NotchSurface = { NotchCardPresenter.publishedSurface }
    var onOpenSession: @MainActor (String) -> Void = { _ in }
    var onOpenOverview: @MainActor () -> Void = {}

    /// The last focus presented, so a re-anchor can re-show what was up
    /// even when the provider is momentarily empty.
    private var lastFocus: ScreenBarFocus?
    /// Esc while a pinned card is up lets it go — the card never
    /// becomes key, so the presenter watches for it: local covers the
    /// pointer having activated us, global every other app.
    private var pinnedKeyMonitors: [Any] = []

    init(model: NotchCardModel) {
        panel = NotchCardPanel(model: model)
        model.onOpenSession = { [weak self] in
            guard let self, let session = self.model.focus.clickSession else { return }
            self.hide()
            self.onOpenSession(session)
        }
        // A click on any session row opens it — the same raise the
        // header's Open does for the focus session.
        model.onOpenRow = { [weak self] session in
            guard let self else { return }
            self.hide()
            self.onOpenSession(session)
        }
        model.onClose = { [weak self] in self?.hide() }
        model.onOpenOverview = { [weak self] in self?.onOpenOverview() }
    }

    /// The transient glance — the header only. A card already pinned
    /// only refreshes: a peek can never demote it.
    func peek() {
        present()
    }

    /// The full card, held open and mouse-accepting — a band click's
    /// deliberate pin, or the island's hover.
    func pin() {
        panel.setPinned(true)
        present()
    }

    /// Drop the pin without dismissing; callers that want the card gone
    /// use `hide`.
    func unpin() {
        setPinned(false)
    }

    func hide() {
        setPinned(false)
        guard isShown else { return }
        isShown = false
        panel.dismiss()
    }

    /// The anchor moved (a wing slot came or went, the island reframed):
    /// re-present under the new rect instead of hiding and re-arming.
    func geometryChanged() {
        if isShown { present() }
    }

    /// Sessions, usage or focus moved on while the card is up — re-feed
    /// the model and refit.
    func refresh() {
        if isShown { present() }
    }

    private func setPinned(_ pinned: Bool) {
        panel.setPinned(pinned)
        for monitor in pinnedKeyMonitors { NSEvent.removeMonitor(monitor) }
        pinnedKeyMonitors = []
        guard pinned else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.hide() }
                return nil
            }
            return event
        }) { pinnedKeyMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.hide() }
            }
        }) { pinnedKeyMonitors.append(global) }
    }

    private func present() {
        // The exactly-one-surface rule, enforced at the panel: the
        // island outranks this card and a switched-off utility shows
        // nothing, whatever the gesture layer asked for. A card already
        // up when ownership flips is dismissed, not left doubled.
        guard surface() == .glass else {
            hide()
            return
        }
        guard let focus = focus() ?? lastFocus else { return }
        guard let anchor = anchor() else { return }
        lastFocus = focus
        model.focus = focus
        // The focus's own session is the header, not a row.
        model.rows = sessionRows().filter { $0.id != focus.focusSession }
        model.meters = meters()
        panel.present(under: anchor, clearance: clearance())
        isShown = true
    }

    /// Nothing to hang from: the notch's own slot on the main screen —
    /// real or simulated (`islandSlot`/`islandDepth` fold the toggle in).
    static func notchAnchor() -> NSRect? {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let depth = ScreenBarGeometry.islandDepth(of: screen)
        let slot = ScreenBarGeometry.islandSlot(on: screen)
        let width = slot?.width ?? ScreenBarGeometry.slotWidth(of: screen)
        let centerX = slot?.centerX ?? screen.frame.midX
        return NSRect(x: centerX - width / 2, y: screen.frame.maxY - depth - 6,
                      width: width, height: 6)
    }
}
