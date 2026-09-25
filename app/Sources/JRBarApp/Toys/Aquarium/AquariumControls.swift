import AppKit
import JRBarCore
import SwiftUI

/// The Aquarium card (docs/TOYS.md): what's in the tank, then four rows
/// most people touch — the Look, Labels, Day & night and Sound — a
/// folded Fine-tune for the numbers, and the tank outside its window.
/// A Settings search that lands on a Fine-tune row opens it.
struct AquariumControlsView: View {
    let toy: AquariumToy
    @ViewState private var fineTune: Bool

    init(toy: AquariumToy, fineTune: Bool = false) {
        self.toy = toy
        _fineTune = ViewState(initialValue: fineTune)
    }

    /// The rows that live inside Fine-tune — a search hit on one opens
    /// it. The swim rows (pace, size, speed) sit there too.
    static let fineTuneTitles: Set<String> = [
        "Fish at once", "Raised fish stay", "Plankton", "Bubbles", "Scenery", "Visitors",
        "Swim pace", "Fish size", "Swimming speed",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                TankSwatch(themeID: toy.game.themeID, substrateID: toy.game.substrateID)
            } label: {
                SettingLabel(title: "In the tank", subtitle: toy.fact)
            }

            Divider()
                .padding(.vertical, 4)

            lookRow
            labelsRow
            dayNightRow
            Toggle(isOn: bind(\.sound)) {
                SettingLabel(title: "Sound",
                             subtitle: "A plop, a gulp, a clink — for your taps and what happens in the open window, at the Sounds page's volume. Quiet during Focus.")
            }

            DisclosureGroup(isExpanded: $fineTune) {
                fineTuneRows
            } label: {
                SettingLabel(title: "Fine-tune",
                             subtitle: "Fish size and speed, how many at once, plankton, bubbles, scenery and visitors.")
            }
            .padding(.top, 2)

