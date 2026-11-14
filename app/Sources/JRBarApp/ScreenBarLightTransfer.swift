import Foundation
import JRBarCore
import JRBarLEDS

enum ScreenBarLightTransfer {
    /// Sample PWM before converting to display light. Simplifying encoded
    /// endpoints first would change the shape of a dim fade.
    ///
    /// The plan follows the strip's own 8-bit steps when they fit the
    /// keyframe budget. A dim fade under a strong calibration gain does not:
    /// one step of the strip is many codes on the display, every step needs
    /// its own keyframes, and a twelve-second roll wants thousands. That
    /// program used to fall back to redrawing the band at 60 Hz for as long
    /// as an agent worked. It now plays the fade those steps approximate
    /// (`smoothPlan`), which the render server interpolates for nothing.
    static func plan(sampler: LEDSSampler, transfer: CoreStripTransfer) -> LEDSKeyframePlan? {
        // Both exact passes read the same samples; convert each instant once.
        var exact: [Int: [RGB]] = [:]
        // Retry within the existing two-code visual tolerance before giving
        // up on the steps. Simplification sees full-precision light.
        for tolerance in 1...2 {
            if let plan = LEDSKeyframePlan.render(sampler: sampler, tolerance: tolerance,
                                                 maxKeyframes: .max, sampleColors: { milliseconds in
                if let known = exact[milliseconds] { return known }
                let value = colors(sampler.rawCodes(atMilliseconds: milliseconds), brightness: sampler.brightness,
                                   transfer: transfer)
                exact[milliseconds] = value
                return value
            }), plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes { return plan }
        }
        return smoothPlan(sampler: sampler, transfer: transfer)
    }

    /// How far, in display codes, the smooth plan may stray from the fade
    /// before the program is left to the frame clock. It starts at two and
    /// gives way a code at a time: a fast sweep under a strong calibration
    /// needs the room, and five codes is two percent of full scale on light
    /// that is already moving.
    static let smoothTolerances = 2...5

    /// The fade without the strip's 8-bit steps, as close to it as the
    /// keyframe budget allows within `smoothTolerances`, or nil when even
    /// that needs too many keyframes (the caller keeps its frame clock). The
    /// fade is never a whole step of the strip away from what the strip
    /// shows.
    static func smoothPlan(sampler: LEDSSampler, transfer: CoreStripTransfer) -> LEDSKeyframePlan? {
        // Every pass reads the same samples; convert each instant once.
        var smooth: [Int: [RGB]] = [:]
        for tolerance in smoothTolerances {
            if let plan = LEDSKeyframePlan.render(sampler: sampler, tolerance: tolerance, maxKeyframes: .max,
                                                 sampleColors: { milliseconds in
                if let known = smooth[milliseconds] { return known }
                let value = colors(light: sampler.smoothRawLight(atMilliseconds: milliseconds),
                                   brightness: sampler.brightness, transfer: transfer)
                smooth[milliseconds] = value
                return value
            }), plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes { return plan }
        }
        return nil
    }

    static func colors(_ codes: [RGB8], brightness: Int, transfer: CoreStripTransfer) -> [RGB] {
        colors(light: codes.map(\.rgb), brightness: brightness, transfer: transfer)
    }

    /// Drive fractions (code / 255) to what the display shows for them.
    static func colors(light: [RGB], brightness: Int, transfer: CoreStripTransfer) -> [RGB] {
        let scale = Double(min(255, max(0, brightness))) / 255
        func channel(_ drive: Double, at index: Int) -> Double {
            let light = pow(drive, transfer.codeToLightExponent)
                / transfer.channelGains[index] * transfer.displayChannelGains[index]
            let clamped = min(1, max(0, light))
            let encoded = clamped <= 0.0031308
                ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return encoded * scale
        }
        return light.map { RGB(r: channel($0.r, at: 0), g: channel($0.g, at: 1), b: channel($0.b, at: 2)) }
    }
}
