import AppKit
import Foundation
import JRBarCore
import JRBarLEDS
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

/// Render proof for seasonal touches: every set on every surface — the
/// closed notch with its Screen Bar, the open card, the tank, the buddy
/// across all ten bodies, and the Settings header — in light and dark,
/// plus the Settings section and the tank resting on battery. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write `seasonal-*.png` into
/// `JRBAR_RENDER_PROOF_DIR`. Synthetic sessions, calendars and people only.
@Suite("Seasonal render proof", .serialized, .temporaryDirectory)
@MainActor
struct SeasonalRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The occasion each proof dresses for: Hanukkah's fifth night,
    /// Kwanzaa's fourth day, a tagged friend's birthday.
    static func occasion(_ holiday: SeasonalHoliday) -> SeasonalOccasion {
        switch holiday {
        case .hanukkah: return SeasonalOccasion(holiday: holiday, day: 5)
        case .kwanzaa: return SeasonalOccasion(holiday: holiday, day: 4)
        case .ramadanEid: return SeasonalOccasion(holiday: holiday, day: 12, phase: .ramadan)
        case .birthday: return SeasonalOccasion(holiday: holiday, name: "Alex Rivera")
        default: return SeasonalOccasion(holiday: holiday)
        }
    }

    /// Every set, and Eid as Ramadan's second face.
    static var cases: [(name: String, occasion: SeasonalOccasion)] {
        var all = SeasonalHoliday.allCases.map { ($0.rawValue, occasion($0)) }
        all.append(("eid", SeasonalOccasion(holiday: .ramadanEid, day: 1, phase: .eid)))
        return all
    }

    private static let schemes: [(name: String, dark: Bool)] = [("dark", true), ("light", false)]

    // MARK: The closed notch and its Screen Bar

    /// The real Screen Bar, coupled under an island at `island` (view
    /// coordinates, y up) in a canvas of `size`, lit with a gradient.
    static func screenBar(size: CGSize, island: CGRect, notchWidth: CGFloat, depth: CGFloat) -> ScreenBarView {
        let bar = ScreenBarView(frame: CGRect(origin: .zero, size: size))
        bar.earRecoveryReduceMotionOverride = true
        bar.updateLayout {
            bar.notchCornerRadius = 8
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: notchWidth, notchDepth: depth,
                                                    bandSpan: size.width, leftExtent: 0, rightExtent: 0)
            bar.islandFrame = island
        }
        bar.relayout()
        let colours = (0..<12).map { i -> RGB in
            let t = Double(i) / 11
            return RGB(r: 0.98 - 0.68 * t, g: 0.55 + 0.2 * t, b: 0.3 + 0.7 * t)
        }
        bar.display(colors: colours)
        return bar
    }

    /// An AppKit view inside a SwiftUI proof scene.
    struct Hosted: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @Test(.enabled(if: enabled)) func closedNotch() throws {
        let (toy, store, _) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let depth = max(toy.notchDepth, 32)
        let idle = toy.idleLayout
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let islandWidth = slot + 2 * idle.windowShoulder
        let canvas = CGSize(width: 520, height: 96)
        let island = CGRect(x: (canvas.width - islandWidth) / 2, y: canvas.height - depth,
                            width: islandWidth, height: depth)
        for (name, occasion) in Self.cases {
            for scheme in Self.schemes {
                let bar = Self.screenBar(size: canvas, island: island, notchWidth: slot, depth: depth)
                // The garland's window, as the overlay places it from the
                // band's own rect.
                let frame = try #require(SeasonalBandOverlay.frame(strip: bar.bandRect, island: island,
                                                                   notchDepth: depth))
                let cap = ScreenBarGeometry.bandCapRadius(bar.bandRect)
                let scene = NotchSurfaceRenderProofTests.scene(
                    NotchIslandView(toy: toy), size: CGSize(width: islandWidth, height: depth), depth: depth,
                    canvas: canvas, dark: scheme.dark)
                let dressed = ZStack(alignment: .topLeading) {
                    scene
                    Hosted(view: bar).frame(width: canvas.width, height: canvas.height)
                    SeasonalGarland(occasion: occasion, capRadius: cap)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: canvas.height - frame.maxY)
                }
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                try ProofRender.write(dressed, size: canvas, name: "seasonal-\(name)-closed-\(scheme.name)",
                                      dark: scheme.dark, settle: 0.1)
            }
        }
    }

    // MARK: The open card

    @Test(.enabled(if: enabled)) func openCard() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        NotchSurfaceRenderProofTests.fill(model, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(model) }
        model.show(.now)
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let width = NotchIslandLayout.expandedWidth(slotWidth: slot)
        let topPad = toy.cardTopPad
        model.seasonalIsland = { SeasonalIslandMetrics(notchWidth: slot, notchDepth: depth, restingRadius: 8,
                                                       topPad: topPad) }
        for (name, occasion) in Self.cases {
            model.seasonalOccasion = { occasion }
            let card = NotchCardView(model: model, style: .island, width: width)
            let probe = NSHostingView(rootView: card)
            probe.layoutSubtreeIfNeeded()
            let height = topPad + ceil(probe.fittingSize.height)
            let canvas = CGSize(width: width + 140, height: height + 40)
            let island = CGRect(x: (canvas.width - width) / 2, y: canvas.height - height, width: width, height: height)
            for scheme in Self.schemes {
                let bar = Self.screenBar(size: canvas, island: island, notchWidth: slot, depth: depth)
                let face = ZStack(alignment: .top) {
                    NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
                    card.padding(.top, topPad)
                }
                let scene = ZStack(alignment: .topLeading) {
                    NotchSurfaceRenderProofTests.scene(face, size: CGSize(width: width, height: height),
                                                       depth: depth, canvas: canvas, dark: scheme.dark)
                    Hosted(view: bar).frame(width: canvas.width, height: canvas.height)
                }
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                try ProofRender.write(scene, size: canvas, name: "seasonal-\(name)-card-\(scheme.name)",
                                      dark: scheme.dark)
            }
        }
        model.seasonalOccasion = { nil }
    }

    // MARK: The tank

    @Test(.enabled(if: enabled)) func tank() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cast = [
            Fish(id: "a", label: "review-patch", providerID: "claude", state: .swimming, lane: 0.35, speed: 0.08,
                 direction: 1, stateSince: now.addingTimeInterval(-100), enteredAt: .distantPast, species: .clownfish),
            Fish(id: "b", label: "ship-it", providerID: "codex", state: .swimming, lane: 0.55, speed: 0.08,
                 direction: -1, stateSince: now.addingTimeInterval(-100), enteredAt: .distantPast, species: .angelfish),
        ]
        for (name, occasion) in Self.cases {
            for scheme in Self.schemes {
                let tank = AquariumView(fixture: .init(fish: cast, showLabels: false, night: scheme.dark ? 0.85 : 0,
                                                       visualTime: 40, season: occasion))
                try ProofRender.write(tank.frame(width: 900, height: 520), size: CGSize(width: 900, height: 520),
                                      name: "seasonal-\(name)-tank-\(scheme.name)", dark: scheme.dark,
                                      scale: 1.5, settle: 0.2)
            }
        }
    }

    // MARK: The buddy

    @Test(.enabled(if: enabled)) func buddy() throws {
        for (name, occasion) in Self.cases {
            for scheme in Self.schemes {
                let row = HStack(spacing: 10) {
                    ForEach(BuddyCharacter.allCases, id: \.self) { character in
                        VStack(spacing: 4) {
                            BuddyFigure(character: character, mood: .pacing, tint: .accentColor, phase: 2.35,
                                        hopProgress: nil, waveAge: nil, slumpAge: nil, leans: false, still: true,
                                        askCount: 0, care: .content, trick: nil, treatAge: nil, crumbAge: nil,
                                        season: occasion.holiday)
                                .frame(width: 30, height: 26)
                                .scaleEffect(3)
                                .frame(width: 96, height: 86)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(scheme.dark ? Color(white: 0.14) : Color.white))
                            Text(character.displayName).font(.system(size: 11))
                                .foregroundStyle(scheme.dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                        }
                    }
                }
                .padding(14)
                .background(scheme.dark ? Color(white: 0.07) : Color(white: 0.93))
                try ProofRender.write(row, size: CGSize(width: 1100, height: 140),
                                      name: "seasonal-\(name)-buddy-\(scheme.name)", dark: scheme.dark, settle: 0.05)
            }
        }
    }

    // MARK: Settings

    @Test(.enabled(if: enabled)) func settingsHeader() throws {
        for (name, occasion) in Self.cases {
            for scheme in Self.schemes {
                let header = SettingsPageHeader(page: .utilities)
                    .overlay(alignment: .topLeading) {
                        SeasonalAccent(holiday: occasion.holiday, day: occasion.day, size: 18)
                            .offset(x: SettingsMetrics.headerTile - 9, y: -5)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(header, size: CGSize(width: 420, height: 90),
                                      name: "seasonal-\(name)-settings-\(scheme.name)", dark: scheme.dark, settle: 0.05)
            }
        }
    }

    @Test(.enabled(if: enabled)) func settingsSection() throws {
        let core = CoreModel()
        let source = SeasonalSource(calendarAccess: { .granted }, read: { _, _ in SeasonalReading() })
        let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              nativeSourcesEnabled: false, aquariumSave: AquariumToy.scratchSave(),
                              seasonalSource: source)
        defer { owner.shutdown() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let halloween = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
        owner.seasonal.clock = { halloween }
        owner.state.seasonal.enabled = true
        owner.state.seasonal.set(.hanukkah, on: false)
        let day = calendar.startOfDay(for: halloween).addingTimeInterval(86_400 * 3)
        owner.seasonal.apply(SeasonalReading(entries: [
            SeasonalCalendarEntry(title: "Alex Rivera’s Birthday", start: day, end: day.addingTimeInterval(86_400),
                                  isBirthday: true, contactID: "alex"),
            SeasonalCalendarEntry(title: "Sam Lee’s Birthday", start: day.addingTimeInterval(86_400 * 9),
                                  end: day.addingTimeInterval(86_400 * 10), isBirthday: true, contactID: "sam"),
        ], holidayCalendars: 1))
        owner.state.seasonal.celebrated = [SeasonalPerson(id: "alex", name: "Alex Rivera")]
        for scheme in Self.schemes {
            let page = Form {
                SettingsPageHeader(page: .utilities)
                    .overlay(alignment: .topLeading) {
                        SeasonalAccent(holiday: .halloween, size: 18).offset(x: SettingsMetrics.headerTile - 9, y: -5)
                    }
                SeasonalSettingsSection(toys: owner)
            }
            .formStyle(.grouped)
            try ProofRender.write(page, size: CGSize(width: 720, height: 1700),
                                  name: "seasonal-settings-section-\(scheme.name)", dark: scheme.dark, settle: 0.1)
        }
    }

    // MARK: Battery

    @Test(.enabled(if: enabled)) func batteryRest() throws {
        let core = CoreModel()
        let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              nativeSourcesEnabled: false, aquariumSave: AquariumToy.scratchSave())
        defer { owner.shutdown() }
        let tank = try #require(owner.aquarium)
        owner.state.aquarium.enabled = true
        tank.power = { PowerPolicy(onBattery: true) }
        for scheme in Self.schemes {
            let card = Form {
                HStack {
                    Text("Aquarium").jrbarType(.headline)
                    StatusBadge(tank.status.text, tint: tank.status.tint)
                }
                AquariumControlsView(toy: tank)
                if let cost = tank.cost(at: 0) { Text(cost).jrbarType(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            try ProofRender.write(card, size: CGSize(width: 720, height: 760),
                                  name: "t2-battery-rest-card-\(scheme.name)", dark: scheme.dark)
            let chips = VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<3) { index in
                    let status = AquariumToy.closedStatus(wallpaper: index == 0 ? "Display" : nil, connected: ["Display"],
                                                          saverMinutes: index == 1 ? 10 : 0, resting: true)
                    StatusBadge(status.text, tint: status.tint)
                }
                StatusBadge(tank.status.text, tint: tank.status.tint)
            }.padding(20).background(Color(nsColor: .windowBackgroundColor))
            try ProofRender.write(chips, size: CGSize(width: 580, height: 200),
                                  name: "t2-battery-rest-chips-\(scheme.name)", dark: scheme.dark)
        }
        tank.power = { .normal }
    }
}
