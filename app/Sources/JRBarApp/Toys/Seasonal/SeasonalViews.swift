import AppKit
import JRBarCore
import JRBarUI
import SwiftUI

/// The garland that hangs from the Screen Bar under the closed notch:
/// the set's string drooping across the band's width with its pieces
/// hung along it. A still drawing: it redraws when the day changes, not
/// on a clock.
struct SeasonalGarland: View {
    let occasion: SeasonalOccasion

    /// How far below the band the garland hangs, in points.
    static let hang: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            var c = context
            let inset = 3.0
            let piece = min(9.5, max(6.5, Double(size.height) * 0.5))
            let count = SeasonLook.count(for: Double(size.width) - inset * 2, holiday: occasion.holiday)
            SeasonLook.garland(&c, occasion, from: CGPoint(x: inset, y: 1), to: CGPoint(x: Double(size.width) - inset, y: 1),
                               sag: Double(size.height) * 0.16, count: count, size: piece, phase: 0.4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The open notch card's strip: under the Now · Shelf · Agent Overview
/// row, just above the Screen Bar, a garland across and the set's
/// centrepiece at the bottom right, with a word or two when there is
/// one to say ("Night 3", "Alex's birthday"). An overlay: the card's
/// layout and size don't change.
struct SeasonalCardStrip: View {
    let occasion: SeasonalOccasion

    /// The card's bottom corners: the centrepiece keeps inside their curve.
    static let cornerClearance: Double = 30

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let piece = min(26, Double(size.height) * 0.9)
            let centreX = Double(size.width) - Self.cornerClearance - piece * 0.45
            // A caption takes its room from the garland's end, never its
            // pieces: about six points a letter at the caption size.
            let captionRoom = occasion.caption.map { Double($0.count) * 6.4 + 10 } ?? 0
            ZStack(alignment: .bottomTrailing) {
                Canvas { context, canvasSize in
                    var c = context
                    let right = centreX - piece * 0.62 - 8 - captionRoom
                    let count = SeasonLook.count(for: right - 20, holiday: occasion.holiday)
                    SeasonLook.garland(&c, occasion, from: CGPoint(x: 20, y: 2), to: CGPoint(x: right, y: 2),
                                       sag: Double(canvasSize.height) * 0.12, count: count,
                                       size: min(9, Double(canvasSize.height) * 0.36), phase: 0.4)
                    let base = CGPoint(x: centreX, y: Double(canvasSize.height) - 7)
                    SeasonLook.centerpiece(&c, occasion, base: base, size: piece, phase: 0.4)
                }
                if let caption = occasion.caption {
                    // The island is black in both appearances; the ink
                    // goes inside the type style, which brings its own.
                    Text(caption)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .jrbarType(.caption)
                        .padding(.trailing, Double(size.width) - centreX + piece * 0.62 + 4)
                        .padding(.bottom, 8)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(occasion.caption ?? occasion.holiday.displayName)
    }
}

/// The small mark beside the Utilities & Toys header while a set is
/// on, and each holiday's icon in the Settings list.
struct SeasonalAccent: View {
    let holiday: SeasonalHoliday
    var day = 3
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvasSize in
            var c = context
            SeasonLook.accent(&c, holiday, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                              size: Double(min(canvasSize.width, canvasSize.height)), day: day)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The buddy's seasonal piece in the wardrobe's box (`SeasonOutfit`).
struct SeasonalOutfitPiece: View {
    let holiday: SeasonalHoliday

    var body: some View {
        Canvas { context, size in
            var c = context
            SeasonOutfit.draw(&c, holiday, in: CGRect(origin: .zero, size: size))
        }
        .frame(width: SeasonOutfit.box.width, height: SeasonOutfit.box.height)
        .allowsHitTesting(false)
    }
}

/// The header accent while a set is on: the Utilities & Toys tile wears
/// it at its top right.
struct SeasonalHeaderAccent: View {
    let store: SettingsStore

    var body: some View {
        if let occasion = store.toys?.seasonal.occasion {
            SeasonalAccent(holiday: occasion.holiday, day: occasion.day, size: 18)
                .offset(x: SettingsMetrics.headerTile - 9, y: -5)
                .help(occasion.caption.map { "\(occasion.holiday.displayName) · \($0)" } ?? occasion.holiday.displayName)
        }
    }
}

// MARK: Settings

/// Seasonal touches on the Toys page: the one switch, where the dates
/// come from, every holiday's own switch, and the birthdays.
struct SeasonalSettingsSection: View {
    let toys: ToysStore

    private var settings: SeasonalSettings { toys.state.seasonal }

    var body: some View {
        SettingGroup("Seasonal touches") {
            Toggle(isOn: Binding(get: { settings.enabled },
                                 set: { toys.state.seasonal.enabled = $0 })) {
                SettingLabel(title: "Seasonal touches",
                             subtitle: "On a holiday the notch, the tank and the buddy dress for it. Nothing runs and no calendar is read while this is off.")
            }
            if settings.enabled {
                Text(toys.seasonal.sourceLine)
                    .jrbarType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(SeasonalHoliday.allCases) { holiday in
                    holidayRow(holiday)
                }
                if settings.isOn(.birthday) { birthdays }
            }
        }
        .id(SettingsStore.groupAnchor("Seasonal touches"))
    }

    private func holidayRow(_ holiday: SeasonalHoliday) -> some View {
        Toggle(isOn: Binding(get: { settings.isOn(holiday) },
                             set: { toys.state.seasonal.set(holiday, on: $0) })) {
            HStack(spacing: 10) {
                SeasonalAccent(holiday: holiday, size: 22)
                SettingLabel(title: holiday.displayName, subtitle: holiday.when)
                if toys.seasonal.occasion?.holiday == holiday {
                    StatusBadge("Today", tone: .live)
                }
            }
        }
    }

    @ViewBuilder private var birthdays: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch toys.seasonal.contactsAccess {
            case .granted:
                Text("Your own birthday comes from your contact card.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
            case .notAsked:
                HStack(spacing: 8) {
                    Text("Your own birthday comes from your contact card, once Contacts is allowed.")
                        .jrbarType(.caption).foregroundStyle(.secondary)
                    Button("Allow Contacts") { toys.seasonal.askForContacts() }
                }
            case .refused:
                Text("Contacts is off for JR-Bar, so your own birthday isn't known. Turn it on in System Settings › Privacy & Security › Contacts.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let people = toys.seasonal.people
            if people.isEmpty {
                Text("People in your Birthdays calendar show here to celebrate. Their names stay on this Mac.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Celebrate these people too. Their names stay on this Mac.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
                ForEach(people.prefix(40)) { person in
                    Toggle(person.name, isOn: Binding(
                        get: { toys.state.seasonal.celebrates(person.id) },
                        set: { on in
                            toys.state.seasonal.celebrated.removeAll { $0.id == person.id }
                            if on { toys.state.seasonal.celebrated.append(person) }
                        }))
                }
            }
        }
        .padding(.leading, 32)
    }
}

// MARK: The closed notch's garland window

/// Hangs the garland under the Screen Bar while the notch is closed.
///
/// A click-through window of its own, placed under the band's panel and
/// moved with it, so the notch and the band keep every size, shape and
/// motion they had: the garland is an overlay only. It follows the panel
/// by its window notifications (moved, resized, shown or hidden), never a
/// timer, and stands down while the island is open (the card has its own
/// strip) or nothing is in season.
@MainActor
final class SeasonalBandOverlay {
    private let seasonal: SeasonalStore
    private let center: NotificationCenter
    private var window: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var observers: [NSObjectProtocol] = []
    private var shown: SeasonalOccasion?

    init(seasonal: SeasonalStore, center: NotificationCenter = .default) {
        self.seasonal = seasonal
        self.center = center
        track()
    }

    /// Re-arm on every change of the day's occasion.
    private func track() {
        withObservationTracking {
            _ = seasonal.occasion
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sync()
                    self?.track()
                }
            }
        }
        sync()
    }

    func sync() {
        guard seasonal.occasion != nil else {
            stop()
            return
        }
        if observers.isEmpty {
            let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                              NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didChangeScreenNotification]
            for name in names {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let isBand = note.object is ScreenBarPanel || note.object is NotchIslandWindow
                    guard isBand else { return }
                    MainActor.assumeIsolated { self?.place() }
                })
            }
        }
        place()
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        window?.orderOut(nil)
        window = nil
        host = nil
        shown = nil
    }

    /// Where the garland hangs: under the band, the island's width (the
    /// notch's), or nil while there is no band, the island is open, or
    /// nothing is in season.
    static func frame(band: NSRect?, island: NSRect?, notchDepth: CGFloat) -> NSRect? {
        guard let band, band.width > 1 else { return nil }
        if let island, island.height > notchDepth + 12 { return nil }
        let span = island.map { NSRect(x: $0.minX, y: band.minY, width: $0.width, height: band.height) } ?? band
        return NSRect(x: span.minX - 2, y: band.minY - SeasonalGarland.hang, width: span.width + 4,
                      height: SeasonalGarland.hang)
    }

    private func place() {
        guard let occasion = seasonal.occasion else { return stop() }
        let screen = ScreenBarGeometry.preferredScreen()
        let depth = screen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0
        guard let frame = Self.frame(band: ScreenBarGeometry.bandScreenRect,
                                     island: ScreenBarGeometry.islandScreenRect, notchDepth: depth) else {
            window?.orderOut(nil)
            return
        }
        let panel = window ?? makeWindow()
        if shown != occasion {
            shown = occasion
            host?.rootView = AnyView(SeasonalGarland(occasion: occasion))
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "JR-Bar seasonal garland"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
        self.host = host
        window = panel
        return panel
    }
}
