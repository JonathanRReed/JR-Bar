import Foundation

/// One LED as the firmware stores it: three 8-bit channel codes.
public struct RGB8: Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB8(r: 0, g: 0, b: 0)

    public var isLit: Bool { r != 0 || g != 0 || b != 0 }

    /// Canonical `#RRGGBB` spelling (uppercase, the way the Python renderer emits it).
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Parses exactly `#RRGGBB` (six hex digits, either case). Anything else is nil.
    public init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#") else { return nil }
        var value: UInt32 = 0
        for character in hex.dropFirst() {
            guard character.isASCII, let digit = character.hexDigitValue else { return nil }
            value = value << 4 | UInt32(digit)
        }
        self.init(r: UInt8(value >> 16 & 0xFF), g: UInt8(value >> 8 & 0xFF), b: UInt8(value & 0xFF))
    }

    public var rgb: RGB { RGB(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0) }
}

/// One LED as a float triple in 0...1.
///
/// The values are the firmware channel codes divided by 255. The strip PWMs
/// those codes linearly, so on the hardware they are linear light; the Python
/// Screen Bar paints the same numbers straight into an sRGB drawing context
/// (its "identity transfer" reconciliation, see `_led_status_legacy.py`). Use
/// `linear` / `fromLinear` when a consumer genuinely needs the IEC 61966-2-1
/// decode, for example to blend in linear light.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(r: 0, g: 0, b: 0)

    /// The brightest channel; the Python pipeline carries this as alpha ("how lit is this LED").
    public var maxChannel: Double { max(r, max(g, b)) }

    /// Decoded through the exact sRGB piecewise curve (port of `srgb_to_linear`).
    public var linear: RGB {
        RGB(r: LEDSTransfer.srgbToLinear(r), g: LEDSTransfer.srgbToLinear(g), b: LEDSTransfer.srgbToLinear(b))
    }

    /// Encoded through the exact sRGB piecewise curve (port of `linear_to_srgb`).
    public static func fromLinear(_ value: RGB) -> RGB {
        RGB(r: LEDSTransfer.linearToSRGB(value.r), g: LEDSTransfer.linearToSRGB(value.g), b: LEDSTransfer.linearToSRGB(value.b))
    }

    /// Nearest 8-bit codes.
    public var codes: RGB8 {
        func channel(_ value: Double) -> UInt8 {
            UInt8(max(0.0, min(255.0, (value * 255.0).rounded())))
        }
        return RGB8(r: channel(r), g: channel(g), b: channel(b))
    }
}

/// The two functions that cross between gamma-encoded sRGB codes and linear light.
public enum LEDSTransfer {
    /// Gamma-encoded sRGB (0.0-1.0) -> relative linear light (0.0-1.0).
    public static func srgbToLinear(_ value: Double) -> Double {
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// Relative linear light (0.0-1.0) -> gamma-encoded sRGB (0.0-1.0).
    public static func linearToSRGB(_ value: Double) -> Double {
        let clamped = max(0.0, min(1.0, value))
        if clamped <= 0.0031308 { return clamped * 12.92 }
        return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }
}
