import AppKit
import JRBarCore
import SwiftUI

/// Growth that follows the work (docs/TOYS.md): the buddy grows up on
/// the crumbs finished sessions feed it — hatchling, grown, elder — over
/// weeks of real runs, and never shrinks back. Tamagotchi's life stages
/// without the neglect death: the stage reads the lifetime crumb count,
/// which only ever goes up.
enum BuddyStage: Int, CaseIterable, Comparable {
    case hatchling, grown, elder

    /// Crumbs to grow up, and to become an elder.
    static let grownAt = 30
    static let elderAt = 400

    static func of(crumbs: Int) -> BuddyStage {
        crumbs >= elderAt ? .elder : (crumbs >= grownAt ? .grown : .hatchling)
    }

    var word: String {
        switch self {
        case .hatchling: return "Hatchling"
        case .grown: return "Grown"
        case .elder: return "Elder"
        }
    }

    /// "Hatchling · 12 crumbs to grown", "Grown · 188 crumbs to elder",
    /// "Elder".
    static func line(crumbs: Int) -> String {
        let stage = of(crumbs: crumbs)
        func left(_ target: Int) -> String {
            let n = max(1, target - crumbs)
            return n == 1 ? "1 crumb" : "\(n) crumbs"
        }
        switch stage {
        case .hatchling: return "Hatchling · \(left(grownAt)) to grown"
        case .grown: return "Grown · \(left(elderAt)) to elder"
        case .elder: return "Elder"
        }
    }

    static func < (a: BuddyStage, b: BuddyStage) -> Bool { a.rawValue < b.rawValue }
}

/// The pal card's facts, pure: what the care log adds up to, in words.
/// Claude Code's /buddy had a stats card built on a hash; this one is
/// built on the log — every line is something that actually happened
/// between you (Pixel Pals' tap card, with real history).
struct BuddyPalCard: Equatable {
    /// "Blissed out", "Content", "Misses you", "Not met yet".
    var feeling: String
    /// "Together since 3 Sep" / "Together at least since 3 Sep"; nil
    /// before you've met.
    var since: String?
    /// "142 pets · 12 treats · 318 crumbs".
    var tally: String
    /// "Favourite agent: Claude — 201 crumbs"; nil before a crumb had a
    /// provider.
    var favourite: String?
    /// "Longest ask sat through: 14 min"; nil before any.
    var longestAsk: String?
    /// "Grown · 188 crumbs to elder".
    var growth: String = ""
    var stage: BuddyStage = .grown

    static func make(care: BuddyCare, now: Date = Date(),
                     providerName: (String) -> String = { SessionLabel.providerName($0) }) -> BuddyPalCard {
        let met = care.firstMetAt > 0
        let feeling: String
        switch care.mood(at: now) {
        case .fed: feeling = "Blissed out"
        case .missing: feeling = "Misses you"
        case .content: feeling = met ? "Content" : "Not met yet"
        }
        var since: String?
        if met {
            let day = Date(timeIntervalSince1970: care.firstMetAt)
                .formatted(.dateTime.day().month(.abbreviated).year())
            since = care.firstMetIsFloor ? "Together at least since \(day)" : "Together since \(day)"
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let tally = [count(care.petCount, "pet", "pets"),
                     count(care.treatsGiven, "treat", "treats"),
                     count(care.crumbsEaten, "crumb", "crumbs")].joined(separator: " · ")
        let favourite = care.favouriteProvider.map {
            "Favourite agent: \(providerName($0.id)) — \(count($0.crumbs, "crumb", "crumbs"))"
        }
        let longestAsk = care.longestAskSeconds >= 1
            ? "Longest ask sat through: \(duration(care.longestAskSeconds))" : nil
        return BuddyPalCard(feeling: feeling, since: since, tally: tally,
                            favourite: favourite, longestAsk: longestAsk,
                            growth: BuddyStage.line(crumbs: care.crumbsEaten),
                            stage: BuddyStage.of(crumbs: care.crumbsEaten))
    }

    /// "45 s", "14 min", "2 h 5 min". The care log and the history are
    /// read tolerantly, so a hand-edited or runaway figure is clamped to
    /// a year rather than trapping the Int conversion.
    static func duration(_ seconds: Double) -> String {
        let s = Int((seconds.isFinite ? min(max(seconds, 0), maxDuration) : 0).rounded())
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The longest span `duration` will spell out.
    static let maxDuration: Double = 365 * 86_400
}

/// The card itself: the buddy standing still in its content pose, its
/// name and kind, and the log in a few calm lines. One heart, never a
/// row of them — a relationship is not a meter.
struct BuddyCardView: View {
    let character: BuddyCharacter
    let name: String
    let card: BuddyPalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BuddyFigure(character: character, mood: .pacing, tint: .accentColor,
                            phase: 0, hopProgress: nil, waveAge: nil, slumpAge: nil,
                            leans: false, still: true, askCount: 0, care: .content,
                            trick: nil, treatAge: nil, crumbAge: nil, stage: card.stage)
                    .frame(width: 18, height: 18)
                    .scaleEffect(1.6)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(character.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label(card.feeling, systemImage: "heart.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.pink)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let since = card.since { line(since) }
                line(card.growth)
                line(card.tally)
                if let favourite = card.favourite { line(favourite) }
                if let longestAsk = card.longestAsk { line(longestAsk) }
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The pal card's window: a small floating card under the buddy, like
/// the rename prompt — borderless, non-activating, gone on a click
/// elsewhere or Escape.
@MainActor
final class BuddyCardPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var resignObserver: (any NSObjectProtocol)?

    init() {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 250, height: 120))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        super.init(contentRect: NSRect(x: 0, y: 0, width: 250, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = effect
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Open under `frame` (the pill's), clamped onto its screen.
    func present(near frame: NSRect?, character: BuddyCharacter, name: String, card: BuddyPalCard) {
        hosting.rootView = AnyView(BuddyCardView(character: character, name: name, card: card))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let anchor = frame ?? NSRect(x: NSScreen.main.map { $0.visibleFrame.midX } ?? 400,
                                     y: NSScreen.main.map { $0.visibleFrame.maxY - 60 } ?? 700,
                                     width: 40, height: 30)
        let anchorPoint = NSPoint(x: anchor.midX, y: anchor.minY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchorPoint) }
            ?? ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 6, dy: 6)
        let centre = BuddyPlacement.clampedCenter(
            CGPoint(x: anchor.midX, y: anchor.minY - 8 - size.height / 2),
            size: size, inside: visible)
        setFrame(NSRect(x: (centre.x - size.width / 2).rounded(),
                        y: (centre.y - size.height / 2).rounded(),
                        width: size.width, height: size.height), display: true)
        orderFrontRegardless()
        makeKey()
    }
}
