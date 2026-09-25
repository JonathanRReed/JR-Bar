import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore
import JRBarUI

/// Render proof for ⌘-drag across the icon: the right half of the bar
/// as it measured on 2026-09-24 (the Screen Bar's band to 980, the icon's
/// mirror, Passwords, Wi-Fi, the battery, Weather, Control Center and the
/// clock), with the mirror drawn by `MenuBarIconMirror` itself at the
/// seat its own rules give — today, Tailscale shown by a drop right of
/// the icon and ⌘-dragged back left (hidden, the icon holding its x a
/// beat), Passwords mid-drag with the icon frozen, the drag's reveal and
/// its divider, a drop's note under the icon, Passwords' cover-drop, both
/// seats — plus the card's new rows and the empty run's hint. Off by default; `JRBAR_RENDER_PROOF=1` writes
/// PNGs into `JRBAR_RENDER_PROOF_DIR` (default /tmp/jrbar-audit/menubar).
@Suite("Menu Bar drag render proof")
@MainActor
struct MenuBarDragRenderProofTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit/menubar", isDirectory: true)
    }

    // MARK: The fixture bar

    /// One item on the fixture bar: where it stands (Quartz x) and what
    /// it draws.
    struct BarItem {
        var x: CGFloat
        var width: CGFloat
        var symbol: String?
        var text: String?
    }

    /// The part of the screen the proof shows, and the band's edge.
    static let origin: CGFloat = 500
    static let canvasWidth: CGFloat = 1012
    static let barHeight: CGFloat = 37
    static let clearOf: CGFloat = 980

    static let passwords = BarItem(x: 1119, width: 39, symbol: "key.fill")
    static let wifi = BarItem(x: 1165, width: 22, symbol: "wifi")
    static let battery = BarItem(x: 1203, width: 26, symbol: "battery.75percent")
    static let weather = BarItem(x: 1236, width: 71.5, symbol: "cloud.sun.fill", text: "72°")
    static let controlCenter = BarItem(x: 1315, width: 26, symbol: "switch.2")
    static let clock = BarItem(x: 1357, width: 135, text: "Thu Sep 24  12:17")
    static let tailscale = BarItem(x: 0, width: 24, symbol: "circle.grid.3x3.fill")

    /// Today's drawn run, left to right.
    static var today: [BarItem] { [passwords, wifi, battery, weather, controlCenter, clock] }

    /// The run after `item` left it: everything left of it slides right
    /// by its width and macOS's gap — the bar packs from the right.
    static func without(_ gone: BarItem, from run: [BarItem]) -> [BarItem] {
        run.filter { $0.x != gone.x }.map { item in
            var moved = item
            if item.x < gone.x { moved.x += gone.width + MenuBarIconMirror.itemGap }
            return moved
        }
    }

    /// The run after `item` joined it just left of `before`: everything
    /// left of that slot slides left.
    static func adding(_ item: BarItem, before anchor: BarItem, to run: [BarItem]) -> [BarItem] {
        var joined = item
        joined.x = anchor.x - MenuBarIconMirror.itemGap - item.width
        return (run.map { other in
            var moved = other
            if other.x < anchor.x { moved.x -= item.width + MenuBarIconMirror.itemGap }
            return moved
        } + [joined]).sorted { $0.x < $1.x }
    }

    /// The icon's face: the Agents strip with sample sessions.
    static func face(hidden: Int, divider: Bool = false) -> MenuBarIconFace {
        let spec = StatusIconSpec(style: .agents, sessions: StatusItemController.sampleSessionDots, phase: 0.4)
        var face = MenuBarIconFace(image: StatusIconRenderer.shared.image(for: spec),
                                   length: StatusIconRenderer.size(for: spec).width, hiddenCount: hidden)
        face.dragDivider = divider
        return face
    }

    /// The mirror, drawn by its own content view, and its width.
    static func mirror(_ face: MenuBarIconFace, dark: Bool) throws -> (image: NSImage, width: CGFloat) {
        let mirror = MenuBarIconMirror()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        mirror.appearance = appearance
        var worn = face
        worn.appearance = appearance
        mirror.update(face: worn)
        let width = mirror.panelWidth
        mirror.setFrame(NSRect(x: -20_000, y: -20_000, width: width, height: MenuBarIconMirror.itemHeight),
                        display: false)
        let content = try #require(mirror.contentView)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        appearance?.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: rep)
        }
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        return (image, width)
    }

    /// The gap seat for a run: `MenuBarIconMirror.seat` over its frames.
    static func gapSeat(_ run: [BarItem], width: CGFloat) -> CGFloat {
        MenuBarIconMirror.seat(drawn: run.map { CGRect(x: $0.x, y: 6.5, width: $0.width, height: 24) },
                               clearOf: clearOf, width: width, rowMaxX: 1512)
    }

    /// One state of the bar.
    struct BarState {
        var name: String
        var caption: String
        var run: [BarItem]
        var hidden: Int
        var seat: (CGFloat) -> CGFloat
        var divider = false
        /// A glyph under the pointer — the item being dragged.
        var dragged: BarItem?
        var pointerX: CGFloat?
        /// Items the drag's reveal brought in, left of the icon.
        var revealed: [BarItem] = []
        /// Items under a cover — a hole in the bar, outlined so the
        /// proof says what the blank is.
        var covered: [BarItem] = []
        var note: String?
        /// Our real slot, outlined (the slot seat).
        var slot: CGRect?
    }

    // MARK: Always on

    @Test("the fixture seats the icon flush left of Passwords today, and the drag's states differ as they should")
    func fixtureSeats() throws {
        let width: CGFloat = 73
        let todaySeat = Self.gapSeat(Self.today, width: width)
        #expect(todaySeat == Self.passwords.x - MenuBarIconMirror.itemGap - width)
        let afterHide = Self.gapSeat(Self.without(Self.weather, from: Self.today), width: width)
        #expect(afterHide > todaySeat, "once thawed the icon follows the run right")
        let afterShow = Self.gapSeat(Self.adding(Self.tailscale, before: Self.passwords, to: Self.today),
                                     width: width)
        #expect(afterShow == todaySeat - Self.tailscale.width - MenuBarIconMirror.itemGap,
                "a show-drop slides the icon left by the item's width")
        let (_, mirrorWidth) = try Self.mirror(Self.face(hidden: 10), dark: false)
        #expect(mirrorWidth > MenuBarIconMirror.chevronZone)
        // The mid-drag glyph ends clear of the frozen icon, and of the band.
        let frozenSeat = Self.gapSeat(Self.today, width: mirrorWidth)
        let dragX = Self.pointer(ending: frozenSeat, glyph: Self.passwords)
        #expect(dragX + Self.passwords.width / 2 <= frozenSeat - 4)
        #expect(dragX - Self.passwords.width / 2 >= Self.clearOf)
        // The drag's reveal never draws under the band.
        let brought = Self.revealedRun(endingAt: frozenSeat)
        #expect(!brought.isEmpty && brought.allSatisfy { $0.x >= Self.clearOf })
        // A cover-drop: the covered hole is blank bar to the seat, so the
        // icon keeps its place beside Wi-Fi and stands over the hole.
        let drop = Self.coverDrop(Self.passwords, in: Self.today)
        let dropSeat = Self.gapSeat(drop.drawn, width: mirrorWidth)
        #expect(abs(dropSeat + mirrorWidth - (Self.wifi.x - MenuBarIconMirror.itemGap)) < 0.01)
        #expect(dropSeat < drop.item.x + drop.item.width, "the hole is under the icon, never right of it")
    }

    // MARK: Proof shots

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the menu bar drag PNGs"))
    func barStates() throws {
        for dark in [false, true] {
            let (_, width) = try Self.mirror(Self.face(hidden: 10), dark: dark)
            let todaySeat = Self.gapSeat(Self.today, width: width)
            let hiddenRun = Self.without(Self.weather, from: Self.today)
            let shownRun = Self.adding(Self.tailscale, before: Self.passwords, to: Self.today)
            // The slot seat: our real item sized to the icon, right-aligned
            // in it, the run left of it pushed left.
            let slotLength = MenuBarSlotLength.quantized(width, floor: StatusItemController.anchorSlimLength)
            let slotMaxX = Self.passwords.x - MenuBarIconMirror.itemGap
            let slot = CGRect(x: slotMaxX - slotLength, y: 6.5, width: slotLength, height: 24)
            let shownSeat = Self.gapSeat(shownRun, width: width)
            let dragPointer = Self.pointer(ending: todaySeat, glyph: Self.passwords)
            let covered = Self.coverDrop(Self.passwords, in: Self.today)
            let states: [BarState] = [
                BarState(name: "today", caption: "Today — the icon flush left of Passwords, ten apps hidden",
                         run: Self.today, hidden: 10, seat: { Self.gapSeat(Self.today, width: $0) }),
                BarState(name: "after-show",
                         caption: "A show-drop: Tailscale right of the icon, the icon slid left by its width",
                         run: shownRun, hidden: 9, seat: { Self.gapSeat(shownRun, width: $0) }),
                BarState(name: "mid-drag",
                         caption: "⌘-dragging Passwords left across the icon — the icon frozen where it stood, no Item Bar",
                         run: Self.today.filter { $0.x != Self.passwords.x }, hidden: 10, seat: { _ in todaySeat },
                         dragged: Self.passwords, pointerX: dragPointer),
                BarState(name: "after-hide",
                         caption: "Tailscale ⌘-dragged back left: hidden through macOS, the icon holds its x a beat, then settles as Today",
                         run: Self.today, hidden: 10, seat: { _ in shownSeat }),
                BarState(name: "drag-reveal",
                         caption: "Show hidden items while ⌘-dragging: what fits comes in beside the icon, the ‹ a divider",
                         run: Self.today.filter { $0.x != Self.passwords.x }, hidden: 10, seat: { _ in todaySeat },
                         divider: true, dragged: Self.passwords, pointerX: Self.passwords.x + 12,
                         revealed: Self.revealedRun(endingAt: todaySeat)),
                BarState(name: "note",
                         caption: "A drop the bar can't honour says why, under the icon, for four seconds",
                         run: Self.today, hidden: 10, seat: { Self.gapSeat(Self.today, width: $0) },
                         note: MenuBarDropNote.systemItem.text),
                BarState(name: "note-covered",
                         caption: "Passwords dropped left: its cover (dashed) is blank bar, so the icon keeps its seat beside Wi-Fi, over it",
                         run: covered.run, hidden: 10, seat: { Self.gapSeat(covered.drawn, width: $0) },
                         covered: [covered.item], note: MenuBarDropNote.appleExtraCovered.text),
                BarState(name: "seat-slot",
                         caption: "The slot seat: the icon on JR-Bar's own slot (dashed), sized to it",
                         run: Self.today, hidden: 10, seat: { slotMaxX - $0 }, slot: slot),
            ]
            for state in states {
                let (image, mirrorWidth) = try Self.mirror(Self.face(hidden: state.hidden, divider: state.divider),
                                                           dark: dark)
                let view = BarProof(state: state, mirror: image, mirrorWidth: mirrorWidth, dark: dark)
                try Self.write(view, name: "menubar-drag-\(state.name)", dark: dark,
                               size: CGSize(width: Self.canvasWidth, height: 150))
            }
        }
    }

    /// The hidden run a drag's reveal brings in, packed left of the icon
    /// — only what fits clear of the band; macOS keeps the rest in its
    /// own overflow.
    static func revealedRun(endingAt seat: CGFloat) -> [BarItem] {
        let symbols = ["message.fill", "cloud.fill", "bolt.horizontal.fill"]
        var x = seat - MenuBarIconMirror.itemGap
        var run: [BarItem] = []
        for symbol in symbols {
            x -= 24
            guard x >= clearOf + MenuBarIconMirror.itemGap else { break }
            run.append(BarItem(x: x, width: 24, symbol: symbol))
            x -= MenuBarIconMirror.itemGap
        }
        return run
    }

    /// Where the pointer rests so the dragged glyph ends a clear 4 pt
    /// left of the frozen icon's seat — past it, not on its ‹.
    static func pointer(ending seat: CGFloat, glyph: BarItem) -> CGFloat {
        seat - 4 - glyph.width / 2
    }

    /// A cover-drop of `item` left of the icon: macOS moves it just past
    /// JR-Bar's slim slot, which stays right of it, and the run packs
    /// from the right. `run` is the bar with the covered item in it;
    /// `drawn` leaves it out, as the seat does (`coverBlanked`).
    static func coverDrop(_ item: BarItem, in run: [BarItem]) -> (run: [BarItem], drawn: [BarItem], item: BarItem) {
        let rest = run.filter { $0.x != item.x }
        let next = rest.filter { $0.x > item.x }.map(\.x).min() ?? item.x + item.width
        let slotMinX = next - MenuBarIconMirror.itemGap - StatusItemController.anchorSlimLength
        var moved = item
        moved.x = slotMinX - MenuBarIconMirror.itemGap - item.width
        return ((rest + [moved]).sorted { $0.x < $1.x }, rest, moved)
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the menu bar card PNGs"))
    func cardRows() throws {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings(enabled: true)
        settings.concealSeeded = true
        utility.settings = { settings }
        final class Quiet: MenuBarConcealBackend {
            func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
                MenuBarAssertionToken(NSNumber(value: 1))
            }
            func invalidate(_ token: MenuBarAssertionToken) {}
        }
        utility.concealer = MenuBarConcealer(backend: Quiet())
        for dark in [false, true] {
            // In a grouped form, as the card sits on the Utilities page, so
            // the switches and pickers stand in the card's own column.
            let rows = Form {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        CardNote(MenuBarDragRows.cardNote(concealing: true, dragToHide: true))
                            .padding(.vertical, SettingsMetrics.xs)
                        MenuBarDragRows(utility: utility)
                        MenuBarItemBarAnchorRow(utility: utility)
                        CardSectionHeader("Advanced")
                        MenuBarPlacementRows(utility: utility)
                        MenuBarSpacingRelaunchRow(utility: utility)
                    }
                    .cardBodyStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .frame(width: 560, height: 640, alignment: .top)
            try Self.write(rows, name: "menubar-drag-card", dark: dark, size: CGSize(width: 560, height: 640),
                           window: true)
            let hint = HintMenuProof(hint: MenuBarUtility.emptyRunHint(concealing: true, dragToHide: true))
            try Self.write(hint, name: "menubar-drag-hint-menu", dark: dark, size: CGSize(width: 420, height: 150))
        }
    }

    // MARK: Writing

    private static func write(_ view: some View, name: String, dark: Bool, size: CGSize,
                              window: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = ZStack(alignment: .topLeading) {
            if window {
                Color(nsColor: .windowBackgroundColor)
            } else {
                LinearGradient(colors: dark ? [Color(white: 0.16), Color(red: 0.12, green: 0.14, blue: 0.24)]
                                            : [Color(red: 0.76, green: 0.84, blue: 0.95), Color(white: 0.93)],
                               startPoint: .top, endPoint: .bottom)
            }
            view
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: staged)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: size)
        let proofWindow = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        proofWindow.appearance = appearance
        proofWindow.isReleasedWhenClosed = false
        proofWindow.contentView = hosting
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            proofWindow.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The fixture bar drawn: the band, the run, the mirror at its seat, the
/// dragged glyph under the pointer, the drag's revealed run, a note.
private struct BarProof: View {
    let state: MenuBarDragRenderProofTests.BarState
    let mirror: NSImage
    let mirrorWidth: CGFloat
    let dark: Bool

