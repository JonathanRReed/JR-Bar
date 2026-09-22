import CoreGraphics
import Foundation
import JRBarLEDS

/// One gradient stop for the band: location in 0...1 and premultiplied-free RGBA.
struct BandStop: Equatable {
    var location: CGFloat
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat
}

/// Port of the Screen Bar's spatial blend (`blended_led_color_at_x`,
/// `_glow_runs`, `draw_horizontal_gradient` and `tone_mapped_led_color`).
///
/// Each LED is a light source centred on its slot that fades through the
/// neighbouring slot on both sides with a raised-cosine weight, so the eight
/// samples become one continuous band with no visible segmentation. Columns
/// are 2 pt wide, quantised to 1/1024 and coalesced when identical, then fed
/// to a single horizontal gradient whose stops sit at run centres.
enum ScreenBarBlend {
    static let blendRadiusLeds: CGFloat = 1.5
    static let columnWidth: CGFloat = 2.0
    /// `alpha_scale` for the rounded band's core layer.
    static let coreAlpha: CGFloat = 0.95
    static let litThreshold: CGFloat = 0.0005

    struct Sample: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        var maxComponent: CGFloat { max(max(r, g), max(b, a)) }

        /// The same colour at alpha 0 — an unlit stop that fades along
        /// this colour instead of through black.
        var cleared: Sample { Sample(r: r, g: g, b: b, a: 0) }
    }

    /// `blended_led_color_at_x`, normalised: the raised-cosine weighted
    /// mean of the LEDs at view-local `x` (0 = band's left edge).
    ///
    /// The Python original sums the weights without dividing by them:
    /// 1.5 in the interior, 0.75 at the band's ends, then a clip per
    /// channel. That ran the interior 1.5× hot and moved the hue — Claude
    /// #D97757 came out peach (255,178,130) while the Settings preview,
    /// which paints the raw code, showed the real colour — and left the
    /// ends at half light. The mean keeps a uniform code exact end to end
    /// and a fade linear. What it costs: a lone lit LED peaks at 2/3, its
    /// light shared across three slots.
    static func blended(_ colors: [RGB], x: CGFloat, ledWidth: CGFloat) -> Sample {
        guard ledWidth > 0 else { return Sample(r: 0, g: 0, b: 0, a: 0) }
        let radius = ledWidth * blendRadiusLeds
        var totals = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var weights: CGFloat = 0
        for (index, color) in colors.enumerated() {
            let center = (CGFloat(index) + 0.5) * ledWidth
            let distance = abs(x - center)
            if distance > radius { continue }
            let weight = 0.5 + 0.5 * cos(.pi * distance / radius)
            weights += weight
            totals.r += CGFloat(color.r) * weight
            totals.g += CGFloat(color.g) * weight
            totals.b += CGFloat(color.b) * weight
            totals.a += CGFloat(color.maxChannel) * weight
        }
        guard weights > 0 else { return Sample(r: 0, g: 0, b: 0, a: 0) }
        func mean(_ v: CGFloat) -> CGFloat { min(1, max(0, v / weights)) }
        return Sample(r: mean(totals.r), g: mean(totals.g), b: mean(totals.b), a: mean(totals.a))
    }

    /// `tone_mapped_led_color`: identity on RGB, alpha becomes the layer's fixed opacity when lit.
    static func toneMapped(_ sample: Sample, alphaScale: CGFloat) -> Sample {
        let lit = max(sample.r, max(sample.g, sample.b)) > litThreshold && sample.a > litThreshold
        return Sample(r: sample.r, g: sample.g, b: sample.b, a: lit ? min(1, max(0, alphaScale)) : 0)
    }

    struct Run: Equatable {
        var x: CGFloat
        var width: CGFloat
        var color: Sample
    }

    /// `_glow_runs`: quantised, coalesced column runs across the band.
    static func runs(colors: [RGB], bandWidth: CGFloat) -> [Run?] {
        let ledWidth = bandWidth / CGFloat(max(1, colors.count))
        var runs: [Run?] = []
        var columnX: CGFloat = 0
        while columnX < bandWidth {
            let width = min(columnWidth, bandWidth - columnX)
            let sample = blended(colors, x: columnX + width / 2.0, ledWidth: ledWidth)
            if sample.maxComponent <= 0.001 {
                if let last = runs.last, last != nil { runs.append(nil) }
                columnX += width
                continue
            }
            let quantized = Sample(
                r: (sample.r * 1024).rounded() / 1024,
                g: (sample.g * 1024).rounded() / 1024,
                b: (sample.b * 1024).rounded() / 1024,
                a: (sample.a * 1024).rounded() / 1024
            )
            if let index = runs.indices.last, var last = runs[index], last.color == quantized {
                last.width += width
                runs[index] = last
            } else {
                runs.append(Run(x: columnX, width: width, color: quantized))
            }
            columnX += width
        }
        return runs
    }

    // MARK: Fixed columns (the keyframe path)

    /// Column pitch for the animated gradient. Wider than the 2 pt paint
    /// columns: the raised-cosine blend is smooth enough that a straight line
    /// between 4 pt samples is within a thousandth of it, and Core Animation
    /// interpolates every stop of every keyframe on the render server.
    static let keyframeColumnWidth: CGFloat = 4.0

    /// Stop locations that never move: one per column centre across the band.
    static func columnLocations(bandWidth: CGFloat) -> [CGFloat] {
        guard bandWidth > 0 else { return [] }
        let count = max(2, Int((bandWidth / keyframeColumnWidth).rounded(.up)))
        return (0..<count).map { index in
            let x = (CGFloat(index) + 0.5) * bandWidth / CGFloat(count)
            return x / bandWidth
        }
    }

    /// The tone-mapped blend at every column centre, in the same order as
    /// `columnLocations`. Unlit columns are fully transparent.
    static func columnSamples(colors: [RGB], bandWidth: CGFloat, alphaScale: CGFloat) -> [Sample] {
        let locations = columnLocations(bandWidth: bandWidth)
        let ledWidth = bandWidth / CGFloat(max(1, colors.count))
        return locations.map { location in
            let sample = blended(colors, x: location * bandWidth, ledWidth: ledWidth)
            let quantized = Sample(
                r: (sample.r * 1024).rounded() / 1024,
                g: (sample.g * 1024).rounded() / 1024,
                b: (sample.b * 1024).rounded() / 1024,
                a: (sample.a * 1024).rounded() / 1024
            )
            return toneMapped(quantized, alphaScale: alphaScale)
        }
    }

    // MARK: Fades that stay linear

    /// Core Animation interpolates a keyframed colour's RGB and its alpha
    /// separately, then composites: a segment from an unlit stop
    /// (0,0,0,0) to a lit (c, 0.95) shows c·t at alpha 0.95·t, so the
    /// light runs t² — a linear fade from black sat at a quarter of its
    /// light halfway (a probe measured (64,32,0) where the line is
    /// (121,60,0)). Here only alpha ramps: an unlit stop takes the RGB of
    /// the lit stop it fades out of or into, still at alpha 0, and c·α is
    /// the straight line. An unlit stop between two lit neighbours of
    /// different colours goes in twice at the same key time — the first
    /// copy ends the fade out in the old colour, the second starts the
    /// fade in with the new one — and the jump between them happens at
    /// alpha 0, where it cannot show. A column dark in its frame and in
    /// both neighbouring frames borrows from the band instead
    /// (`spatiallyFilled`). One dark across a segment but lit a frame
    /// further out keeps that frame's RGB at alpha 0 throughout: the
    /// column itself never shows it, but the 4 pt falloff beside a lit
    /// neighbour can carry a trace of its hue.
    static func keyframes(_ frames: [[Sample]], keyTimes: [Double]) -> (frames: [[Sample]], keyTimes: [Double]) {
        precondition(frames.count == keyTimes.count)
        guard frames.count > 1 else { return (frames.map(spatiallyFilled), keyTimes) }
        func litColumn(_ frame: Int, _ column: Int) -> Sample? {
            guard frames.indices.contains(frame), frames[frame].indices.contains(column) else { return nil }
            let sample = frames[frame][column]
            return sample.a > 0 ? sample : nil
        }
        var outFrames: [[Sample]] = []
        var outTimes: [Double] = []
        for (k, frame) in frames.enumerated() {
            let base = spatiallyFilled(frame)
            var incoming = base
            var outgoing = base
            for column in frame.indices where frame[column].a == 0 {
                let before = litColumn(k - 1, column)
                let after = litColumn(k + 1, column)
                if let lit = before ?? after { incoming[column] = lit.cleared }
                if let lit = after ?? before { outgoing[column] = lit.cleared }
            }
            // The first stop only starts a segment, the last only ends one.
            if k > 0 {
                outFrames.append(incoming)
                outTimes.append(keyTimes[k])
            }
            if k < frames.count - 1, k == 0 || outgoing != incoming {
                outFrames.append(outgoing)
                outTimes.append(keyTimes[k])
            }
        }
        return (outFrames, outTimes)
    }

    /// The same honesty along the band: `CAGradientLayer` interpolates
    /// its stops unpremultiplied as well, so a lit column next to a
    /// (0,0,0,0) one squares the light's falloff across that 4 pt gap.
    /// Each unlit column carries the RGB of the nearest lit column in the
    /// frame (the left one on a tie), still at alpha 0.
    static func spatiallyFilled(_ samples: [Sample]) -> [Sample] {
        var nearest = [Int?](repeating: nil, count: samples.count)
        var distance = [Int](repeating: .max, count: samples.count)
        var lit: Int?
        for index in samples.indices {
            if samples[index].a > 0 { lit = index }
            if let lit { nearest[index] = lit; distance[index] = index - lit }
        }
        lit = nil
        for index in samples.indices.reversed() {
            if samples[index].a > 0 { lit = index }
            if let lit, lit - index < distance[index] { nearest[index] = lit; distance[index] = lit - index }
        }
        var filled = samples
        for index in samples.indices where samples[index].a == 0 {
            if let source = nearest[index] { filled[index] = samples[source].cleared }
        }
        return filled
    }

    /// `draw_horizontal_gradient`'s stop construction for one layer.
    static func stops(colors: [RGB], bandWidth: CGFloat, alphaScale: CGFloat) -> [BandStop] {
        guard bandWidth > 0 else { return [] }
        let segments = runs(colors: colors, bandWidth: bandWidth).compactMap { $0 }.filter { $0.width > 0 }
        guard !segments.isEmpty else { return [] }
        var stops: [BandStop] = []
        func append(_ location: CGFloat, _ sample: Sample) {
            let bounded = min(1, max(0, location))
            let mapped = toneMapped(sample, alphaScale: alphaScale)
            let stop = BandStop(location: bounded, r: mapped.r, g: mapped.g, b: mapped.b, a: mapped.a)
            if let last = stops.last, bounded <= last.location {
                if bounded == last.location { stops[stops.count - 1] = stop }
                return
            }
            stops.append(stop)
        }
        // A gap's edge stops are the neighbouring run's colour at alpha 0,
        // not (0,0,0,0): the gradient interpolates unpremultiplied, and a
        // fade toward black would square the light's falloff into the gap.
        append(0, segments[0].x > 0 ? segments[0].color.cleared : segments[0].color)
        var previousEnd: CGFloat = 0
        var previous: Run?
        for run in segments {
            if run.x > previousEnd + 0.001 {
                append(previousEnd / bandWidth, (previous ?? run).color.cleared)
                append(run.x / bandWidth, run.color.cleared)
            }
            append((run.x + run.width / 2.0) / bandWidth, run.color)
            previousEnd = max(previousEnd, run.x + run.width)
            previous = run
        }
        if previousEnd < bandWidth - 0.001 {
            let tail = segments[segments.count - 1].color.cleared
            append(previousEnd / bandWidth, tail)
            append(1, tail)
        } else {
            append(1, segments[segments.count - 1].color)
        }
        if stops.count == 1 { append(1, segments[segments.count - 1].color) }
        return stops
    }
}
