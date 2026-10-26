import JRBarCore
import SwiftUI

/// What the island's window tells its view while the island moves.
///
/// During a morph the window is a stage and the shape moves inside it
/// (`NotchStage`): `shape` is where, in the stage's own coordinates, and
/// nil whenever the window is the shape. `openness` is how far the shape
/// has travelled between the resting island and the grown card: the one
/// clock the card's content reads (`NotchReveal`). Each is written by the
/// window on its display link and read by one tiny modifier below, so a
/// tick re-evaluates that modifier and nothing else: the faces, the card
/// and its rows keep their bodies.
@MainActor
@Observable
final class NotchStageModel {
    /// The shape on the stage, top-left origin, y down; nil when the
    /// window itself is the shape.
    var shape: CGRect?
    /// The two ends of a notice's drop: the resting island and the
    /// notice's own frame. nil while no notice or ask has a frame.
    var noticeMorph: NotchMorph?
    /// The height the grown card's frame lands at: how tall the content
    /// the shape uncovers is (`NotchReveal.footFade` reads it).
    var cardHeight: CGFloat?
    /// And how wide: the sheet is laid out at this width and stands as
    /// wide as the shape while the shape is narrower (`NotchReveal.fit`).
    var cardWidth: CGFloat?
    /// 0 at the resting island, 1 at the grown card.
    private(set) var openness: CGFloat = 0
    /// The card is on stage: grown, or still folding out of sight. The
    /// island's body reads this, and it only changes at the two ends.
    private(set) var cardStaged = false

    /// How resolved the card's content is, on its own clock
    /// (`NotchContentClock`): it starts with the shape and, on a fold,
    /// leaves ahead of it. nil is the old rule, content as a pure
    /// function of the shape's travel (`jrbar.notchStagedMotion` off, or
    /// a caller that only knows the shape).
    private(set) var content: NotchContentClock?

    /// The same clock for a notice's or an ask's face, aimed at whether one
    /// is up. nil under the old rule.
    private(set) var noticeClock: NotchContentClock?

    init(directional: Bool = true) {
        content = directional ? NotchContentClock() : nil
        noticeClock = directional ? NotchContentClock() : nil
    }

    /// One tick of the window's move, `dt` long: the notice's clock moves
    /// toward whether a notice is up (`shown`).
    func tickNotice(dt: TimeInterval, shown: Bool) {
        guard var clock = noticeClock else { return }
        clock.aim(open: shown)
        clock.advance(dt: dt)
        if clock != noticeClock { noticeClock = clock }
    }

    /// A caller that draws a still puts the notice at a level directly.
    func showNotice(level: CGFloat, shown: Bool) {
        guard noticeClock != nil else { return }
        var clock = NotchContentClock(level: level)
        clock.aim(open: shown)
        noticeClock = clock
    }

    /// No move is carrying the notice: it is there or it is not.
    func settleNotice(shown: Bool) {
        guard var clock = noticeClock else { return }
        clock.snap(open: shown)
        if clock != noticeClock { noticeClock = clock }
    }

    /// How a notice or ask face is scaled while the shape is narrower than
    /// the width the face is laid out at (`NotchReveal.fit`).
    var noticeFit: CGFloat {
        guard noticeClock != nil, let shape, let width = noticeMorph?.openWidth else { return 1 }
        return NotchReveal.fit(shapeWidth: shape.width, cardWidth: width)
    }

    /// The window's per-tick report. Equal values are not re-published,
    /// so a landed spring costs nothing. `dt` is the tick's length: the
    /// content's clock moves by it toward whichever way the card is
    /// going (`expanded`), the same tick the shape does.
    func setOpenness(_ value: CGFloat, expanded: Bool, dt: TimeInterval = 0) {
        let clamped = min(1, max(0, value))
        if openness != clamped { openness = clamped }
        let staged = NotchReveal.staged(expanded: expanded, openness: clamped)
        if cardStaged != staged { cardStaged = staged }
        guard var clock = content else { return }
        clock.aim(open: expanded)
        clock.advance(dt: dt)
        if clock != content { content = clock }
    }

    /// A caller that draws a still (a render proof, a test) puts the
    /// content at a level directly.
    func showContent(level: CGFloat, expanded: Bool) {
        guard content != nil else { return }
        var clock = NotchContentClock(level: level)
        clock.aim(open: expanded)
        content = clock
    }

    /// The card's sheet right now: the content's clock when it has one,
    /// else the shape's travel.
    var sheet: NotchReveal.Sheet {
        if let content { return NotchReveal.sheet(level: content.level) }
        return NotchReveal.sheet(openness: openness)
    }

    /// The scale that keeps the sheet inside the shape's sides while the
    /// shape is narrower than the card. 1 when the window is the shape,
    /// and under the old rule.
    var contentFit: CGFloat {
        guard content != nil, let shape, let cardWidth else { return 1 }
        return NotchReveal.fit(shapeWidth: shape.width, cardWidth: cardWidth)
    }

    /// One row's opacity at its step in the cascade.
    func row(step: Int) -> CGFloat {
        if let content { return NotchReveal.row(step: step, level: content.level) }
        return NotchReveal.row(step: step, openness: openness)
    }

    /// What a notice's face wears right now. While the shape moves on a
    /// stage it is the shape's own travel toward (or away from) the
    /// notice's frame; otherwise (the shape at rest, the old per-tick
    /// resize, an unseen window) there is nothing to follow and `shown`
    /// says whether it is there.
    func noticeSheet(shown: Bool) -> NotchReveal.Sheet {
        guard let shape, let morph = noticeMorph else {
            return shown ? .settled : NotchReveal.notice(openness: 0)
        }
        if let noticeClock {
            let gate = NotchReveal.noticeGate(openness: morph.openness(size: shape.size))
            return NotchReveal.notice(level: min(noticeClock.level, gate))
        }
        return NotchReveal.notice(openness: morph.openness(size: shape.size))
    }