            CardSectionHeader("Outside the window")
            outsideRows
        }
        .onChange(of: revealKey, initial: true) {
            if let row = toy.store?.revealRow, Self.fineTuneTitles.contains(row) {
                fineTune = true
            }
        }
    }

    /// Changes with every search reveal, so the same row picked twice
    /// still opens Fine-tune.
    private var revealKey: Int { toy.store?.settings.revealRequest ?? 0 }

    // MARK: Main rows

    private var lookRow: some View {
        LabeledContent {
            AquariumLookMenu(toy: toy)
                .frame(maxWidth: 230, alignment: .trailing)
        } label: {
            SettingLabel(title: "Look", subtitle: "Water, floor and back wall — Classic, or anything you've bought.")
        }
    }

    private var labelsRow: some View {
        LabeledContent {
            Picker("", selection: bind(\.labelStyle)) {
                Text("Always").tag(AquariumLabelStyle.always)
                Text("On hover").tag(AquariumLabelStyle.hover)
                Text("Never").tag(AquariumLabelStyle.never)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        } label: {
            SettingLabel(title: "Labels", subtitle: labelsSubtitle)
        }
    }

    private var labelsSubtitle: String {
        switch settings.labelStyle {
        case .always: return "The session's name rides under its fish."
        case .hover: return "A name shows over the fish under the pointer."
        case .never: return "No names — a fish you select still says who it is."
        }
    }

    private var dayNightRow: some View {
        LabeledContent {
            Picker("", selection: bind(\.dayNight)) {
                Text("Follow the clock").tag(DayNightMode.realTime)
                Text("Follow the sun").tag(DayNightMode.sun)
                Text("Follow Light & Dark").tag(DayNightMode.appearance)
                Text("4-minute cycle").tag(DayNightMode.cycle)
                Divider()
                Text("Always day").tag(DayNightMode.alwaysDay)
                Text("Always night").tag(DayNightMode.alwaysNight)
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            SettingLabel(title: "Day & night", subtitle: toy.dayNightSubtitle)
        }
    }

    // MARK: Fine-tune

    @ViewBuilder
    private var fineTuneRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            AquariumSwimRows(settings: aquarium)
            LabeledContent {
                Picker("", selection: bind(\.maxFish)) {
                    ForEach(AquariumSettings.maxFishChoices, id: \.self) { count in
                        Text(count == 0 ? "All" : "\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: "Fish at once",
                             subtitle: "Past this, raised fish rest first, then quiet sessions. An ask or a failure always shows.")
            }
            Toggle(isOn: bind(\.keepResidents)) {
                SettingLabel(title: "Raised fish stay",
                             subtitle: "A fish you grew keeps swimming after its session leaves.")
            }
            LabeledContent {
                slider(bind(\.density), in: AquariumSettings.densityRange)
            } label: {
                SettingLabel(title: "Plankton", subtitle: "The motes drifting in the water. None at 0.")
            }
            LabeledContent {
                slider(bind(\.bubbles), in: AquariumSettings.bubblesRange)
            } label: {
                SettingLabel(title: "Bubbles", subtitle: "The bubbles rising off the sand. None at 0.")
            }
            LabeledContent {
                Picker("", selection: bind(\.scenery)) {
                    Text("Full").tag(AquariumScenery.full)
                    Text("Light").tag(AquariumScenery.light)
                    Text("Bare").tag(AquariumScenery.bare)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: "Scenery",
                             subtitle: "The kelp, rocks and shells every tank starts with. What you bought always stays.")
            }
            Toggle(isOn: bind(\.visitors)) {
                SettingLabel(title: "Visitors",
                             subtitle: "The whale, the diver, the submarine and the alien now and then.")
            }
            HStack {
                Spacer()
                Button("Reset fine-tune") { resetFineTune() }
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func slider(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range)
                .frame(width: 160)
            ValueText(text: String(format: "%.2f×", value.wrappedValue))
        }
    }

    /// Fine-tune back to the tank's defaults; the look, labels, day &
    /// night, sound and everything outside the window stay as set.
    private func resetFineTune() {
        guard let store = toy.store else { return }
        let current = store.state.aquarium
        var fresh = AquariumSettings()
        fresh.enabled = current.enabled
        fresh.speciesOverrides = current.speciesOverrides
        fresh.dayNight = current.dayNight
        fresh.idleFillMinutes = current.idleFillMinutes
        fresh.ambientDisplay = current.ambientDisplay
        fresh.saverClock = current.saverClock
        fresh.labelStyle = current.labelStyle
        fresh.sound = current.sound
        store.state.aquarium = fresh
    }

    // MARK: Outside the window

    @ViewBuilder
    private var outsideRows: some View {
        LabeledContent {
            Button("Fill screen") { toy.fillScreen() }
        } label: {
            SettingLabel(title: "Fill screen", subtitle: "The tank covers the whole screen. Esc leaves.")
        }
        LabeledContent {
            wallpaperPicker
                .labelsHidden()
                .fixedSize()
        } label: {
            SettingLabel(title: "Live wallpaper", subtitle: "The tank behind every window on a display, click-through. Draws while you can see it.")
        }
        LabeledContent {
            Picker("", selection: bind(\.idleFillMinutes)) {
                ForEach(AquariumSettings.idleFillChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "Off" : "After \(minutes) min").tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            SettingLabel(title: "Screensaver", subtitle: "Idle that long, the tank fills your screens until you're back — never over a video, a call or a fullscreen app.")
        }
        if settings.idleFillMinutes > 0 {
            Toggle(isOn: bind(\.saverClock)) {
                SettingLabel(title: "Clock on the screensaver", subtitle: "The time and date, quietly, in a corner.")
            }
        }
    }

    private var wallpaperPicker: some View {
        let connected = NSScreen.screens.map(\.localizedName)
        let choices = AquariumWallpaper.displayChoices(connected: connected,
                                                       saved: settings.ambientDisplay)
        return Picker("", selection: bind(\.ambientDisplay)) {
            Text("Off").tag(String?.none)
            ForEach(choices, id: \.self) { name in
                Text(connected.contains(name) ? name : "\(name) (not connected)")
                    .tag(String?.some(name))
            }
        }
    }

    // MARK: Plumbing

    private var settings: AquariumSettings { toy.store?.state.aquarium ?? AquariumSettings() }

    /// A binding onto the whole aquarium block, for rows that take one
    /// (`AquariumSwimRows`).
    private var aquarium: Binding<AquariumSettings> {
        let toy = self.toy
        return Binding(get: { toy.store?.state.aquarium ?? AquariumSettings() },
                       set: { toy.store?.state.aquarium = $0 })
    }

    /// A binding onto one aquarium setting in the toys' store.
    private func bind<Value>(_ key: WritableKeyPath<AquariumSettings, Value>) -> Binding<Value> {
        let toy = self.toy
        return Binding(get: { (toy.store?.state.aquarium ?? AquariumSettings())[keyPath: key] },
                       set: { toy.store?.state.aquarium[keyPath: key] = $0 })
    }
}

/// The card's Look menu: Classic plus every owned water, floor and back
/// wall, each a checked pick, and the way into the shop.
struct AquariumLookMenu: View {
    let toy: AquariumToy

    var body: some View {
        Menu {
            surfacePicker("Water", .water, items: owned { $0.themeID })
            surfacePicker("Floor", .floor, items: owned { $0.substrateID })
            surfacePicker("Back wall", .wall, items: owned { $0.backdropID })
            Divider()
            Button("Open the shop…") { toy.openShop() }
        } label: {
            Text(summary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Arcade · Candy gravel · Toy reef", or "Classic" when nothing
    /// bought is showing.
    var summary: String {
        let game = toy.game
        let picks = [name(game.themeID) { $0.themeID },
                     name(game.substrateID) { $0.substrateID },
                     name(game.backdropID) { $0.backdropID }].compactMap { $0 }
        return picks.isEmpty ? "Classic" : picks.joined(separator: " · ")
    }

    private func name(_ id: String, _ key: (ShopItem) -> String?) -> String? {
        guard id != "classic" else { return nil }
        return ShopItem.allCases.first { key($0) == id }?.displayName
    }

    private func owned(_ key: (ShopItem) -> String?) -> [ShopItem] {
        ShopItem.allCases.filter { key($0) != nil && toy.game.owns($0) }
    }

    private func surfacePicker(_ title: String, _ surface: AquariumSurface,
                               items: [ShopItem]) -> some View {
        Picker(title, selection: selection(surface)) {
            Text("Classic").tag("classic")
            ForEach(items, id: \.rawValue) { item in
                Text(item.displayName).tag(Self.id(of: item, on: surface) ?? item.rawValue)
            }
        }
        .pickerStyle(.inline)
    }

    private static func id(of item: ShopItem, on surface: AquariumSurface) -> String? {
        switch surface {
        case .water: return item.themeID
        case .floor: return item.substrateID
        case .wall: return item.backdropID
        }
    }

    private func selection(_ surface: AquariumSurface) -> Binding<String> {
        let toy = self.toy
        return Binding(get: {
            switch surface {
            case .water: return toy.game.themeID
            case .floor: return toy.game.substrateID
            case .wall: return toy.game.backdropID
            }
        }, set: { id in
            toy.useSurface(surface, id: id)
        })
    }
}

/// The card's glimpse of the tank: the water in the theme it wears,
/// light falling through it and the floor it sits on — a still
/// picture, so the card costs nothing to show.
struct TankSwatch: View {
    let themeID: String
    let substrateID: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Canvas { canvas, size in
            let rect = Path(CGRect(origin: .zero, size: size))
            canvas.fill(rect, with: .linearGradient(
                Gradient(stops: AquariumView.waterStops(forTheme: themeID)),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let light = AquariumView.water(forTheme: themeID)
            var shafts = canvas
            shafts.blendMode = .plusLighter
            for (x, w) in [(0.22, 0.10), (0.42, 0.06), (0.58, 0.12)] as [(Double, Double)] where light.shafts > 0 {
                var beam = Path()
                beam.move(to: CGPoint(x: size.width * (x - w / 2), y: 0))
                beam.addLine(to: CGPoint(x: size.width * (x + w / 2), y: 0))
                beam.addLine(to: CGPoint(x: size.width * (x + w * 1.4 + 0.12), y: size.height))
                beam.addLine(to: CGPoint(x: size.width * (x + 0.12), y: size.height))
                beam.closeSubpath()
                shafts.fill(beam, with: .linearGradient(
                    Gradient(colors: [TankPaint.color(light.light, 0.22 * light.shafts), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            var sand = Path()
            sand.move(to: CGPoint(x: 0, y: size.height * 0.80))
            sand.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.76),
                              control: CGPoint(x: size.width * 0.5, y: size.height * 0.70))
            sand.addLine(to: CGPoint(x: size.width, y: size.height))
            sand.addLine(to: CGPoint(x: 0, y: size.height))
            sand.closeSubpath()
            canvas.fill(sand, with: .linearGradient(
                Gradient(colors: AquariumView.sandSwatch(forSubstrate: substrateID)),
                startPoint: CGPoint(x: 0, y: size.height * 0.72), endPoint: CGPoint(x: 0, y: size.height)))
            var gravel = canvas
            gravel.clip(to: sand)
            let bed = CGRect(x: 0, y: size.height * 0.70, width: size.width, height: size.height * 0.30)
            AquariumView.drawSwatchGravel(&gravel, in: bed, substrate: substrateID, bead: 1.5)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.15)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
        .frame(width: 76, height: 46)
        .accessibilityHidden(true)
    }
}
