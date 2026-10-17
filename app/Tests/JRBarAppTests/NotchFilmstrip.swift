import AppKit
import Foundation
import JRBarCore

/// A motion filmstrip: the island's silhouette and content at evenly
/// spaced moments of one scripted move, as numbers first and pictures
/// second, so motion can be judged without a live screen.
///
/// The script is the real thing played on an injected clock: the frame
/// spring (`NotchFrameSpring`) with the springs `NotchMotion.frameMotion`
/// picks for each change, the silhouette's corner and shoulder read off
/// the same `NotchSilhouetteGeometry` the view draws, and the content's
/// opacity, blur and scale read off `NotchReveal` of the shape's own
/// travel. Nothing here reads a wall clock. The numbers go to a CSV; the
/// renderer (`NotchFilmstripRender.swift`) draws the real view at the
/// same sampled sizes.
struct NotchFilmstrip {
    /// The hardware and the faces a script moves between: a 14-inch
    /// MacBook Pro's notch unless a render proof measures its own card.
    struct Geometry {
        var slot: CGFloat = 185
        var depth: CGFloat = 32
        var restingRadius: CGFloat = 8
        var card = CGSize(width: 320, height: 422)
        var notice: CGSize
        var ask: CGSize
        /// The resting island with the Now Playing strip in its shoulder.
        var mediaIdle: CGSize
        /// The same strip after the next track (the width does not depend on its title).
        var mediaIdleNext: CGSize

        var idle: CGSize { CGSize(width: slot, height: depth) }
        /// The bare housing's hover swell: straight down, never sideways.
        var peekBare: CGSize { NotchIslandLayout.peekAdjusted(idle, bare: true) }

        static func standard() -> Geometry {
            let slot: CGFloat = 185
            let depth: CGFloat = 32
            let notice = NotchIslandLayout.noticeSize(slotWidth: slot, notchDepth: depth)
            let ask = NotchIslandLayout.askSize(slotWidth: slot, notchDepth: depth,
                                                summaryLines: 1, takeover: false)
            // A playing track alone: the cover left of the notch, the waveform right of it.
            let layout = NotchIsland.idleLayout(NotchIslandSummary(), media: AlcoveMedia(title: "Ligeti", playing: true),
                                                earsDrawn: false)
            let shoulder = layout.windowShoulder
            let media = NotchIslandLayout.idleSize(slotWidth: slot, notchDepth: depth,
                                                   leftShoulder: shoulder, rightShoulder: shoulder)
            // The strip carries no title, so the next track's longer one changes nothing about its width.
            return Geometry(notice: notice, ask: ask, mediaIdle: media, mediaIdleNext: media)
        }
    }

    /// What decides when a move begins.
    enum Trigger {
        /// This many seconds into the script.
        case at(Double)
        /// The first moment the shape's openness crosses this value, in
        /// whichever direction it is travelling.
        case crossing(CGFloat)
    }

    struct Move {
        var trigger: Trigger
        var to: CGSize
    }

    /// What rides inside the shape.
    enum Content {
        /// The grown card's sheet (`NotchReveal.sheet`).
        case card
        /// A notice or an ask face (`NotchReveal.notice`, by the same clock as the card's).
        case notice
        /// A track's title and cover crossfading (`NotchMotion.trackSwap`).
        case trackSwap
        /// The marks swelling with the hover (`NotchMotion.hoverMarks`).
        case hoverMarks
    }

    struct Script {
        var name: String
        var title: String
        var start: CGSize
        var moves: [Move]
        /// The two ends the content's openness runs between.
        var morph: NotchMorph
        var content: Content
        /// Seconds to play, from the first move's start.
        var duration: Double
    }

    /// One moment of a script.
    struct Sample {
        var t: Double
        var size: CGSize
        /// The shape's top edge in screen y (up); the island hangs from
        /// the screen's top, so this is 0 whenever nothing is wrong.
        var topEdge: CGFloat
        var velocity: CGSize
        var openness: CGFloat
        var radius: CGFloat
        var flare: CGFloat
        var contentOpacity: CGFloat
        var contentBlur: CGFloat
        var contentScale: CGFloat
        /// The card's content clock (`NotchContentClock`); the shape's
        /// openness stands in for it when the script plays the old rule.
        var contentLevel: CGFloat
        var shadow: CGFloat
        var footFade: CGFloat
    }

