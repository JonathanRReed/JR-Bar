import AppKit
import JRBarCore
import SwiftUI

/// The game's chrome over the water: pearls, the shop and the inspector.
extension AquariumView {
    // MARK: Game chrome

    /// Whether a shop item is in the tank — owned and not put away.
    /// The fixture path shows whatever its synthetic game says.
    func owns(_ item: ShopItem) -> Bool {
        game?.shows(item) ?? false
    }

    /// Where the pearl counter sits before it has measured itself — the
    /// place a collected pearl flies home to on the first frame.
    static let pearlChipCenter = CGPoint(x: 34, y: 44)

    /// The idle game's chrome (docs/TOYS.md), in the safe area over the
    /// water: the pearl count and streak on glass at the top left, the
    /// feed and shop buttons at the top right, the "while you were
    /// away" card on reopen, a reward card for the rare moments and a
    /// small toast for the rest.
    func gameChrome(fish: [Fish]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let game = toy?.game {
                    pearlChip(game)
                    if game.streakDays > 1 {
                        hudChip {
                            HStack(spacing: 4) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange.gradient)
                                    .symbolEffect(.bounce, options: .nonRepeating, value: game.streakDays)
                                Text("\(game.streakDays)d")
                            }
                        }
                        .help("Days in a row with a completed session.")
                    }
                }
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        hudButton("hand.pinch.fill", help: "Drop a pinch of food — or just tap the water.") {
                            feed(at: CGPoint(x: motion.size.width * 0.5, y: motion.size.height * 0.30))
                        }
                        hudButton("bag.fill", help: "Tank shop — decor, pets, themes, hats.") {
                            showShop = true
                        }
                        .popover(isPresented: $showShop, arrowEdge: .top) {
                            shopPanel(fish: fish)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            if let away = toy?.awayNotice {
                awayBanner(away)
            }
            if let n = toy?.notice {
                rewardCard(n)
            }
            Spacer()
            if let toast = toy?.toast {
                Text(toast.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .environment(\.colorScheme, .dark)
                    .padding(.bottom, 52)
                    .onTapGesture { toy?.dismissToast() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: toy?.notice?.id)
        .animation(.smooth(duration: 0.3), value: toy?.toast?.text)
    }

    /// The pearl counter: a little lit pearl and the bank, bouncing when
    /// it grows. It measures where it sits so a pearl collected in the
    /// water flies home to it.
    private func pearlChip(_ game: AquariumGame) -> some View {
        hudChip {
            HStack(spacing: 5) {
                PearlGlyph(size: 10, coin: game.themeID == "arcade")
                    .keyframeAnimator(initialValue: 1.0, trigger: game.pearls) { pearl, scale in
                        pearl.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.35, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.32)
                    }
                Text("\(game.pearls)")
                    .contentTransition(.numericText())
            }
        }
        .help("Pearls — earned while sessions work, spent in the shop.")
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .named(Self.tankSpace))
            return CGPoint(x: frame.minX + 12, y: frame.midY)
        } action: { point in
            motion.pearlChip = point
        }
    }

    /// A HUD chip: a small capsule of glass over the water.
    func hudChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
    }

    /// A round glass button in the HUD.
    private func hudButton(_ symbol: String, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .environment(\.colorScheme, .dark)
        .help(help)
    }

    /// The reward card — kin to the away-summary banner: glass, a gold
    /// glyph, title and payout. Slides in from the top edge and fades
    /// out as `notice` clears.
    private func rewardCard(_ n: (id: UUID, title: String, reward: String?, symbol: String, at: Date)) -> some View {
        HStack(spacing: 9) {
            Image(systemName: n.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.36).gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(n.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                if let reward = n.reward {
                    Text(reward)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: n.id) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            toy?.dismissNotice(id: n.id)
        }
        .allowsHitTesting(false)
    }

    /// The "while you were away" card (docs/TOYS.md): what the closed
    /// window banked, one line, dismissed by a tap or the ×.
    func awayBanner(_ away: AquariumAwaySummary) -> some View {
        var parts: [String] = []
        if away.pearlsEarned > 0 { parts.append("+\(away.pearlsEarned) pearls") }
        if away.completions > 0 {
            parts.append("\(away.completions) session\(away.completions == 1 ? "" : "s") finished")
        }
        if away.dropsCollected > 0 {
            parts.append("\(away.dropsCollected) drop\(away.dropsCollected == 1 ? "" : "s") collected")
        }
        return HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.84, blue: 1.0))
            Text("While you were away — \(parts.joined(separator: " · "))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
            Button {
                toy?.dismissAwayNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .onTapGesture { toy?.dismissAwayNotice() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Shop

    /// The shop: every `ShopItem` grouped by category, one row each —
    /// price button when buyable, a lock while the tank level is short,
    /// a state control once owned. The game's reducer is the only money
    /// handler; the rows just send events.
    func shopPanel(fish: [Fish]) -> some View {
        let game = self.game ?? AquariumGame()
        let adults = fish.filter { !$0.isFry && $0.state != .leaving }
        return ScrollView {
            shopShelves(game: game, adults: adults)
                .padding(16)
        }
        .frame(width: 348, height: 480)
    }

    /// The shop's contents: the purse and its vitals, then each shelf.
    func shopShelves(game: AquariumGame, adults: [Fish]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            shopHeader(game)
            ForEach(ShopItem.Category.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.displayName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    VStack(spacing: 2) {
                        ForEach(ShopItem.allCases.filter { $0.category == category },
                                id: \.rawValue) { item in
                            shopRow(item, game: game, adults: adults)
                        }
                    }
                }
            }
            achievementsSection(game)
        }
    }

    /// The economy's vitals over the shelves: the bank, the tank's
    /// level and how far to the next, the streak, and today's chore.
    private func shopHeader(_ game: AquariumGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Tank shop")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    PearlGlyph(size: 11)
                    Text(game.pearls.formatted())
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "water.waves")
                        .foregroundStyle(Self.shopAccent)
                    Text("Tank level \(game.tankLevel)")
                        .fontWeight(.medium)
                    if let next = AquariumProgression.nextLevelAt(lifetimePearls: game.lifetimePearls) {
                        Text("\(game.lifetimePearls.formatted()) of \(next.formatted()) pearls")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if game.streakDays > 1 {
                        Label("\(game.streakDays)d", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let goal = game.dailyGoal {
                    HStack(spacing: 6) {
                        Image(systemName: goal.claimed ? "checkmark.circle.fill" : "target")
                            .foregroundStyle(goal.claimed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        Text(goal.kind.displayName)
                        Spacer(minLength: 4)
                        Text(goal.claimed ? "Done" : "\(min(goal.progress, goal.target)) of \(goal.target)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// The shop's one accent — the tank's own teal.
    static let shopAccent = Color(red: 0.16, green: 0.58, blue: 0.66)

    /// One shop row: name + detail + the action the item's state asks
    /// for — buy, apply a surface, seat a wearable, or just "owned".
    /// An item on a shelf above the tank's level sits dimmed behind a
    /// lock instead.
    private func shopRow(_ item: ShopItem, game: AquariumGame,
                         adults: [Fish]) -> some View {
        let unlocked = item.isUnlocked(atLevel: game.tankLevel)
        return HStack(alignment: .center, spacing: 10) {
            shopTile(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                if unlocked {
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Unlocks at tank level \(AquariumProgression.tierUnlockLevel(tier: item.tier))",
                          systemImage: "lock.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if !unlocked {
                EmptyView()
            } else if game.owns(item) {
                ownedControl(item, game: game, adults: adults)
            } else {
                buyButton(item, game: game)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            if game.owns(item) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            }
        }
        .opacity(unlocked ? 1 : 0.5)
    }

    /// The row's tile: a theme shows its own water, a floor its sand,
    /// everything else a glyph on its shelf's colour.
    @ViewBuilder
    private func shopTile(_ item: ShopItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let theme = item.themeID {
                shape.fill(LinearGradient(stops: Self.waterStops(forTheme: theme),
                                          startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.35)).frame(width: 14, height: 2).padding(.bottom, 5)
                    }
            } else if let substrate = item.substrateID {
                shape.fill(LinearGradient(colors: Self.sandSwatch(forSubstrate: substrate),
                                          startPoint: .top, endPoint: .bottom))
            } else if let backdrop = item.backdropID {
                BackdropSwatch(backdropID: backdrop)
                    .clipShape(shape)
            } else {
                shape.fill(Self.shopTint(item.category).gradient)
                    .overlay {
                        Image(systemName: Self.shopSymbol(item))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    }
            }
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    /// Each shelf's colour for its tiles.
    static func shopTint(_ category: ShopItem.Category) -> Color {
        switch category {
        case .decor: return Color(red: 0.20, green: 0.56, blue: 0.62)
        case .pets: return Color(red: 0.24, green: 0.62, blue: 0.36)
        case .accessories: return Color(red: 0.46, green: 0.36, blue: 0.78)
        case .hats: return Color(red: 0.86, green: 0.38, blue: 0.46)
        case .buddy: return Color(red: 0.93, green: 0.30, blue: 0.62)
        case .themes: return Color(red: 0.20, green: 0.44, blue: 0.80)
        case .substrates: return Color(red: 0.62, green: 0.50, blue: 0.30)
        }
    }

    /// Each item's glyph on its tile.
    static func shopSymbol(_ item: ShopItem) -> String {
        switch item {
        case .plant: return "leaf.fill"
        case .rock, .rockyBackdrop, .reefWallBackdrop: return "mountain.2.fill"
        case .treasureChest: return "shippingbox.fill"
        case .castle: return "flag.fill"
        case .driftwood: return "tree.fill"
        case .amphora: return "wineglass.fill"
        case .bubbleWall: return "bubbles.and.sparkles.fill"
        case .anemoneBed, .buddyFlower: return "camera.macro"
        case .sunkenStatue: return "theatermasks.fill"
        case .shipwreck: return "sailboat.fill"
        case .ruinedColumns: return "building.columns.fill"
        case .coralGarden: return "allergens.fill"
        case .moonJellyLamp: return "lamp.table.fill"
        case .volcano: return "flame.fill"
        case .snail, .hermitCrab: return "fossil.shell.fill"
        case .jellyfish: return "umbrella.fill"
        case .cleanerShrimp: return "ant.fill"
        case .tetraSchool: return "fish.fill"
        case .seaTurtle: return "tortoise.fill"
        case .axolotl: return "lizard.fill"
        case .octopus: return "hurricane"
        case .manta: return "bird.fill"
        case .sunglasses: return "sunglasses.fill"
        case .bowTie, .buddyBow: return "sparkles"
        case .monocle: return "eyeglasses"
        case .headphones: return "headphones"
        case .scarf: return "wind"
        case .topHat: return "hat.widebrim.fill"
        case .tinyLaptop: return "laptopcomputer"
        case .hatBeanie, .buddyBeanie: return "hat.cap.fill"
        case .hatParty: return "party.popper.fill"
        case .hatCrown: return "crown.fill"
        case .oyster: return "circle.circle.fill"
        case .alienBeacon: return "antenna.radiowaves.left.and.right"
        default: return "sparkles"
        }
    }

    /// What an owned item offers: a surface's Use, a wearable's fish
    /// picker, or just the check that says it's in the tank.
    @ViewBuilder
    private func ownedControl(_ item: ShopItem, game: AquariumGame,
                              adults: [Fish]) -> some View {
        switch item.category {
        case .themes:
            if game.themeID == item.themeID {
                inUse
            } else {
                Button("Use") { toy?.selectTheme(item) }
                    .controlSize(.small)
            }
        case .substrates:
            if game.substrateID == item.substrateID
                || game.backdropID == item.backdropID {
                inUse
            } else {
                Button("Use") {
                    if item.substrateID != nil {
                        toy?.selectSubstrate(item)
                    } else if item.backdropID != nil {
                        toy?.selectBackdrop(item)
                    }
                }
                .controlSize(.small)
            }
        case .buddy:
            // The Notch Buddy wears it — the same purse dresses both toys.
            let worn = toy?.store?.state.notchBuddy.wearing == item.rawValue
            Button(worn ? "Take off" : "Wear") {
                toy?.store?.notchBuddy.wear(worn ? nil : item)
            }
            .controlSize(.small)
            .help(worn ? "The buddy is wearing it." : "Put it on the Notch Buddy.")
        case .hats, .accessories:
            let worn = item.category == .hats ? game.hats : game.accessories
            Menu {
                ForEach(adults) { fish in
                    Button(fish.label) {
                        if item.category == .hats {
                            toy?.equipHat(item, to: fish.id)
                        } else {
                            toy?.equipAccessory(item, to: fish.id)
                        }
                    }
                }
                if worn.contains(where: { $0.value == item.rawValue }) {
                    Divider()
                    Button("Take it off") {
                        if item.category == .hats {
                            toy?.equipHat(item, to: nil)
                        } else {
                            toy?.equipAccessory(item, to: nil)
                        }
                    }
                }
            } label: {
                Text(worn.contains(where: { $0.value == item.rawValue })
                     ? "Re-seat" : "Wear")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        case .decor, .pets:
            // Owned pieces and pets can be put away without selling
            // them — the switch is whether it's in the tank.
            Toggle("In tank", isOn: Binding(
                get: { game.shows(item) },
                set: { toy?.setStored(item, !$0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10.5))
                .fixedSize()
                .help(game.shows(item) ? "In the tank — switch off to put it away."
                                       : "Put away — switch on to bring it back.")
        }
    }

    /// The quiet "in use" mark for the surface the tank is wearing.
    private var inUse: some View {
        Text("In use")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Self.shopAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.shopAccent.opacity(0.14), in: Capsule())
    }

    /// The price button — disabled when the bank is short; a denied
    /// tap can't get past the disabled state anyway.
    private func buyButton(_ item: ShopItem, game: AquariumGame) -> some View {
        Button {
            toy?.purchase(item)
            // The purchase bloop: three little rings mid-tank.
            for k in 0..<3 {
                motion.puffs.append((x: 0.44 + Double(k) * 0.06,
                                     y: 0.30 + Double(k) * 0.05,
                                     bornAt: Date()))
            }
        } label: {
            HStack(spacing: 4) {
                PearlGlyph(size: 8)
                Text("\(item.price)")
                    .monospacedDigit()
            }
            .frame(minWidth: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(Self.shopAccent)
        .controlSize(.small)
        .disabled(game.pearls < item.price)
    }

    /// The milestones, folded shut until asked: unlocked ones carry
    /// their date, locked ones sit dimmed with what they take.
    private func achievementsSection(_ game: AquariumGame) -> some View {
        let earned = AquariumAchievement.allCases.filter { game.unlocked[$0.rawValue] != nil }.count
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AquariumAchievement.allCases, id: \.rawValue) { achievement in
                    let at = game.unlocked[achievement.rawValue]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: at != nil ? "checkmark.seal.fill" : "seal")
                            .font(.system(size: 11))
                            .foregroundStyle(at != nil ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(achievement.title)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(achievement.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if let at {
                            Text(Date(timeIntervalSince1970: at),
                                 format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .opacity(at == nil ? 0.55 : 1)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("ACHIEVEMENTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(earned) of \(AquariumAchievement.allCases.count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    func captionLayout(canvas: inout GraphicsContext, size: CGSize)
        -> (text: GraphicsContext.ResolvedText, rect: CGRect) {
        let resolved = canvas.resolve(
            Text("Quiet water — fish arrive when agents start")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.78)))
        let textSize = resolved.measure(in: CGSize(width: size.width - 64, height: 40))
        let rect = CGRect(x: 16, y: size.height - 16 - textSize.height - 14,
                          width: textSize.width + 26, height: textSize.height + 14)
        return (resolved, rect)
    }

    /// A quiet tank is still a dressed tank — the jellyfish stays on
    /// as the resident and the caption sits low on the left in a smoked
    /// glass capsule.
    func drawEmpty(canvas: inout GraphicsContext, size: CGSize,
                   caption: (text: GraphicsContext.ResolvedText, rect: CGRect)) {
        let pill = Path(roundedRect: caption.rect, cornerRadius: caption.rect.height / 2)
        canvas.fill(pill, with: .linearGradient(
            Gradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.20).opacity(0.62),
                              Color(red: 0.02, green: 0.06, blue: 0.12).opacity(0.70)]),
            startPoint: CGPoint(x: 0, y: caption.rect.minY), endPoint: CGPoint(x: 0, y: caption.rect.maxY)))
        canvas.stroke(pill, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.22), .white.opacity(0.06)]),
            startPoint: CGPoint(x: 0, y: caption.rect.minY), endPoint: CGPoint(x: 0, y: caption.rect.maxY)),
                      lineWidth: 0.75)
        canvas.draw(caption.text,
                    at: CGPoint(x: caption.rect.midX, y: caption.rect.midY),
                    anchor: .center)
    }

    func frac(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }

    func smooth(_ x: Double) -> Double {
        let c = clamp01(x)
        return c * c * (3 - 2 * c)
    }
}

/// A single pearl, lit from above: the tank's currency mark, in the
/// HUD, the shop's purse and its price buttons.
struct PearlGlyph: View {
    var size: CGFloat
    /// The Arcade tank's pearls come as coins — the HUD chip follows.
    var coin = false

    var body: some View {
        if coin { coinBody } else { pearlBody }
    }

    /// A small gold coin with a dark rim and a hard highlight.
    private var coinBody: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.52),
                                          Color(red: 0.96, green: 0.70, blue: 0.14),
                                          Color(red: 0.78, green: 0.48, blue: 0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(Color(red: 0.42, green: 0.24, blue: 0.02), lineWidth: max(0.8, size * 0.1)))
            .overlay(alignment: .topLeading) {
                Ellipse()
                    .fill(.white.opacity(0.9))
                    .frame(width: size * 0.3, height: size * 0.22)
                    .offset(x: size * 0.18, y: size * 0.16)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var pearlBody: some View {
        Circle()
            .fill(RadialGradient(colors: [.white, Color(red: 0.96, green: 0.92, blue: 0.84),
                                          Color(red: 0.72, green: 0.66, blue: 0.64)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7))
            .overlay(alignment: .topLeading) {
                Ellipse()
                    .fill(.white.opacity(0.9))
                    .frame(width: size * 0.32, height: size * 0.22)
                    .offset(x: size * 0.2, y: size * 0.16)
            }
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A back wall's tile: open water with the wall's silhouette across the
/// bottom — the reef's rounded heads or the rocky spires.
private struct BackdropSwatch: View {
    let backdropID: String

    var body: some View {
        Canvas { canvas, size in
            canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: AquariumView.waterStops(forTheme: "classic")),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if backdropID == "toyreef" {
                // The painted set: three round heads in toy colours with
                // an ink edge.
                let heads: [(Double, Double, Double, Color)] = [
                    (0.22, 0.62, 0.26, Color(red: 1.0, green: 0.50, blue: 0.56)),
                    (0.58, 0.55, 0.30, Color(red: 0.36, green: 0.82, blue: 0.40)),
                    (0.88, 0.66, 0.22, Color(red: 1.0, green: 0.64, blue: 0.26)),
                ]
                for (x, y, r, color) in heads {
                    let rect = CGRect(x: size.width * x - size.height * r, y: size.height * y - size.height * r,
                                      width: size.height * r * 2, height: size.height * r * 2)
                    canvas.fill(Path(ellipseIn: rect), with: .color(color))
                    canvas.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.55)), lineWidth: 1)
                }
            }
            var wall = Path()
            wall.move(to: CGPoint(x: 0, y: size.height))
            if backdropID == "toyreef" {
                wall.addLine(to: CGPoint(x: 0, y: size.height * 0.80))
            } else if backdropID == "rocky" {
                let peaks: [(Double, Double)] = [(0, 0.55), (0.18, 0.30), (0.34, 0.62), (0.52, 0.40),
                                                 (0.70, 0.66), (0.86, 0.26), (1, 0.50)]
                for (x, y) in peaks {
                    wall.addLine(to: CGPoint(x: size.width * x, y: size.height * y))
                }
            } else {
                wall.addLine(to: CGPoint(x: 0, y: size.height * 0.36))
                var x = 0.0
                while x < 1 {
                    let next = min(1, x + 0.2)
                    wall.addQuadCurve(to: CGPoint(x: size.width * next, y: size.height * (0.44 + 0.1 * sin(next * 9))),
                                      control: CGPoint(x: size.width * (x + next) / 2, y: size.height * 0.24))
                    x = next
                }
            }
            wall.addLine(to: CGPoint(x: size.width, y: size.height))
            wall.closeSubpath()
            canvas.fill(wall, with: .linearGradient(
                Gradient(colors: [Color(red: 0.12, green: 0.30, blue: 0.46), Color(red: 0.03, green: 0.10, blue: 0.24)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var sand = Path()
            sand.addRect(CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.18))
            canvas.fill(sand, with: .linearGradient(
                Gradient(colors: AquariumView.sandSwatch(forSubstrate: "classic")),
                startPoint: CGPoint(x: 0, y: size.height * 0.82), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}
