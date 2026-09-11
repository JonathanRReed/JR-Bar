import Foundation

/// Working values for the guided calibration sheet -- the numbers the daemon
/// applies through the same write-boundary transform as live output. All
/// mutators clamp to the daemon's own bounds (`MIN/MAX_CHANNEL_GAIN`,
/// `MAX_RESTING_GLOW`) so a persisted apply can never hold a value the
/// settings layer would later reject.
public struct CalibrationModel: Equatable, Sendable {
    /// The nominal reference patch -- what the device SHOULD look like. The
    /// preview sends the patch colour itself, never a gain-tinted hex, so the
    /// screen stays the truthful reference while the hardware does the work.
    public enum Patch: String, CaseIterable, Sendable {
        case white, red, green, blue, grey

        public var label: String { rawValue.capitalized }

        /// Nominal sRGB components, 0...1 -- mirroring the daemon's
        /// CALIBRATION_PATCHES table.
        public var swatch: (r: Double, g: Double, b: Double) {
            switch self {
            case .white: return (1.0, 1.0, 1.0)
            case .red: return (1.0, 0.0, 0.0)
            case .green: return (0.0, 1.0, 0.0)
            case .blue: return (0.0, 0.0, 1.0)
            case .grey: return (0.5, 0.5, 0.5)
            }
        }
    }

    /// One-button colour judgements; each moves the relevant channel(s) by
    /// `nudgeStep`, mirrored from `CALIBRATION_NUDGE_STEP` in the daemon.
    /// The name describes the LIGHT's fault: `.warmer` means "the light is
    /// too cool", so it raises red and lowers blue.
    public enum Nudge: Sendable {
        case warmer, cooler, greener, lessGreen
    }

    /// The profile as it was when the sheet opened -- the baseline for
    /// `isDirty` and for "Compare with before".
    public struct Snapshot: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var glow: Double
        public var brightness: Double

        public init(red: Double, green: Double, blue: Double, glow: Double, brightness: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.glow = glow
            self.brightness = brightness
        }
    }

    /// Mirrors `CALIBRATION_NUDGE_STEP` in `status_bar_legacy.py`.
    public static let nudgeStep = 0.04
    /// Mirrors `MIN/MAX_CHANNEL_GAIN` in `_led_status_legacy.py`.
    public static let gainRange = 0.3...1.5
    /// Mirrors the resting-glow clamp in the settings layer
    /// (`with_device_resting_glow`).
    public static let glowRange = 0.0...0.35

    public var red: Double
    public var green: Double
    public var blue: Double
    public var glow: Double
    /// The device's own brightness as a 0...1 fraction of its 0...255 domain.
    public var brightness: Double
    public var patch: Patch
    public var original: Snapshot

    public init(
        red: Double = 1.0,
        green: Double = 1.0,
        blue: Double = 1.0,
        glow: Double = 0.0,
        brightness: Double = 1.0,
        patch: Patch = .white
    ) {
        self.red = Self.gainRange.clamp(red)
        self.green = Self.gainRange.clamp(green)
        self.blue = Self.gainRange.clamp(blue)
        self.glow = Self.glowRange.clamp(glow)
        self.brightness = Self.clampUnit(brightness)
        self.patch = patch
        self.original = Snapshot(
            red: self.red, green: self.green, blue: self.blue,
            glow: self.glow, brightness: self.brightness
        )
    }

    public mutating func nudge(_ nudge: Nudge) {
        let step = Self.nudgeStep
        switch nudge {
        case .warmer: red += step; blue -= step
        case .cooler: red -= step; blue += step
        case .greener: green += step
        case .lessGreen: green -= step
        }
        red = Self.gainRange.clamp(red)
        green = Self.gainRange.clamp(green)
        blue = Self.gainRange.clamp(blue)
    }

    /// The shipped die: no channel correction and no resting glow. Brightness
    /// counts too -- a dimmed device is not the as-shipped drive.
    public var isDefault: Bool {
        red == 1.0 && green == 1.0 && blue == 1.0 && glow == 0.0 && brightness == 1.0
    }

    /// Anything that `apply_calibration` would change. The patch is preview
    /// state, not profile state, so it never makes the sheet dirty.
    public var isDirty: Bool {
        original != Snapshot(red: red, green: green, blue: blue, glow: glow, brightness: brightness)
    }

    /// Back to the die as shipped: gains 1.0 and glow 0. Brightness is the
    /// device's own setting, not a calibration default, so reset leaves it.
    public mutating func reset() {
        red = 1.0
        green = 1.0
        blue = 1.0
        glow = 0.0
    }

    /// Brightness in the daemon's 0...255 domain, rounded to a whole drive.
    public var brightnessByte: Int { Int((brightness * 255.0).rounded()) }

    /// Arguments for `apply_calibration` -- only the persisted fields.
    public func profileArguments() -> [String: JSONValue] {
        [
            "red_gain": .number(red),
            "green_gain": .number(green),
            "blue_gain": .number(blue),
            "resting_glow": .number(glow),
            "brightness": .number(Double(brightnessByte)),
        ]
    }

    /// Arguments for `preview_calibration` -- the nominal patch plus the
    /// explicit values the daemon applies through the write boundary.
    public func previewArguments(device: String, companion: Bool) -> [String: JSONValue] {
        [
            "device": .string(device),
            "gains": .object([
                "red": .number(red),
                "green": .number(green),
                "blue": .number(blue),
            ]),
            "resting_glow": .number(glow),
            "brightness": .number(Double(brightnessByte)),
            "patch": .string(patch.rawValue),
            "companion": .bool(companion),
        ]
    }

    static func clampUnit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
