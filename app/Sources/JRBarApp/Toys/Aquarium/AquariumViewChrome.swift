import AppKit
import JRBarCore
import SwiftUI

/// The game's chrome over the water: pearls, the shop and the inspector.
extension AquariumView {
    // MARK: Game chrome

    /// Whether the tank owns a shop item — the fixture path owns
    /// whatever its synthetic game says.
    func owns(_ item: ShopItem) -> Bool {
        game?.owns(item) ?? false
    }

    /// A small translucent HUD chip.
    func hudChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
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
        return HStack(spacing: 8) {
            Text("While you were away — \(parts.joined(separator: " · "))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
            Button {
                toy?.dismissAwayNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .onTapGesture { toy?.dismissAwayNotice() }
    }

    /// The shop: every `ShopItem` grouped by category, one row each —
    /// price button when buyable, a lock while the tank level is short,
    /// a state control once owned. The game's reducer is the only money
    /// handler; the rows just send events.
    func shopPanel(fish: [Fish]) -> some View {
        let game = toy?.game ?? AquariumGame()
        let adults = fish.filter { !$0.isFry && $0.state != .leaving }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tank shop").font(.headline)
                    Spacer()
                    Text("◉ \(game.pearls)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                shopHeader(game)
                ForEach(ShopItem.Category.allCases, id: \.self) { category in
                    Text(category.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(ShopItem.allCases.filter { $0.category == category },
                            id: \.rawValue) { item in
                        shopRow(item, game: game, adults: adults)
                    }
                }
                achievementsSection(game)
            }
            .padding(14)
        }
        .frame(width: 330, height: 420)
    }

    /// The economy's vitals over the shelves: ladder rung and progress,
    /// the streak, and today's chore with its counter.
    private func shopHeader(_ game: AquariumGame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Tank level \(game.tankLevel)", systemImage: "chart.bar.fill")
                    .font(.system(size: 10, weight: .medium))
                if let next = AquariumProgression.nextLevelAt(
                    lifetimePearls: game.lifetimePearls) {
                    Text("· \(game.lifetimePearls.formatted()) / \(next.formatted()) pearls")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if game.streakDays > 1 {
                    Label("\(game.streakDays)d", systemImage: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            if let goal = game.dailyGoal {
                HStack(spacing: 6) {
                    Image(systemName: goal.claimed
                          ? "checkmark.circle.fill" : "target")
                        .font(.system(size: 10))
                        .foregroundStyle(goal.claimed ? .green : .secondary)
                    Text(goal.kind.displayName)
                        .font(.system(size: 10))
                    Spacer(minLength: 4)
                    Text(goal.claimed ? "Done"
                         : "\(min(goal.progress, goal.target))/\(goal.target)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One shop row: name + detail + the action the item's state asks
    /// for — buy, apply a surface, seat a wearable, or just "owned".
    /// An item on a shelf above the tank's level sits dimmed behind
    /// a lock instead.
    private func shopRow(_ item: ShopItem, game: AquariumGame,
                         adults: [Fish]) -> some View {
        let unlocked = item.isUnlocked(atLevel: game.tankLevel)
        return HStack(alignment: .center, spacing: 9) {
            shopTile(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                if unlocked {
                    Text(item.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Label("Unlocks at tank level \(AquariumProgression.tierUnlockLevel(tier: item.tier))",
                          systemImage: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if game.owns(item) {
                ownedControl(item, game: game, adults: adults)
            } else {
                buyButton(item, game: game)
            }
        }
        .opacity(unlocked ? 1 : 0.55)
    }

    /// The row's tile: a theme shows its own water, a floor its sand,
    /// everything else a glyph on its shelf's colour.
    @ViewBuilder
    private func shopTile(_ item: ShopItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let theme = item.themeID {
                shape.fill(LinearGradient(stops: Self.waterStops(forTheme: theme),
                                          startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.35)).frame(width: 14, height: 2).padding(.bottom, 4)
                    }
            } else if let substrate = item.substrateID {
                shape.fill(LinearGradient(colors: substrate == "white"
                                          ? [Color(red: 0.98, green: 0.96, blue: 0.90), Color(red: 0.72, green: 0.68, blue: 0.58)]
                                          : [Color(red: 0.34, green: 0.35, blue: 0.40), Color(red: 0.06, green: 0.06, blue: 0.08)],
                                          startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(Self.shopTint(item.category).gradient)
                    .overlay {
                        Image(systemName: Self.shopSymbol(item))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                    }
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .frame(width: 26, height: 26)
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
                Text("In use").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { toy?.selectTheme(item) }
                    .controlSize(.small)
            }
        case .substrates:
            if game.substrateID == item.substrateID
                || game.backdropID == item.backdropID {
                Text("In use").font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        default:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Owned")
        }
    }

    /// The price button — disabled when the bank is short; a denied
    /// tap can't get past the disabled state anyway.
    private func buyButton(_ item: ShopItem, game: AquariumGame) -> some View {
        Button("◉ \(item.price)") {
            toy?.purchase(item)
            // The purchase bloop: three little rings mid-tank.
            for k in 0..<3 {
                motion.puffs.append((x: 0.44 + Double(k) * 0.06,
                                     y: 0.30 + Double(k) * 0.05,
                                     bornAt: Date()))
            }
        }
        .controlSize(.small)
        .disabled(game.pearls < item.price)
    }

    /// The milestones, folded shut until asked: unlocked ones carry
    /// their date, locked ones sit dimmed with what they take.
    private func achievementsSection(_ game: AquariumGame) -> some View {
        DisclosureGroup {
            ForEach(AquariumAchievement.allCases, id: \.rawValue) { achievement in
                let at = game.unlocked[achievement.rawValue]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: at != nil ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 10))
                        .foregroundStyle(at != nil ? .yellow : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(achievement.title)
                            .font(.system(size: 11, weight: .medium))
                        Text(achievement.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if let at {
                        Text(Date(timeIntervalSince1970: at),
                             format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(at == nil ? 0.55 : 1)
            }
        } label: {
            Text("Achievements")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    func captionLayout(canvas: inout GraphicsContext, size: CGSize)
        -> (text: GraphicsContext.ResolvedText, rect: CGRect) {
        let resolved = canvas.resolve(
            Text("Quiet water — fish arrive when agents start")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62)))
        let textSize = resolved.measure(in: CGSize(width: size.width - 64, height: 40))
        let rect = CGRect(x: 16, y: size.height - 16 - textSize.height - 12,
                          width: textSize.width + 22, height: textSize.height + 12)
        return (resolved, rect)
    }

    /// A quiet tank is still a dressed tank — the jellyfish stays on
    /// as the resident and the caption capsule sits low on the left.
    func drawEmpty(canvas: inout GraphicsContext, size: CGSize,
                           caption: (text: GraphicsContext.ResolvedText, rect: CGRect)) {
        let pill = Path(roundedRect: caption.rect, cornerRadius: caption.rect.height / 2)
        canvas.fill(pill,
                    with: .color(Color(red: 0.02, green: 0.07, blue: 0.13).opacity(0.55)))
        canvas.stroke(pill, with: .color(.white.opacity(0.10)), lineWidth: 0.75)
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
