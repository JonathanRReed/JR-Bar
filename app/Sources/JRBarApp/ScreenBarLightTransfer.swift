import Foundation
import JRBarCore
import JRBarLEDS

enum ScreenBarLightTransfer {
    /// Sample PWM before converting to display light. Simplifying encoded
    /// endpoints first would change the shape of a dim fade.
    static func plan(sampler: LEDSSampler, transfer: CoreStripTransfer) -> LEDSKeyframePlan? {
        // Retry within the existing two-code visual tolerance before using
        // the 60 Hz frame clock. Simplification sees full-precision light.
        for tolerance in 1...2 {
            if let plan = LEDSKeyframePlan.render(sampler: sampler, tolerance: tolerance,
                                                 maxKeyframes: .max, sampleColors: { milliseconds in
                colors(sampler.rawCodes(atMilliseconds: milliseconds), brightness: sampler.brightness,
                       transfer: transfer)
            }), plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes { return plan }
        }
        return nil
    }

    static func colors(_ codes: [RGB8], brightness: Int, transfer: CoreStripTransfer) -> [RGB] {
        let scale = Double(min(255, max(0, brightness))) / 255
        func channel(_ code: UInt8, at index: Int) -> Double {
            let drive = Double(code) / 255
            let light = pow(drive, transfer.codeToLightExponent)
                / transfer.channelGains[index] * transfer.displayChannelGains[index]
            let clamped = min(1, max(0, light))
            let encoded = clamped <= 0.0031308
                ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return encoded * scale
        }
        return codes.map { RGB(r: channel($0.r, at: 0), g: channel($0.g, at: 1), b: channel($0.b, at: 2)) }
    }
}