    /// The face changed: `settled` puts the card straight at its end
    /// (open or gone); otherwise the window's ticks carry it there.
    func noteFace(expanded: Bool, settled: Bool) {
        setOpenness(settled ? (expanded ? 1 : 0) : openness, expanded: expanded)
        guard content != nil else { return }
        if settled {
            var clock = content ?? NotchContentClock()
            clock.snap(open: expanded)
            if clock != content { content = clock }
        }
    }
}

private struct NotchStageKey: EnvironmentKey {
    static let defaultValue: NotchStageModel? = nil
}

extension EnvironmentValues {
    /// The island's stage, for the card's content to read its reveal
    /// from. nil on the glass card, which is simply there.
    var notchStage: NotchStageModel? {
        get { self[NotchStageKey.self] }
        set { self[NotchStageKey.self] = newValue }
    }
}

/// Seats the island's content on its stage: the shape's size at the
/// shape's place while a morph runs, the whole window otherwise. Always
/// the same view structure, so the tree keeps its identity (and the
/// card its scroll position) as the stage comes and goes.
struct NotchStageFrame: ViewModifier {
    let stage: NotchStageModel

    func body(content: Content) -> some View {
        let shape = stage.shape
        content
            .frame(width: shape?.width, height: shape?.height)
            .offset(x: shape?.minX ?? 0, y: shape?.minY ?? 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The shape moves on the spring's clock, one step per tick;
            // an implicit animation on top of it would only lag it.
            .animation(nil, value: shape)
            .transaction { transaction in
                if shape != nil {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// The card's sheet: it comes out of the notch in focus and settles
/// into place as the shape grows, and goes back the same way on the
/// fold. Opacity, a blur that clears, a scale from the top, a short lift;
/// all four are `NotchReveal.sheet` of the content's clock, which starts
/// with the shape and leaves ahead of it.
struct NotchSheetReveal: ViewModifier {
    @Environment(\.notchStage) private var stage

    func body(content: Content) -> some View {
        let sheet = stage?.sheet ?? .settled
        content
            .opacity(sheet.opacity)
            .blur(radius: sheet.blur)
            .scaleEffect(min(sheet.scale, stage?.contentFit ?? 1), anchor: .top)
            .offset(y: sheet.lift)
    }
}

/// A notice's face coming out of the notch with the shape: opacity, a
/// short blur and a few points of settle, all `NotchReveal.notice` of the
/// shape's travel, so a notice that is cut short (or replaced) mid-drop
/// goes back the way it came.
struct NotchNoticeReveal: ViewModifier {
    let stage: NotchStageModel
    /// Whether the notice is the one being shown (not its departing ghost).
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let sheet = stage.noticeSheet(shown: shown)
        if reduceMotion {
            // A quiet crossfade: no blur, no travel.
            content.opacity(sheet.opacity)
        } else {
            content
                .opacity(sheet.opacity)
                .blur(radius: sheet.blur)
                .offset(y: sheet.lift)
        }
    }
}

/// One row's place in the cascade: `NotchReveal.row` of the shape's
/// travel, on top of the sheet's. Opacity only; the blur and the scale
/// are the sheet's, once, not a dozen passes in the busiest frames.
struct NotchRowReveal: ViewModifier {
    let step: Int
    @Environment(\.notchStage) private var stage

    func body(content: Content) -> some View {
        content.opacity(stage.map { Double($0.row(step: step)) } ?? 1)
    }
}

/// The island's lower edge catching the light: a hairline inside the
/// silhouette, brightest along the foot and gone up the sides, so the
/// black body reads as a body on a dark desktop. It arrives with the
/// last of the grow and is absent on the resting island, which stays
/// exactly the bezel's black.
struct NotchEdgeLight: View {
    let stage: NotchStageModel
    let silhouette: NotchSilhouette

    /// The line's brightest point, as white at this opacity, and its
    /// width: two points, half of them clipped away by the silhouette
    /// the caller clips to, so one point of light shows.
    static let peak: Double = 0.14
    static let width: CGFloat = 2

    var body: some View {
        let strength = NotchReveal.edgeLight(openness: stage.openness)
        silhouette
            .stroke(LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: 0.45),
                .init(color: .white.opacity(Self.peak), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: Self.width)
            .opacity(strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The soft foot of a shape that is still short of its content: black
/// laid over the last few points above the lower edge, fading in toward
/// it, so the edge dissolves what it uncovers instead of cutting through
/// it. Black on the island's black costs nothing to composite (no mask,
/// no offscreen pass), and nothing is drawn once the shape has landed.
struct NotchFootFade: View {
    let stage: NotchStageModel
    /// The height of the content the shape uncovers, nil when there is
    /// none to speak of (the resting face).
    let contentHeight: CGFloat?

    var body: some View {
        let band: CGFloat = {
            guard let shape = stage.shape, let contentHeight else { return 0 }
            return NotchReveal.footFade(shapeHeight: shape.height, contentHeight: contentHeight)
        }()
        if band > 0 {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: band)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// `revealRow` for the island's card: this row's step in the cascade.
    func notchRowReveal(step: Int) -> some View {
        modifier(NotchRowReveal(step: step))
    }
}

extension NotchFrameSpring.Motion {
    /// The same spring as a SwiftUI animation, for the marks that lean
    /// with the shape.
    var animation: Animation {
        .spring(response: Double(response), dampingFraction: Double(dampingFraction))
    }
}