    let geometry: Geometry
    /// Whether the card's content runs on its own clock (the island's
    /// rule) or is a pure function of the shape's travel (the rule before
    /// it, and `jrbar.notchStagedMotion` off).
    let directional: Bool
    /// The simulation's step. Fine, so a peak is never missed between
    /// samples; the spring itself is exact at any step.
    static let step = 1.0 / 480

    init(geometry: Geometry = .standard(), directional: Bool = true) {
        self.geometry = geometry
        self.directional = directional
    }

    static func rect(_ size: CGSize) -> CGRect {
        CGRect(x: -size.width / 2, y: -size.height, width: size.width, height: size.height)
    }

    // MARK: Scripts

    private func cardMorph() -> NotchMorph {
        NotchMorph(rest: geometry.depth, open: geometry.card.height,
                   restWidth: geometry.slot, openWidth: geometry.card.width)
    }

    private func noticeMorph(to size: CGSize) -> NotchMorph {
        NotchMorph(rest: geometry.depth, open: size.height, restWidth: geometry.slot, openWidth: size.width)
    }

    /// Every scenario the proof plays, in the order it writes them.
    var scripts: [Script] {
        let g = geometry
        let card = cardMorph()
        return [
            Script(name: "open", title: "OPEN  rest -> card", start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.card)], morph: card, content: .card, duration: 0.45),
            Script(name: "close", title: "CLOSE  card -> rest", start: g.card,
                   moves: [Move(trigger: .at(0), to: g.idle)], morph: card, content: .card, duration: 0.30),
            Script(name: "interrupted-open", title: "INTERRUPTED OPEN  leaves at 40%, folds home",
                   start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.card), Move(trigger: .crossing(0.4), to: g.idle)],
                   morph: card, content: .card, duration: 0.45),
            Script(name: "interrupted-close", title: "INTERRUPTED CLOSE  re-enters at 40%, opens again",
                   start: g.card,
                   moves: [Move(trigger: .at(0), to: g.idle), Move(trigger: .crossing(0.4), to: g.card)],
                   morph: card, content: .card, duration: 0.50),
            Script(name: "notice-in", title: "NOTICE IN  rest -> one-line notice", start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.notice)], morph: noticeMorph(to: g.notice),
                   content: .notice, duration: 0.35),
            Script(name: "notice-out", title: "NOTICE OUT  notice -> rest", start: g.notice,
                   moves: [Move(trigger: .at(0), to: g.idle)], morph: noticeMorph(to: g.notice),
                   content: .notice, duration: 0.35),
            Script(name: "ask-arrive", title: "ASK ARRIVES  rest -> ask with verbs", start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.ask)], morph: noticeMorph(to: g.ask),
                   content: .notice, duration: 0.45),
            Script(name: "track-change", title: "TRACK CHANGE  the strip holds its width, the cover crossfades",
                   start: g.mediaIdle,
                   moves: [Move(trigger: .at(0), to: g.mediaIdleNext)],
                   morph: NotchMorph(rest: g.depth, open: g.depth + 1, restWidth: g.mediaIdle.width,
                                     openWidth: g.mediaIdleNext.width),
                   content: .trackSwap, duration: 0.30),
            Script(name: "media-expand", title: "MEDIA EXPAND  strip -> card", start: g.mediaIdle,
                   moves: [Move(trigger: .at(0), to: g.card)],
                   morph: NotchMorph(rest: g.depth, open: g.card.height,
                                     restWidth: g.mediaIdle.width, openWidth: g.card.width),
                   content: .card, duration: 0.45),
            Script(name: "hover-swell", title: "HOVER SWELL  pointer arrives, island leans", start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.peekBare)],
                   morph: NotchMorph(rest: g.depth, open: g.peekBare.height,
                                     restWidth: g.slot, openWidth: g.peekBare.width),
                   content: .hoverMarks, duration: 0.30),
            Script(name: "hover-then-open", title: "HOVER THEN OPEN  swell, then the dwell opens the card",
                   start: g.idle,
                   moves: [Move(trigger: .at(0), to: g.peekBare), Move(trigger: .at(0.12), to: g.card)],
                   morph: card, content: .card, duration: 0.45),
        ]
    }

    // MARK: Playing a script

    /// The script played densely: one sample per `step`.
    func play(_ script: Script) -> [Sample] {
        var spring = NotchFrameSpring(at: Self.rect(script.start))
        var pending = script.moves
        var samples: [Sample] = []
        var shadow: CGFloat = NotchShadow.casts(height: script.start.height, notchDepth: geometry.depth) ? 1 : 0
        var castsAtTarget = shadow > 0
        var armed = false
        var previousSide: CGFloat?
        var t = 0.0
        var firstStart: Double?
        let end = script.duration + (script.moves.compactMap { move -> Double? in
            if case .at(let at) = move.trigger { return at }
            return nil
        }.max() ?? 0)
        func openness(_ spring: NotchFrameSpring) -> CGFloat {
            script.morph.openness(size: spring.frame.size)
        }
        // The card's content clock, aimed the way the shape is going.
        var expanded = openness(spring) >= 0.5
        var clock = NotchContentClock(level: expanded ? 1 : 0)
        while t <= end + 1e-9 {
            // Fire every move that is due.
            while let next = pending.first {
                var fire = false
                switch next.trigger {
                case .at(let at): fire = t + 1e-9 >= at
                case .crossing(let level):
                    let side = openness(spring) - level
                    if let previous = previousSide, (previous < 0) != (side < 0) || side == 0 { fire = true }
                    previousSide = side
                }
                guard fire else { break }
                pending.removeFirst()
                let target = Self.rect(next.to)
                spring.retarget(target, motion: NotchFrameSpring.motion(from: spring.frame, to: target))
                castsAtTarget = NotchShadow.casts(height: next.to.height, notchDepth: geometry.depth)
                expanded = script.morph.openness(size: next.to) >= 0.5
                armed = true
                if firstStart == nil { firstStart = t }
            }
            let frame = spring.frame
            let size = frame.size
            let open = openness(spring)
            let (opacity, blur, scale) = content(script, spring: spring, level: clock.level,
                                                 since: firstStart.map { t - $0 } ?? 0)
            samples.append(Sample(
                t: t, size: size, topEdge: frame.maxY, velocity: spring.velocity, openness: open,
                radius: NotchSilhouetteGeometry.radius(size: size, notchDepth: geometry.depth,
                                                       restingRadius: geometry.restingRadius),
                flare: NotchSilhouetteGeometry.topFlare(size: size, notchWidth: geometry.slot,
                                                        notchDepth: geometry.depth),
                contentOpacity: opacity, contentBlur: blur, contentScale: scale,
                contentLevel: directional ? clock.level : open, shadow: shadow,
                footFade: NotchReveal.footFade(shapeHeight: size.height, contentHeight: script.morph.open)))
            spring.integrate(dt: Self.step)
            clock.aim(open: expanded)
            clock.advance(dt: Self.step)
            // The window snaps the content home when the shape lands.
            if armed, spring.settled { clock.snap() }
            t += Self.step
            // The shadow arrives once the shape has landed and lets go
            // as a move toward the bezel begins.
            let moving = armed && !spring.settled
            if castsAtTarget, !moving {
                shadow = min(1, shadow + CGFloat(Self.step / NotchShadow.fadeIn))
            } else if !castsAtTarget {
                shadow = max(0, shadow - CGFloat(Self.step / NotchShadow.fadeOut))
            }
        }
        return samples
    }

    private func content(_ script: Script, spring: NotchFrameSpring, level: CGFloat, since: Double)
        -> (opacity: CGFloat, blur: CGFloat, scale: CGFloat) {
        let open = script.morph.openness(size: spring.frame.size)
        switch script.content {
        case .card:
            let sheet = directional ? NotchReveal.sheet(level: level) : NotchReveal.sheet(openness: open)
            let fit = directional
                ? NotchReveal.fit(shapeWidth: spring.frame.width, cardWidth: geometry.card.width) : 1
            return (sheet.opacity, sheet.blur, min(sheet.scale, fit))
        case .notice:
            let sheet = directional
                ? NotchReveal.notice(level: min(level, NotchReveal.noticeGate(openness: open)))
                : NotchReveal.notice(openness: open)
            let fit = directional
                ? NotchReveal.fit(shapeWidth: spring.frame.width, cardWidth: script.morph.openWidth ?? 1) : 1
            return (sheet.opacity, sheet.blur, fit)
        case .trackSwap:
            // The incoming words' share, which comes in as the outgoing
            // ones leave (`NotchMotion.trackSwapLevels`).
            return (NotchMotion.trackSwapLevels(since: since).incoming, 0, 1)
        case .hoverMarks:
            let swell = NotchMotion.hoverMarks.step(at: since)
            return (1, 0, 1 + (NotchMotion.hoverContentScale - 1) * swell)
        }
    }

    /// `count` samples evenly spaced from 0 to the script's end.
    func film(_ script: Script, count: Int) -> [Sample] {
        let dense = play(script)
        guard count > 1, dense.count > 1 else { return dense }
        return (0..<count).map { index in
            dense[Int((Double(index) / Double(count - 1) * Double(dense.count - 1)).rounded())]
        }
    }

    // MARK: Output

    static let csvHeader = "t_ms,width,height,top_edge,corner_radius,top_flare,openness,"
        + "content_opacity,content_blur,content_scale,content_level,shadow,foot_fade,width_velocity,height_velocity"

    static func csv(_ samples: [Sample]) -> String {
        func f(_ v: CGFloat, _ places: Int = 3) -> String { String(format: "%.\(places)f", Double(v)) }
        var lines = [csvHeader]
        for s in samples {
            lines.append([String(format: "%.1f", s.t * 1000), f(s.size.width), f(s.size.height), f(s.topEdge, 4),
                          f(s.radius), f(s.flare), f(s.openness, 4), f(s.contentOpacity, 4), f(s.contentBlur),
                          f(s.contentScale, 4), f(s.contentLevel, 4), f(s.shadow, 4), f(s.footFade, 2), f(s.velocity.width, 1), f(s.velocity.height, 1)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What a reviewer asks of a move, reduced to numbers.
    struct Metrics {
        /// The most the top edge ever left the screen's edge, in points.
        var topEdgeDrift: CGFloat
        /// The furthest the shape went past where it ended, as a share
        /// of the travel, outward (positive) and inward (negative: under
        /// the resting size or inside the card).
        var overshootOutward: CGFloat
        var overshootInward: CGFloat
        /// The biggest step in one 1/120 s of the corner radius, the
        /// content's opacity, and the shape's height.
        var radiusStep: CGFloat
        var opacityStep: CGFloat
        var heightStep: CGFloat
        /// The first moment the height has covered 90% of its way, ms.
        var heightAt90: Double?
        /// When the content is fully in (opacity 0.99) or fully out
        /// (0.01) for good, ms from the start; nil when it never is.
        var contentSettled: Double?
        var peakHeightSpeed: CGFloat
    }

    static func metrics(_ samples: [Sample]) -> Metrics {
        guard let first = samples.first, let last = samples.last else {
            return Metrics(topEdgeDrift: 0, overshootOutward: 0, overshootInward: 0, radiusStep: 0,
                           opacityStep: 0, heightStep: 0, heightAt90: nil, contentSettled: nil,
                           peakHeightSpeed: 0)
        }
        let h0 = first.size.height
        let h1 = last.size.height
        let span = (samples.map(\.size.height).max() ?? h1) - (samples.map(\.size.height).min() ?? h0)
        // The direction it ends up going; a script that returns to where it began has no net travel,
        // so its overshoot is read against the span it covered.
        let travel = abs(h1 - h0) > 1 ? h1 - h0 : span
        var outward: CGFloat = 0
        var inward: CGFloat = 0
        for s in samples where abs(travel) > 1 {
            let past = (s.size.height - h1) / travel
            if past > 0 { outward = max(outward, past) }
            let before = (h0 - s.size.height) / travel
            if before > 0 { inward = max(inward, before) }
        }
        // 1/120 s windows.
        let stride = Int((1.0 / 120) / step)
        var radiusStep: CGFloat = 0
        var opacityStep: CGFloat = 0
        var heightStep: CGFloat = 0
        for index in stride..<max(stride, samples.count) {
            let a = samples[index - stride]
            let b = samples[index]
            radiusStep = max(radiusStep, abs(b.radius - a.radius))
            opacityStep = max(opacityStep, abs(b.contentOpacity - a.contentOpacity))
            heightStep = max(heightStep, abs(b.size.height - a.size.height))
        }
        let at90 = samples.first { abs(travel) > 1 && (($0.size.height - h0) / travel) >= 0.9 }?.t
        let settled: Double? = {
            let target: CGFloat = last.contentOpacity > 0.5 ? 0.99 : 0.01
            var index = samples.count - 1
            while index > 0 {
                let ok = target > 0.5 ? samples[index - 1].contentOpacity >= target
                                      : samples[index - 1].contentOpacity <= target
                if !ok { break }
                index -= 1
            }
            return samples[index].t * 1000
        }()
        return Metrics(topEdgeDrift: samples.map { abs($0.topEdge) }.max() ?? 0,
                       overshootOutward: outward, overshootInward: inward, radiusStep: radiusStep,
                       opacityStep: opacityStep, heightStep: heightStep, heightAt90: at90.map { $0 * 1000 },
                       contentSettled: settled,
                       peakHeightSpeed: samples.map { abs($0.velocity.height) }.max() ?? 0)
    }
}