    private typealias Proof = MenuBarDragRenderProofTests
    private var ink: Color { dark ? .white : .black }

    private func x(_ quartz: CGFloat) -> CGFloat { quartz - Proof.origin }

    var body: some View {
        let seat = state.seat(mirrorWidth)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(dark ? Color.black.opacity(0.55) : Color.white.opacity(0.62))
                .frame(width: Proof.canvasWidth, height: Proof.barHeight)
            // The Screen Bar's band and the notch it wraps.
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                .fill(Color.black)
                .frame(width: Proof.clearOf - 531, height: Proof.barHeight)
                .offset(x: x(531))
            if let slot = state.slot {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: slot.width, height: 26)
                    .offset(x: x(slot.minX), y: 5.5)
            }
            ForEach(Array((state.revealed + state.run).enumerated()), id: \.offset) { _, item in
                if state.covered.contains(where: { $0.x == item.x }) {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: item.width, height: 22)
                        .offset(x: x(item.x), y: 7.5)
                } else {
                    glyph(item).offset(x: x(item.x), y: 6.5)
                }
            }
            Image(nsImage: mirror)
                .frame(width: mirrorWidth, height: MenuBarIconMirror.itemHeight)
                .offset(x: x(seat), y: 6.5)
            if let dragged = state.dragged, let pointer = state.pointerX {
                glyph(dragged)
                    .opacity(0.72)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: x(pointer) - dragged.width / 2, y: 8)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 17))
                    .foregroundStyle(.black)
                    .shadow(color: .white, radius: 0.5)
                    .offset(x: x(pointer) + 2, y: 16)
            }
            if let note = state.note {
                MenuBarBarView(model: noteModel(note), tiles: MenuBarLiveTiles(), onTrigger: { _ in },
                               onRevealItem: { _ in }, itemSection: { _ in .hidden }, onMoveItem: { _, _ in })
                    .frame(width: MenuBarBarLayout.noteSize(note).width, height: MenuBarBarLayout.noteHeight)
                    .background(RoundedRectangle(cornerRadius: MenuBarBarPanel.cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3))
                    .offset(x: x(seat + mirrorWidth / 2) - MenuBarBarLayout.noteSize(note).width / 2,
                            y: Proof.barHeight + MenuBarBarLayout.barGap)
            }
            Text(state.caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(x: 16, y: 118)
        }
        .frame(width: Proof.canvasWidth, height: 150, alignment: .topLeading)
    }

    private func noteModel(_ note: String) -> MenuBarBarModel {
        let model = MenuBarBarModel()
        model.note = note
        return model
    }

    private func glyph(_ item: MenuBarDragRenderProofTests.BarItem) -> some View {
        HStack(spacing: 3) {
            if let symbol = item.symbol {
                Image(systemName: symbol).font(.system(size: 13.5, weight: .medium))
            }
            if let text = item.text {
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(ink)
        .frame(width: item.width, height: 24)
    }
}

/// The empty run's hint as the icon's menu shows it.
private struct HintMenuProof: View {
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hint)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            Divider().padding(.horizontal, 6)
            Text("Open Item Bar")
                .padding(.horizontal, 12)
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3))
        .padding(24)
    }
}
