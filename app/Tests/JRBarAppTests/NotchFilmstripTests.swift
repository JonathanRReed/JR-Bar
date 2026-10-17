import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The motion filmstrip's two halves. The numbers run in every test run:
/// each scenario is played on an injected clock and held to the rules a
/// good island follows (the top edge never leaves the bezel, overshoot
/// only outward, nothing jumps, an interruption at any moment is
/// continuous in position and speed). The pictures are written only with
/// `JRBAR_RENDER_PROOF=1`: one contact sheet and two CSVs per scenario
/// (`filmstrip-<name>.png`, `.csv`, `-dense.csv`) and a `filmstrip-metrics.csv`.
@Suite("Notch motion filmstrip")
@MainActor
struct NotchFilmstripTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private let film = NotchFilmstrip()

    // MARK: Rules every scenario follows

    @Test("the top edge stays on the bezel in every scenario, interrupted or not")
    func topEdgeNeverMoves() {
        for script in film.scripts {
            let m = NotchFilmstrip.metrics(film.play(script))
            #expect(m.topEdgeDrift < 0.01, "\(script.name) drifted \(m.topEdgeDrift) pt from the bezel")
        }
    }

    @Test("a grow overshoots outward only, a fold never goes under the resting size")
    func overshootOnlyOutward() {
        for script in film.scripts {
            let samples = film.play(script)
            // The sizes the script visits as targets: the shape may pass slightly outside
            // them only outward (a few percent of the travel at most), never inward.
            let stops = [script.start] + script.moves.map(\.to)
            let low = CGSize(width: stops.map(\.width).min() ?? 0, height: stops.map(\.height).min() ?? 0)
            let high = CGSize(width: stops.map(\.width).max() ?? 0, height: stops.map(\.height).max() ?? 0)
            let travelH = max(1, high.height - low.height)
            let travelW = max(1, high.width - low.width)
            for sample in samples {
                #expect(sample.size.height >= low.height - 0.3,
                        "\(script.name) went \(low.height - sample.size.height) pt under its smallest stop")
                // A strip wider than the card narrows into it: the width spring may pass its
                // narrower target by a few percent of its travel, in either direction.
                #expect(sample.size.width >= low.width - travelW * 0.04 - 0.3,
                        "\(script.name) went \(low.width - sample.size.width) pt narrower than its smallest stop")
                #expect(sample.size.height <= high.height + travelH * 0.04 + 0.3,
                        "\(script.name) overshoots its largest stop by \(sample.size.height - high.height)")
                #expect(sample.size.width <= high.width + travelW * 0.04 + 0.3,
                        "\(script.name) overshoots its widest stop by \(sample.size.width - high.width)")
            }
        }
    }

    @Test("corner, shoulder and content change smoothly: no step is a jump")
    func nothingJumps() {
        for script in film.scripts {
            let samples = film.play(script)
            let m = NotchFilmstrip.metrics(samples)
            // Per 1/120 s: a corner under 3.5 pt, content under a fifth of its range, height under 8% of
            // the card's travel.
            #expect(m.radiusStep < 3.5, "\(script.name) corner stepped \(m.radiusStep) pt in one frame")
            #expect(m.opacityStep < 0.35, "\(script.name) content stepped \(m.opacityStep) in one frame")
            #expect(m.heightStep < film.geometry.card.height * 0.08,
                    "\(script.name) height stepped \(m.heightStep) pt in one frame")
            var worstFlare: CGFloat = 0
            for (a, b) in zip(samples, samples.dropFirst()) {
                worstFlare = max(worstFlare, abs(b.flare - a.flare))
            }
            #expect(worstFlare < 0.5, "\(script.name) shoulder stepped \(worstFlare) pt in 1/480 s")
        }
    }

    @Test("the corner follows the shape, not the clock: equal sizes wear equal corners")
    func cornerIsAFunctionOfSize() {
        for script in film.scripts where script.content == .card {
            let samples = film.play(script)
            for a in samples.indices.filter({ $0 % 7 == 0 }) {
                for b in samples.indices.filter({ $0 % 11 == 0 }) where
                    abs(samples[a].size.height - samples[b].size.height) < 0.01
                        && abs(samples[a].size.width - samples[b].size.width) < 0.01 {
                    #expect(abs(samples[a].radius - samples[b].radius) < 1e-6)
                }
            }
        }
    }

    // MARK: The content's clock, before and after

    /// The first moment the content shows `level` of itself in `samples`.
    private func firstTime(_ samples: [NotchFilmstrip.Sample], opacityAtLeast level: CGFloat) -> Double? {
        samples.first { $0.contentOpacity >= level }?.t
    }

    @Test("open: content is visible within 25 ms where the old rule took 90 ms")
    func openContentArrivesEarly() throws {
        let script = try #require(film.scripts.first { $0.name == "open" })
        let after = film.play(script)
        let before = NotchFilmstrip(geometry: film.geometry, directional: false).play(script)
        let now = try #require(firstTime(after, opacityAtLeast: 0.1))
        let then = try #require(firstTime(before, opacityAtLeast: 0.1))
        #expect(now < 0.025, "content at 10% by \(now * 1000) ms")
        #expect(then > 0.07, "the rule before it: \(then * 1000) ms")
        let sharp = try #require(firstTime(after, opacityAtLeast: 0.99))
        let wasSharp = try #require(firstTime(before, opacityAtLeast: 0.99))
        #expect(sharp < wasSharp, "and whole sooner: \(sharp * 1000) ms against \(wasSharp * 1000)")
        #expect(NotchFilmstrip.metrics(after).opacityStep < 0.35, "still no jump in a frame")
    }

    @Test("close: content remains in the early frames and clears before landing")
    func closeLeavesFirst() throws {
        let script = try #require(film.scripts.first { $0.name == "close" })
        let after = film.play(script)
        let before = NotchFilmstrip(geometry: film.geometry, directional: false).play(script)
        func contentAt(_ samples: [NotchFilmstrip.Sample], ms: Double) -> CGFloat {
            samples.first { $0.t * 1000 >= ms }?.contentOpacity ?? 1
        }
        #expect(contentAt(after, ms: 30) > 0.4, "the early fold must not be an empty black card")
        #expect(contentAt(before, ms: 30) > 0.8, "the rule before it held \(contentAt(before, ms: 30))")
        #expect(contentAt(after, ms: 90) < 0.1, "content clears while the shape is still folding")
        // Nothing is left to be seen in the last stretch of the fold.
        let emptyShape = after.filter { $0.openness < 0.15 && $0.openness > 0.02 }
        #expect(!emptyShape.isEmpty && emptyShape.allSatisfy { $0.contentOpacity < 0.05 },
                "the shape falls away without content")
    }

    @Test("a notice enters early and clears before the lip lands")
    func noticeArrivesAndLeavesEarly() throws {
        let inScript = try #require(film.scripts.first { $0.name == "notice-in" })
        let outScript = try #require(film.scripts.first { $0.name == "notice-out" })
        let old = NotchFilmstrip(geometry: film.geometry, directional: false)
        let now = try #require(firstTime(film.play(inScript), opacityAtLeast: 0.1))
        let was = try #require(firstTime(old.play(inScript), opacityAtLeast: 0.1))
        // The lip has to be a fifth down before the line may show (`noticeGate`), then it is quick.
        #expect(now < 0.06, "the words are coming in by \(now * 1000) ms")
        #expect(was > 0.07 && now < was - 0.02, "the rule before it: \(was * 1000) ms")
        // The notice remains through the early fold and clears before landing.
        let out = film.play(outScript)
        let gone = try #require(out.first { $0.contentOpacity < 0.05 })
        #expect(gone.openness > 0.1 && gone.openness < 0.4, "gone before landing, at \(gone.openness) openness")
        #expect(NotchFilmstrip.metrics(out).opacityStep < 0.35 && NotchFilmstrip.metrics(film.play(inScript)).opacityStep < 0.35)
    }

    @Test("reversing mid-open or mid-close, the content's level is continuous and ends where it should")
    func reversalsKeepTheContentContinuous() throws {
        for name in ["interrupted-open", "interrupted-close"] {
            let script = try #require(film.scripts.first { $0.name == name })
            let samples = film.play(script)
            var worst: CGFloat = 0
            for (a, b) in zip(samples, samples.dropFirst()) {
                worst = max(worst, abs(b.contentLevel - a.contentLevel))
            }
            #expect(worst < 0.07, "\(name) stepped \(worst) in 1/480 s")
            #expect(NotchFilmstrip.metrics(samples).opacityStep < 0.35)
            let last = try #require(samples.last)
            #expect(last.contentOpacity == (name == "interrupted-open" ? 0 : 1),
                    "ends whole or gone: \(last.contentOpacity)")
        }
    }

    // MARK: Interruption

    /// A grow interrupted at `at`, played with the content and corner
    /// derived at every step.
    private func interrupted(at t: Double, opening: Bool) -> [NotchFilmstrip.Sample] {
        let g = film.geometry
        let (from, to) = opening ? (g.idle, g.card) : (g.card, g.idle)
        let morph = NotchMorph(rest: g.depth, open: g.card.height, restWidth: g.slot, openWidth: g.card.width)
        let script = NotchFilmstrip.Script(
            name: "interrupt", title: "", start: from,
            moves: [.init(trigger: .at(0), to: to), .init(trigger: .at(t), to: from)],
            morph: morph, content: .card, duration: 0.5)
        return film.play(script)
    }

    @Test("a retarget at any moment keeps the frame and the speed it had, exactly")
    func retargetKeepsPositionAndVelocity() {
        let g = film.geometry
        for opening in [true, false] {
            let (from, to) = opening ? (g.idle, g.card) : (g.card, g.idle)
            for k in 1...100 {
                var spring = NotchFrameSpring(at: NotchFilmstrip.rect(from))
                spring.retarget(NotchFilmstrip.rect(to),
                                motion: NotchFrameSpring.motion(from: spring.frame, to: NotchFilmstrip.rect(to)))
                spring.integrate(dt: Double(k) * 0.004)
                let frame = spring.frame
                let speed = spring.velocity
                let back = NotchFilmstrip.rect(from)
                spring.retarget(back, motion: NotchFrameSpring.motion(from: frame, to: back))
                #expect(spring.frame == frame, "position jumped at \(k * 4) ms")
                #expect(spring.velocity == speed, "speed jumped at \(k * 4) ms")
            }
        }
    }

    @Test("interrupting at any moment is smooth in position, speed and what hangs from them")
    func interruptionIsContinuousEverywhere() {
        let g = film.geometry
        // The most a spring can change its own speed in one step: its stiffest axis (the fold's
        // own response) times the card's whole travel. A discontinuity at the retarget would be
        // the speed itself, thousands of points a second, in one step.
        let stiffest = Double(min(NotchMotion.close.response, NotchMotion.open.response * NotchMotion.widthLead))
        let omega = 2 * Double.pi / stiffest
        let travel = g.card.height - g.depth
        let speedBound = CGFloat(omega * omega * Double(travel) * NotchFilmstrip.step * 1.15)
        for opening in [true, false] {
            for k in 1...75 {
                let t = Double(k) * 0.006
                let samples = interrupted(at: t, opening: opening)
                var worstSpeedJump: CGFloat = 0
                var worstHeightStep: CGFloat = 0
                var worstRadius: CGFloat = 0
                var worstOpacity: CGFloat = 0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    worstSpeedJump = max(worstSpeedJump, abs(b.velocity.height - a.velocity.height),
                                         abs(b.velocity.width - a.velocity.width))
                    worstHeightStep = max(worstHeightStep, abs(b.size.height - a.size.height))
                    worstRadius = max(worstRadius, abs(b.radius - a.radius))
                    worstOpacity = max(worstOpacity, abs(b.contentOpacity - a.contentOpacity))
                }
                let label = "\(opening ? "open" : "close") interrupted at \(t)"
                #expect(worstSpeedJump < speedBound, "\(label): speed jumped \(worstSpeedJump) (bound \(speedBound))")
                // Peak speed is about ten travels a second: 1/480 s of it is a fiftieth of the travel.
                #expect(worstHeightStep < travel * 0.03, "\(label): height stepped \(worstHeightStep)")
                #expect(worstRadius < 0.8, "\(label): corner stepped \(worstRadius)")
                #expect(worstOpacity < 0.12, "\(label): content stepped \(worstOpacity)")
                let topDrift = samples.map { abs($0.topEdge) }.max() ?? 0
                #expect(topDrift < 0.01, "\(label): top edge left the bezel by \(topDrift)")
            }
        }
    }

    @Test("a reversal that begins mid-flight never sends the shape the wrong way for a frame")
    func reversalTurnsAroundSmoothly() {
        // The speed passes through zero on its way from opening to
        // closing: it does not skip across it in one step.
        let samples = interrupted(at: 0.08, opening: true)
        var sawPositive = false
        var sawNegative = false
        var previous = samples[0].velocity.height
        for sample in samples.dropFirst() {
            if sample.velocity.height > 50 { sawPositive = true }
            if sample.velocity.height < -50 { sawNegative = true }
            #expect(abs(sample.velocity.height - previous) < 700)
            previous = sample.velocity.height
        }
        #expect(sawPositive && sawNegative, "it opened, then folded")
    }

    // MARK: The pictures

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs and CSVs"))
    func writeEveryFilmstrip() throws {
        let measured = NotchFilmstrip(geometry: NotchFilmstripRender.geometry())
        var summary = "scenario,top_edge_drift,overshoot_out,overshoot_in,radius_step,opacity_step,height_step,"
            + "height_90_ms,content_settled_ms,peak_height_speed\n"
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        for script in measured.scripts {
            try NotchFilmstripRender.write(script, film: measured, outputName: "filmstrip-\(script.name)")
            let m = NotchFilmstrip.metrics(measured.play(script))
            // Overshoot is read against one move's travel; an interrupted script has several.
            let single = script.moves.count == 1
            summary += String(format: "%@,%.4f,%@,%@,%.3f,%.3f,%.2f,%@,%@,%.0f\n", script.name,
                              Double(m.topEdgeDrift),
                              single ? String(format: "%.4f", Double(m.overshootOutward)) : "n/a",
                              single ? String(format: "%.4f", Double(m.overshootInward)) : "n/a",
                              Double(m.radiusStep), Double(m.opacityStep), Double(m.heightStep),
                              m.heightAt90.map { String(format: "%.0f", $0) } ?? "-",
                              m.contentSettled.map { String(format: "%.0f", $0) } ?? "-",
                              Double(m.peakHeightSpeed))
        }
        try summary.write(to: ProofRender.directory.appendingPathComponent("filmstrip-metrics.csv"),
                          atomically: true, encoding: .utf8)
    }
}
