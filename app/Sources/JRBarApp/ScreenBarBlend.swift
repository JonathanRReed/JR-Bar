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
    }

    /// `blended_led_color_at_x`: blend the LEDs at view-local `x` (0 = band's left edge).
    static func blended(_ colors: [RGB], x: CGFloat, ledWidth: CGFloat) -> Sample {
        guard ledWidth > 0 else { return Sample(r: 0, g: 0, b: 0, a: 0) }
        let radius = ledWidth * blendRadiusLeds
        var totals = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        for (index, color) in colors.enumerated() {
            let center = (CGFloat(index) + 0.5) * ledWidth
            let distance = abs(x - center)
            if distance > radius { continue }
            let weight = 0.5 + 0.5 * cos(.pi * distance / radius)
            totals.r += CGFloat(color.r) * weight
            totals.g += CGFloat(color.g) * weight
            totals.b += CGFloat(color.b) * weight
            totals.a += CGFloat(color.maxChannel) * weight
        }
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        return Sample(r: clamp(totals.r), g: clamp(totals.g), b: clamp(totals.b), a: clamp(totals.a))
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
        let transparent = Sample(r: 0, g: 0, b: 0, a: 0)
        append(0, segments[0].x > 0 ? transparent : segments[0].color)
        var previousEnd: CGFloat = 0
        for run in segments {
            if run.x > previousEnd + 0.001 {
                append(previousEnd / bandWidth, transparent)
                append(run.x / bandWidth, transparent)
            }
            append((run.x + run.width / 2.0) / bandWidth, run.color)
            previousEnd = max(previousEnd, run.x + run.width)
        }
        if previousEnd < bandWidth - 0.001 {
            append(previousEnd / bandWidth, transparent)
            append(1, transparent)
        } else {
            append(1, segments[segments.count - 1].color)
        }
        if stops.count == 1 { append(1, segments[segments.count - 1].color) }
        return stops
    }
}
