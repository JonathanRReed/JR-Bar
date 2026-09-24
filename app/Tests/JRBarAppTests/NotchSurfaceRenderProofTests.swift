import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
import JRBarLEDS
import JRBarUI
@testable import JRBarApp

/// Render proof for every face the notch shows a person: the resting
/// island, each notice capsule, the level HUD, the ask and the meeting,
/// the grown card on both pages, the glass card in light and dark, and
/// the HUD's fallback pill. Each face renders through the native
/// `NSHostingView` path (ImageRenderer draws a placeholder for the
/// card's scroll view) over a desktop and a menu bar, so a human can
/// judge it the way it sits under the real notch. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write `notch-*.png` into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Notch surfaces render proof")
@MainActor
struct NotchSurfaceRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    // MARK: Fixtures

    private static let now = Date().timeIntervalSince1970

    private static func sessions() -> CoreState {
        let ask = CoreAsk(session: "claude:ask", openedAt: now - 190,
                          summary: "Run the migration against the staging database?",
                          answerable: true, request: "r1",
                          preview: "make migrate ENV=staging")
        return CoreState(
            sessions: [
                CoreSession(id: "claude:1", provider: "claude", label: "review-patch", mode: "working"),
                CoreSession(id: "codex:1", provider: "codex", label: "ship-it", mode: "working"),
                CoreSession(id: "gemini:1", provider: "gemini", label: "long-think", mode: "working"),
                CoreSession(id: "claude:ask", provider: "claude", label: "rename-the-fish",
                            ask: ask),
            ],
            asks: [ask])
    }

    private static func makeToy(state: CoreState? = sessions())
        -> (NotchToy, ToysStore, ProofMonitor) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        toys.notch.meetingAlerts = true
        toys.notch.mirror = true
        let core = CoreModel()
        if let state { core.apply(.state(state)) }
        let monitor = ProofMonitor()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: proofCardModel(monitor),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        // The line never times anything out while a proof looks at it.
        toy.capsuleTimer = { _, _ in }
        let desk = AskAnswerDesk(send: { _, _, _ in CoreReply(id: "1", ok: true) })
        toy.cardModel.askDesk = { desk }
        return (toy, store, monitor)
    }

    /// A card model whose Now Playing reader is a hand-driven feed.
    private static func proofCardModel(_ monitor: ProofMonitor) -> NotchCardModel {
        NotchCardModel(
            timers: ShelfTimerModel(storeURL: URL(fileURLWithPath:
                NSTemporaryDirectory() + "jrbar-proof-timers-\(UUID().uuidString).json")),
            tray: ShelfTrayModel(),
            utility: ShelfUtilityModel(feed: MediaFeed(monitor: monitor)),
            runtimeEnabled: false)
    }

    /// A monitor that never spawns the helper; the proof hands it media.
    final class ProofMonitor: AlcoveMediaMonitor {
        override func start() { markRunning(true) }
        override func stop() { markRunning(false) }
    }

    /// A square of album art — a dusk gradient with a sun, so the tint
    /// the row reads off it is a real colour.
    static func artwork() -> Data {
        let size = 120
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let gradient = NSGradient(colors: [
            NSColor(red: 0.98, green: 0.45, blue: 0.35, alpha: 1),
            NSColor(red: 0.55, green: 0.18, blue: 0.55, alpha: 1),
            NSColor(red: 0.12, green: 0.10, blue: 0.32, alpha: 1),
        ])
        gradient?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
        NSColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 38, y: 40, width: 44, height: 44)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func media(playing: Bool = true) -> AlcoveMedia {
        AlcoveMedia(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                    playing: playing, artworkData: artwork(), bundleIdentifier: "com.apple.Music",
                    duration: 243, elapsed: 97, timestamp: Date().timeIntervalSince1970)
    }

    // MARK: Scene

    /// The hardware the island sits on: the slot and depth of the Mac
    /// running the proof, or a 14-inch MacBook Pro's.
    static var slotWidth: CGFloat {
        ScreenBarGeometry.preferredScreen().flatMap { ScreenBarGeometry.islandSlot(on: $0) }?.width ?? 185
    }

    /// A desktop, the menu bar across its top and the island hung from
    /// the notch at `size`.
    static func scene<V: View>(_ island: V, size: CGSize, depth: CGFloat,
                               canvas: CGSize, dark: Bool = true) -> some View {
        ZStack(alignment: .top) {
            ProofDesktop(dark: dark)
            Rectangle()
                .fill(dark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
                .frame(height: depth)
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                .fill(.black)
                .frame(width: slotWidth, height: depth)
            island.frame(width: size.width, height: size.height)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: Proofs

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func islandFaces() throws {
        let (toy, store, _) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let depth = max(toy.notchDepth, 32)
        let canvas = CGSize(width: 520, height: 150)

        // Resting: working dots on the left, the ask on the right.
        let idle = toy.idleLayout
        try ProofRender.write(Self.scene(NotchIslandView(toy: toy),
                                         size: CGSize(width: Self.slotWidth + 2 * idle.windowShoulder,
                                                      height: depth),
                                         depth: depth, canvas: CGSize(width: 520, height: 70)),
                              size: CGSize(width: 520, height: 70), name: "notch-idle-agents")

        // Resting with the track up: no asks, media in the right shoulder.
        let (quiet, quietStore, _) = Self.makeToy(state: CoreState(sessions: [
            CoreSession(id: "claude:1", provider: "claude", label: "review-patch", mode: "working"),
        ]))
        defer { withExtendedLifetime(quietStore) {} }
        quiet.noteMedia(Self.media())
        let media = quiet.idleLayout
        try ProofRender.write(Self.scene(NotchIslandView(toy: quiet),
                                         size: CGSize(width: Self.slotWidth + 2 * media.windowShoulder,
                                                      height: depth),
                                         depth: depth, canvas: CGSize(width: 520, height: 70)),
                              size: CGSize(width: 520, height: 70), name: "notch-idle-media")

        // Every one-line notice.
        let notices: [(String, AlcoveNotice)] = [
            ("completed", AlcoveNotice(id: "c", kind: .completed, title: "Claude · review-patch",
                                       subtitle: "finished", provider: "claude", key: "c")),
            ("failed", AlcoveNotice(id: "f", kind: .failed, title: "Codex · ship-it",
                                    subtitle: "failed", provider: "codex", key: "f")),
            ("quota", AlcoveNotice(id: "q", kind: .quotaReset, title: "Claude 5h",
                                   subtitle: "quota reset", provider: "claude", key: "q")),
            ("charging", AlcoveNotice(id: "p", kind: .charging, title: "Charging",
                                      subtitle: "84%", key: "p")),
            ("timer", AlcoveNotice(id: "t", kind: .timer, title: "Tea",
                                   subtitle: "done", key: "t")),
            ("focus", NotchAnnouncements.focusNotice(name: "Work", on: true)),
            ("device", AlcoveNotice(id: "d", kind: .device, title: "AirPods Pro",
                                    subtitle: "connected", key: "d", glyph: "airpodspro")),
            ("capslock", NotchAnnouncements.capsLockNotice(on: true)),
            ("display", NotchAnnouncements.displayNotice(connected: true)),
        ]
        let noticeSize = NotchIslandLayout.noticeSize(slotWidth: Self.slotWidth, notchDepth: depth)
        for (name, notice) in notices {
            toy.activeCapsule = notice
            try ProofRender.write(Self.scene(NotchIslandView(toy: toy), size: noticeSize,
                                             depth: depth, canvas: CGSize(width: 520, height: 90)),
                                  size: CGSize(width: 520, height: 90), name: "notch-notice-\(name)")
        }
        toy.activeCapsule = nil

        // The level HUD, each key.
        let levels: [(String, AlcoveNotice)] = [
            ("volume", AlcoveNotice(id: "v", kind: .level, title: "Volume", subtitle: "", key: "v",
                                    glyph: "speaker.wave.3.fill", fraction: 0.62)),
            ("muted", AlcoveNotice(id: "m", kind: .level, title: "Volume", subtitle: "", key: "m",
                                   glyph: "speaker.slash.fill", fraction: 0.62, muted: true)),
            ("brightness", AlcoveNotice(id: "b", kind: .level, title: "Brightness", subtitle: "", key: "b",
                                        glyph: "sun.max.fill", fraction: 0.85)),
            ("keyboard", AlcoveNotice(id: "k", kind: .level, title: "Keyboard", subtitle: "", key: "k",
                                      glyph: "light.max", fraction: 0.3)),
            ("timer-drag", AlcoveNotice(id: "td", kind: .level, title: "Timer", subtitle: "25 min", key: "td",
                                        glyph: "timer", fraction: 0.42)),
        ]
        for (name, notice) in levels {
            toy.activeOverlay = notice
            try ProofRender.write(Self.scene(NotchIslandView(toy: toy), size: noticeSize,
                                             depth: depth, canvas: CGSize(width: 520, height: 90)),
                                  size: CGSize(width: 520, height: 90), name: "notch-level-\(name)")
        }
        toy.activeOverlay = nil
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func askFaces() throws {
        let (toy, store, _) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let depth = max(toy.notchDepth, 32)
        let ask = CoreAsk(session: "claude:ask", openedAt: Self.now - 190,
                          summary: "Run the migration against the staging database?",
                          answerable: true, request: "r1", preview: "make migrate ENV=staging")
        for takeover in [false, true] {
            let notice = AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish",
                                      subtitle: "needs you", provider: "claude", session: "claude:ask",
                                      key: "ask:claude:ask|r1", ask: ask, takeover: takeover)
            toy.activeCapsule = notice
            let size = NotchIslandLayout.askSize(slotWidth: Self.slotWidth, notchDepth: depth,
                                                 summaryLines: toy.askSummaryLines, takeover: takeover,
                                                 underHousing: nil)
            try ProofRender.write(Self.scene(NotchIslandView(toy: toy), size: size, depth: depth,
                                             canvas: CGSize(width: 520, height: size.height + 30)),
                                  size: CGSize(width: 520, height: size.height + 30),
                                  name: takeover ? "notch-ask-takeover" : "notch-ask")
        }
        toy.activeCapsule = nil
        toy.noteMeetingSoon(ShelfCalendarModel.Event(
            title: "Design review", start: Date().addingTimeInterval(120),
            end: Date().addingTimeInterval(1920), url: URL(string: "https://meet.example.com/abc")))
        let size = NotchIslandLayout.askSize(slotWidth: Self.slotWidth, notchDepth: depth,
                                             summaryLines: 1, takeover: false, underHousing: nil)
        try ProofRender.write(Self.scene(NotchIslandView(toy: toy), size: size, depth: depth,
                                         canvas: CGSize(width: 520, height: size.height + 30)),
                              size: CGSize(width: 520, height: size.height + 30), name: "notch-meeting")
    }

    /// The faces as Jonathan runs them: the Screen Bar up, its housing
    /// coupled under the island and climbing its bottom corners. The
    /// island renders at its housed size, then the bar's own view is
    /// composited over it, as the desktop orders the two windows.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func housedFaces() throws {
        let (toy, store, _) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.screenBarShown = { true }
        let depth = max(toy.notchDepth, 32)
        let corner = toy.notchCornerRadius
        let ask = CoreAsk(session: "claude:ask", openedAt: Self.now - 190,
                          summary: "Run the migration against the staging database?",
                          answerable: true, request: "r1", preview: "make migrate ENV=staging")
        let faces: [(String, AlcoveNotice, Bool)] = [
            ("completed", AlcoveNotice(id: "c", kind: .completed, title: "Claude · review-patch",
                                       subtitle: "finished", provider: "claude", key: "c"), false),
            ("volume", AlcoveNotice(id: "v", kind: .level, title: "Volume", subtitle: "", key: "v",
                                    glyph: "speaker.wave.3.fill", fraction: 0.62), true),
            ("ask", AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish",
                                 subtitle: "needs you", provider: "claude", session: "claude:ask",
                                 key: "ask:claude:ask|r1", ask: ask), false),
        ]
        for (name, notice, overlay) in faces {
            if overlay { toy.activeOverlay = notice } else { toy.activeCapsule = notice }
            let size = notice.kind.hasVerbs
                ? NotchIslandLayout.askSize(slotWidth: Self.slotWidth, notchDepth: depth,
                                            summaryLines: 1, takeover: false, underHousing: corner)
                : NotchIslandLayout.noticeSize(slotWidth: Self.slotWidth, notchDepth: depth,
                                               underHousing: corner)
            let canvas = CGSize(width: 520, height: size.height + ScreenBarDesign.bandHeight
                                + ScreenBarGeometry.coupledChin + ScreenBarGeometry.coupledSlack + 30)
            let islandFrame = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
                                     width: size.width, height: size.height)
            let scene = ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                Rectangle().fill(Color.black.opacity(0.22)).frame(height: depth)
                NotchIslandView(toy: toy).frame(width: size.width, height: size.height)
            }
            .frame(width: canvas.width, height: canvas.height)
            let bar = ScreenBarView(frame: CGRect(origin: .zero, size: canvas))
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: Self.slotWidth, notchDepth: depth,
                                                     bandSpan: size.width, leftExtent: 40, rightExtent: 40)
            bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "claude"),
                                       right: ScreenBarWingSlot(text: "Codex", provider: "codex"))
            bar.notchCornerRadius = corner
            bar.islandFrame = islandFrame
            bar.relayout()
            bar.display(colors: Array(repeating: RGB(r: 0.25, g: 0.65, b: 1), count: 8))
            try ProofRender.write(scene, size: canvas, name: "notch-housed-\(name)", overlay: bar)
            toy.activeCapsule = nil
            toy.activeOverlay = nil
        }
    }

    /// The grown card on black, both pages, fed like a real afternoon.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func grownCard() throws {
        let (toy, store, monitor) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        Self.fill(model, monitor: monitor)
        defer { Self.clearTray(model) }
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: Self.slotWidth)
        for page in [NotchCardModel.Page.now, .shelf] {
            model.show(page)
            let card = NotchCardView(model: model, style: .island, width: width)
            let probe = NSHostingView(rootView: card)
            probe.layoutSubtreeIfNeeded()
            let height = toy.cardTopPad + ceil(probe.fittingSize.height)
            let island = ZStack(alignment: .top) {
                NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
                card.padding(.top, toy.cardTopPad)
            }
            let canvas = CGSize(width: width + 140, height: height + 40)
            try ProofRender.write(Self.scene(island, size: CGSize(width: width, height: height),
                                             depth: depth, canvas: canvas),
                                  size: canvas, name: "notch-card-\(page == .now ? "now" : "shelf")")
        }
    }

    /// The shelf page's day rows with something in them — the weather,
    /// the calendar with a joinable meeting, reminders, synced lyrics —
    /// on the island's black and on glass in both appearances.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func dayRows() throws {
        let (toy, store, monitor) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        Self.fill(model, monitor: monitor)
        defer { Self.clearTray(model) }
        let now = Date()
        let reading = NotchWeather.Reading(celsius: 21.4, code: 2, place: "Austin", fahrenheit: true,
                                           highCelsius: 27, lowCelsius: 16, rainInMinutes: 40)
        let events = ShelfCalendarModel.State.events([
            ShelfCalendarModel.Event(title: "Design review", start: now.addingTimeInterval(600),
                                     end: now.addingTimeInterval(2400),
                                     url: URL(string: "https://meet.example.com/abc")),
            ShelfCalendarModel.Event(title: "1:1 with Sam", start: now.addingTimeInterval(7200),
                                     end: now.addingTimeInterval(9000), url: nil),
        ])
        let reminders = ShelfRemindersModel.State.items([
            ShelfRemindersModel.Entry(id: "1", title: "Ship the notch pass", due: now.addingTimeInterval(-600)),
            ShelfRemindersModel.Entry(id: "2", title: "Call the vet", due: now.addingTimeInterval(5400)),
            ShelfRemindersModel.Entry(id: "3", title: "Water the plants", due: nil),
        ])
        let lyrics = SyncedLyrics.parse("""
            [01:30.00]Waiting in a car
            [01:37.00]Waiting for a ride in the dark
            [01:42.00]The night city grows
            """)
        let width = NotchIslandLayout.expandedWidth(slotWidth: Self.slotWidth)
        for (name, cardStyle, dark) in [("island", NotchCardStyle.island, true),
                                        ("glass-light", NotchCardStyle.glass, false),
                                        ("glass-dark", NotchCardStyle.glass, true)] {
            let rows = VStack(alignment: .leading, spacing: NotchCardView.runSpacing) {
                ShelfWeatherRow(reading: reading, style: cardStyle)
                ShelfCalendarRow(calendar: model.calendar, state: events, style: cardStyle)
                ShelfRemindersRow(reminders: model.reminders, state: reminders, style: cardStyle)
                LyricLines(lyrics: lyrics, utility: model.utility, playing: true, style: cardStyle)
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            let probe = NSHostingView(rootView: rows)
            probe.layoutSubtreeIfNeeded()
            let size = CGSize(width: width + 40, height: ceil(probe.fittingSize.height) + 40)
            let view = ZStack {
                ProofDesktop(dark: dark)
                if cardStyle == .island {
                    rows.background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black))
                } else {
                    rows.background(ProofGlass(cornerRadius: NotchCardPanel.cornerRadius))
                }
            }
            try ProofRender.write(view.frame(width: size.width, height: size.height), size: size,
                                  name: "notch-day-\(name)", dark: dark)
        }
    }

    /// The quiet states: a card with nothing on it but the idle header,
    /// the wing hint up, and the glass peek — the header alone.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func quietCard() throws {
        let (toy, store, _) = Self.makeToy(state: CoreState(sessions: []))
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        model.pinned = true
        model.wingHint = true
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: Self.slotWidth)
        let card = NotchCardView(model: model, style: .island, width: width)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let island = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
            card.padding(.top, toy.cardTopPad)
        }
        let canvas = CGSize(width: width + 140, height: height + 40)
        try ProofRender.write(Self.scene(island, size: CGSize(width: width, height: height),
                                         depth: depth, canvas: canvas),
                              size: canvas, name: "notch-card-quiet")

        model.pinned = false
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "codex"), label: "ship-it",
                                     word: "Working", clickSession: "codex:1",
                                     explanation: "Running the test suite")
        for dark in [false, true] {
            let peek = NotchCardView(model: model, style: .glass)
            let view = ZStack {
                ProofDesktop(dark: dark)
                peek.background(ProofGlass(cornerRadius: NotchCardPanel.cornerRadius))
            }
            try ProofRender.write(view.frame(width: 360, height: 110), size: CGSize(width: 360, height: 110),
                                  name: "notch-glass-peek-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The glass card — the fallback surface — in both appearances.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func glassCard() throws {
        let (toy, store, monitor) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        Self.fill(model, monitor: monitor)
        defer { Self.clearTray(model) }
        for dark in [false, true] {
            for page in [NotchCardModel.Page.now, .shelf] {
                model.show(page)
                let card = NotchCardView(model: model, style: .glass)
                let probe = NSHostingView(rootView: card)
                probe.layoutSubtreeIfNeeded()
                let size = probe.fittingSize
                let view = ZStack {
                    ProofDesktop(dark: dark)
                    card
                        .background(ProofGlass(cornerRadius: NotchCardPanel.cornerRadius))
                }
                let canvas = CGSize(width: size.width + 80, height: size.height + 60)
                try ProofRender.write(view.frame(width: canvas.width, height: canvas.height),
                                      size: canvas,
                                      name: "notch-glass-\(page == .now ? "now" : "shelf")-\(dark ? "dark" : "light")",
                                      dark: dark)
            }
        }
    }

    /// The HUD's fallback pill: a toast and the level, both appearances.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func hudPill() throws {
        for dark in [false, true] {
            let cases: [(String, NotchHUDModel)] = [
                ("toast", {
                    let m = NotchHUDModel()
                    m.toastActive = true
                    m.text = "SidePulse connected"
                    m.symbol = "cable.connector"
                    return m
                }()),
                ("meter", {
                    let m = NotchHUDModel()
                    m.toastActive = true
                    m.meter = NotchHUDModel.Meter(symbol: "speaker.wave.3.fill", fraction: 0.62)
                    return m
                }()),
                ("muted", {
                    let m = NotchHUDModel()
                    m.toastActive = true
                    m.meter = NotchHUDModel.Meter(symbol: "speaker.slash.fill", fraction: 0.4, muted: true)
                    return m
                }()),
            ]
            for (name, model) in cases {
                let view = ZStack {
                    ProofDesktop(dark: dark)
                    NotchHUDView(model: model)
                        .background(ProofGlass(cornerRadius: 16, hud: true))
                }
                try ProofRender.write(view.frame(width: 300, height: 80), size: CGSize(width: 300, height: 80),
                                      name: "notch-hud-\(name)-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    /// The toy cards' disclosure bodies this lane draws — Fold, the
    /// Notch Buddy and Confetti — on a settings-card ground in both
    /// appearances, through the native path so the real controls draw.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func toyCards() throws {
        let (_, store, _) = Self.makeToy()
        defer { withExtendedLifetime(store) {} }
        var cards: [(String, AnyView)] = [
            ("buddy", store.notchBuddy.controls),
            ("confetti", store.confetti.controls),
        ]
        if let fold = store.fold { cards.append(("fold", fold.controls)) }
        for dark in [false, true] {
            for (name, controls) in cards {
                // The Toys page is a grouped form; a card's body is one
                // row of its section.
                let probe = NSHostingView(rootView: controls.frame(width: 560))
                probe.layoutSubtreeIfNeeded()
                let height = ceil(probe.fittingSize.height) + 90
                let view = Form { Section { controls } }
                    .formStyle(.grouped)
                    .frame(width: 640, height: height)
                try ProofRender.write(view, size: CGSize(width: 640, height: height),
                                      name: "card-\(name)-\(dark ? "dark" : "light")", dark: dark)
            }
        }
        // The Fold card's lid at a few angles, the fold zone swept out.
        let lids = HStack(spacing: 12) {
            ForEach([nil, 40.0, 100.0, 135.0] as [Double?], id: \.self) { angle in
                FoldLidGlyph(angle: angle, activation: 65)
                    .frame(width: 118, height: 70)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(16)
        for dark in [false, true] {
            try ProofRender.write(lids.background(Color(nsColor: .windowBackgroundColor)),
                                  size: CGSize(width: 620, height: 126),
                                  name: "card-fold-lids-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The buddy's pal card, both appearances, a well-kept friendship.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func palCard() throws {
        var care = BuddyCare()
        let start = Date().addingTimeInterval(-86400 * 40)
        care.pet(at: start)
        for day in 0..<30 { care.feed(at: start.addingTimeInterval(Double(day) * 86400)) }
        care.eat(at: Date(), count: 120, provider: "claude")
        care.noteAsk(lasted: 1260)
        let card = BuddyPalCard.make(care: care)
        for dark in [false, true] {
            let view = ZStack {
                ProofDesktop(dark: dark)
                BuddyCardView(character: .cat, name: "Miso", card: card)
                    .background(ProofGlass(cornerRadius: 14))
            }
            try ProofRender.write(view.frame(width: 320, height: 280), size: CGSize(width: 320, height: 280),
                                  name: "buddy-pal-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The tray persists its paths in the test runner's defaults; a
    /// proof leaves it as it found it.
    static func clearTray(_ model: NotchCardModel) {
        for entry in model.tray.entries { model.tray.remove(entry) }
    }

    /// A card with something on every row: the focus, three sessions
    /// (one asking), two meters, the track, two timers and the tray.
    static func fill(_ model: NotchCardModel, monitor: ProofMonitor) {
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "review-patch",
                                     word: "Working", clickSession: "claude:1",
                                     explanation: "Editing AquariumView.swift")
        let ask = CoreAsk(session: "claude:ask", openedAt: now - 190,
                          summary: "Run the migration against staging?",
                          answerable: true, request: "r1", preview: "make migrate ENV=staging")
        model.rows = [
            NotchIslandRow(id: "claude:ask", label: "rename-the-fish", provider: "claude",
                           activity: .waiting, ask: ask),
            NotchIslandRow(id: "codex:1", label: "ship-it", provider: "codex", activity: .working),
            NotchIslandRow(id: "gemini:1", label: "long-think", provider: "gemini", activity: .failed),
        ]
        model.meters = [
            NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 42,
                             resetsAt: now + 3700, windowSpan: 18000),
            NotchIslandMeter(id: "codex", provider: "codex", window: "7d", percent: 71,
                             resetsAt: now + 86400 * 2, windowSpan: 604800),
        ]
        model.workingCount = 2
        model.pinned = true
        model.onOpenRow = { _ in }
        model.utility.start()
        monitor.onChange?(media())
        model.timers.add(label: "Tea", duration: 240)
        model.timers.add(label: "Standup", duration: 1500)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jrbar-proof-tray")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in ["Screenshot 2026-09-24.png", "notes.md", "design-review.pdf"] {
            let url = dir.appending(path: name)
            FileManager.default.createFile(atPath: url.path, contents: Data("proof".utf8))
            urls.append(url)
        }
        model.tray.add(urls)
    }
}

/// A desktop to sit the surfaces on: a macOS-26-ish wallpaper wash.
struct ProofDesktop: View {
    let dark: Bool

    var body: some View {
        LinearGradient(colors: dark
                       ? [Color(red: 0.10, green: 0.13, blue: 0.26), Color(red: 0.22, green: 0.16, blue: 0.34),
                          Color(red: 0.08, green: 0.22, blue: 0.30)]
                       : [Color(red: 0.62, green: 0.74, blue: 0.93), Color(red: 0.86, green: 0.78, blue: 0.92),
                          Color(red: 0.70, green: 0.88, blue: 0.90)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// What the glass reads as in a still frame: a frosted tint with a
/// hairline rim — `NSGlassEffectView` does not render offscreen.
struct ProofGlass: View {
    let cornerRadius: CGFloat
    var hud = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(scheme == .dark
                   ? Color(white: hud ? 0.12 : 0.16).opacity(0.82)
                   : Color(white: 0.97).opacity(0.78))
            .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.14 : 0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

/// The native render path the proofs share: an offscreen window hosts
/// the view so `onAppear`, state and timelines behave as on screen, the
/// run loop turns long enough for entrances to land, then the hosting
/// view caches its display into a bitmap at `scale`.
@MainActor
enum ProofRender {
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit", isDirectory: true)
    }

    static func write<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true,
                               scale: CGFloat = 2, settle: TimeInterval = 0.45,
                               overlay: NSView? = nil) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // A native view drawn over the scene — the Screen Bar's panel sits
        // above the island on the desktop.
        if let overlay {
            overlay.layoutSubtreeIfNeeded()
            let top = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            top.size = size
            overlay.cacheDisplay(in: overlay.bounds, to: top)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            top.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
