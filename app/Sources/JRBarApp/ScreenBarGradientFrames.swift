import CoreGraphics
import Foundation
import JRBarLEDS

/// Immutable layer values, made on the planning worker. CGColor is immutable.
struct ScreenBarGradientFrames: @unchecked Sendable {
    struct Track {
        let colors: [[CGColor]]
        let times: [NSNumber]
    }
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    let rest: [CGColor]
    let lead: Track?
    let loop: Track?
    let locations: [NSNumber]

    static func build(plan: LEDSKeyframePlan, width: CGFloat, reduced: Bool) -> Self {
        func samples(_ codes: [RGB8]) -> [ScreenBarBlend.Sample] {
            ScreenBarBlend.columnSamples(colors: codes.map(\.rgb), bandWidth: width,
                                         alphaScale: ScreenBarBlend.coreAlpha)
        }
        var colors: [UInt64: CGColor] = [:]
        func color(_ sample: ScreenBarBlend.Sample) -> CGColor {
            let red = UInt64(sample.r * 1024) << 33
            let green = UInt64(sample.g * 1024) << 22
            let blue = UInt64(sample.b * 1024) << 11
            let alpha = UInt64(sample.a * 1024)
            let key = red | green | blue | alpha
            if let cached = colors[key] { return cached }
            let value = CGColor(colorSpace: colorSpace, components: [sample.r, sample.g, sample.b, sample.a])!
            if colors.count < 4_096 { colors[key] = value }
            return value
        }
        func track(_ source: LEDSKeyframeTrack?) -> Track? {
            guard !reduced, let source else { return nil }
            let fades = ScreenBarBlend.keyframes(source.frames.map(samples), keyTimes: source.keyTimes)
            return Track(colors: fades.frames.map { $0.map(color) },
                         times: fades.keyTimes.map { NSNumber(value: $0) })
        }
        let codes: [RGB8]
        if reduced {
            let frames = (plan.lead?.frames ?? []) + (plan.loop?.frames ?? []) + [plan.finalCodes]
            func level(_ codes: [RGB8]) -> Int {
                codes.reduce(0) { $0 + Int(max($1.r, max($1.g, $1.b))) }
            }
            codes = frames.max { level($0) < level($1) } ?? plan.finalCodes
        } else {
            codes = plan.loop?.frames.first ?? plan.finalCodes
        }
        return Self(rest: ScreenBarBlend.spatiallyFilled(samples(codes)).map(color),
                    lead: track(plan.lead), loop: track(plan.loop),
                    locations: ScreenBarBlend.columnLocations(bandWidth: width).map { NSNumber(value: Double($0)) })
    }
}
