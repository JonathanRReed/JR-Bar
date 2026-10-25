import Foundation
import JRBarCore
import JRBarLEDS

enum ScreenBarLightTransfer {
    /// Sample PWM before converting to display light. Simplifying encoded
    /// endpoints first would change the shape of a dim fade.
    static func plan(sampler: LEDSSampler, transfer: CoreStripTransfer) -> LEDSKeyframePlan? {
        // Keep the transfer error fixed. A plan that exceeds the layer
        // budget uses the capped clock instead of loosening its colours.
        guard let plan = LEDSKeyframePlan.render(sampler: sampler, tolerance: 1,
                                               maxKeyframes: .max, sample: { milliseconds in
            colors(sampler.rawCodes(atMilliseconds: milliseconds), brightness: sampler.brightness,
                   transfer: transfer).map { color in
                RGB8(r: UInt8((color.r * 255).rounded()),
                     g: UInt8((color.g * 255).rounded()), b: UInt8((color.b * 255).rounded()))
            }
        }), plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes else { return nil }
        return plan
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
