import Foundation

/// The `auto_dim` settings document (`docs/CORE-PROTOCOL.md`, settings):
/// `{mode, schedule {start_minutes, end_minutes, fraction}, display
/// {min_fraction}, ambient {min_fraction, lux_floor, lux_ceiling}}`, read
/// leniently the way the daemon's `AutoDimSettings.from_dict` reads it
/// (anything malformed falls back to that field's default), with the dot
/// paths `set_setting` writes and the readout line the Lighting page and
/// the why popover show.
public struct AutoDimSettings: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case off, schedule, display, ambient

        public var label: String {
            switch self {
            case .off: return "Off"
            case .schedule: return "Schedule"
            case .display: return "Follow display"
            case .ambient: return "Ambient light"
            }
        }

        public var detail: String {
            switch self {
            case .off: return "The lights keep their full brightness at every hour."
            case .schedule: return "Dim to a fraction inside a daily window; the window may wrap midnight."
            case .display: return "Follow the built-in display's brightness, never below the floor. An external or sleeping display leaves the lights alone."
            case .ambient: return "Follow the ambient light sensor: the floor at the low lux mark, full at the high one. Without a sensor this follows the display instead."
            }
        }
    }

    public var mode: Mode
    public var scheduleStartMinutes: Int
    public var scheduleEndMinutes: Int
    public var scheduleFraction: Double
    public var displayMinFraction: Double
    public var ambientMinFraction: Double
    public var ambientLuxFloor: Double
    public var ambientLuxCeiling: Double

    /// The daemon's defaults (`src/jrbar/auto_dim.py`).
    public static let defaults = AutoDimSettings(
        mode: .off, scheduleStartMinutes: 22 * 60, scheduleEndMinutes: 7 * 60, scheduleFraction: 0.3,
        displayMinFraction: 0.15, ambientMinFraction: 0.1, ambientLuxFloor: 5, ambientLuxCeiling: 400)

    public static let minFraction = 0.02
    public static let maxLux = 200_000.0

    public init(mode: Mode, scheduleStartMinutes: Int, scheduleEndMinutes: Int, scheduleFraction: Double,
                displayMinFraction: Double, ambientMinFraction: Double, ambientLuxFloor: Double, ambientLuxCeiling: Double) {
        self.mode = mode
        self.scheduleStartMinutes = scheduleStartMinutes
        self.scheduleEndMinutes = scheduleEndMinutes
        self.scheduleFraction = scheduleFraction
        self.displayMinFraction = displayMinFraction
        self.ambientMinFraction = ambientMinFraction
        self.ambientLuxFloor = ambientLuxFloor
        self.ambientLuxCeiling = ambientLuxCeiling
    }

    // MARK: Paths

    public static let root: SettingsPath = "auto_dim"
    public static let modePath: SettingsPath = "auto_dim.mode"
    public static let scheduleStartPath: SettingsPath = "auto_dim.schedule.start_minutes"
    public static let scheduleEndPath: SettingsPath = "auto_dim.schedule.end_minutes"
    public static let scheduleFractionPath: SettingsPath = "auto_dim.schedule.fraction"
    public static let displayMinFractionPath: SettingsPath = "auto_dim.display.min_fraction"
    public static let ambientMinFractionPath: SettingsPath = "auto_dim.ambient.min_fraction"
    public static let ambientLuxFloorPath: SettingsPath = "auto_dim.ambient.lux_floor"
    public static let ambientLuxCeilingPath: SettingsPath = "auto_dim.ambient.lux_ceiling"

    public static let allPaths: [SettingsPath] = [
        modePath, scheduleStartPath, scheduleEndPath, scheduleFractionPath, displayMinFractionPath,
        ambientMinFractionPath, ambientLuxFloorPath, ambientLuxCeilingPath,
    ]

    // MARK: Document

    /// Reads the document; a missing or malformed field is its default, an
    /// unknown mode is `off`, and a ceiling at or under the floor puts both
    /// back to their defaults (the daemon does the same).
    public init(document: SettingsDocument) {
        let d = Self.defaults
        mode = document.string(Self.modePath).flatMap(Mode.init(rawValue:)) ?? d.mode
        scheduleStartMinutes = Self.minutes(document.double(Self.scheduleStartPath), default: d.scheduleStartMinutes)
        scheduleEndMinutes = Self.minutes(document.double(Self.scheduleEndPath), default: d.scheduleEndMinutes)
        scheduleFraction = Self.fraction(document.double(Self.scheduleFractionPath), default: d.scheduleFraction)
        displayMinFraction = Self.fraction(document.double(Self.displayMinFractionPath), default: d.displayMinFraction)
        ambientMinFraction = Self.fraction(document.double(Self.ambientMinFractionPath), default: d.ambientMinFraction)
        var floor = Self.lux(document.double(Self.ambientLuxFloorPath), default: d.ambientLuxFloor)
        var ceiling = Self.lux(document.double(Self.ambientLuxCeilingPath), default: d.ambientLuxCeiling)
        if ceiling <= floor { floor = d.ambientLuxFloor; ceiling = d.ambientLuxCeiling }
        ambientLuxFloor = floor
        ambientLuxCeiling = ceiling
    }

    /// `AutoDimSettings.to_dict()`: the whole document under `auto_dim`.
    public var document: JSONValue {
        .object([
            "mode": .string(mode.rawValue),
            "schedule": .object([
                "start_minutes": .number(Double(scheduleStartMinutes)),
                "end_minutes": .number(Double(scheduleEndMinutes)),
                "fraction": .number(scheduleFraction),
            ]),
            "display": .object(["min_fraction": .number(displayMinFraction)]),
            "ambient": .object([
                "min_fraction": .number(ambientMinFraction),
                "lux_floor": .number(ambientLuxFloor),
                "lux_ceiling": .number(ambientLuxCeiling),
            ]),
        ])
    }

    /// The document is present at all (the daemon serves the key).
    public static func isProvided(in document: SettingsDocument) -> Bool {
        document.object(root) != nil
    }

    static func fraction(_ value: Double?, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return max(minFraction, min(1, value))
    }

    static func minutes(_ value: Double?, default fallback: Int) -> Int {
        guard let value, value.isFinite else { return fallback }
        return max(0, min(24 * 60 - 1, Int(value)))
    }

    static func lux(_ value: Double?, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return max(0, min(maxLux, value))
    }

    // MARK: Words

    /// Whether `nowMinutes` (since local midnight) is inside the schedule;
    /// a start after its end wraps midnight, an empty window never matches.
    public func scheduleActive(nowMinutes: Int) -> Bool {
        if scheduleStartMinutes == scheduleEndMinutes { return false }
        if scheduleStartMinutes < scheduleEndMinutes {
            return scheduleStartMinutes <= nowMinutes && nowMinutes < scheduleEndMinutes
        }
        return nowMinutes >= scheduleStartMinutes || nowMinutes < scheduleEndMinutes
    }

    /// The setting in one line for the why popover: "off", "schedule
    /// 22:00–07:00 to 30%", "follows display, floor 15%", "ambient 5–400
    /// lux, floor 10%".
    public var summary: String {
        switch mode {
        case .off:
            return "off"
        case .schedule:
            return "schedule \(Self.clock(scheduleStartMinutes))–\(Self.clock(scheduleEndMinutes)) to \(Self.percent(scheduleFraction))"
        case .display:
            return "follows display, floor \(Self.percent(displayMinFraction))"
        case .ambient:
            return "ambient \(Self.luxText(ambientLuxFloor))–\(Self.luxText(ambientLuxCeiling)) lux, floor \(Self.percent(ambientMinFraction))"
        }
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func luxText(_ lux: Double) -> String {
        lux == lux.rounded() ? String(Int(lux)) : String(format: "%.1f", lux)
    }
}

/// The live line under the auto-dim controls, from `lights.auto_dim`:
/// what the daemon read and the factor it chose.
public enum AutoDimReadout {
    /// "Ambient: 12 lux → 45%", "Sensor unavailable, following display:
    /// 62% → 62%", "Schedule: 23:10, inside the window → 30%",
    /// "Display: 62% → 62%", "Display unreadable → 100%", "Off → 100%".
    /// Nil with no `auto_dim` from the daemon.
    public static func line(_ result: CoreAutoDim?, settings: AutoDimSettings? = nil) -> String? {
        guard let result else { return nil }
        let factor = result.factor.map { " → \(AutoDimSettings.percent($0))" } ?? ""
        switch result.mode {
        case "off":
            return "Off" + (result.factor.map { " → \(AutoDimSettings.percent($0))" } ?? " → 100%")
        case "schedule":
            guard let reading = result.reading else { return "Schedule" + factor }
            let minutes = Int(reading)
            let inside: String
            if let settings {
                inside = settings.scheduleActive(nowMinutes: minutes) ? "inside the window" : "outside the window"
            } else {
                inside = (result.factor ?? 1) < 1 ? "inside the window" : "outside the window"
            }
            return "Schedule: \(AutoDimSettings.clock(minutes)), \(inside)" + factor
        case "ambient":
            if result.source == "ambient", let lux = result.reading {
                return "Ambient: \(AutoDimSettings.luxText(lux)) lux" + factor
            }
            // No sensor: the daemon followed the display and said so.
            guard result.reading != nil else { return "Sensor unavailable, display unreadable" + factor }
            return "Sensor unavailable, following display: \(displayText(result.reading))" + factor
        case "display":
            guard result.available, let reading = result.reading else { return "Display unreadable" + factor }
            return "Display: \(AutoDimSettings.percent(reading))" + factor
        default:
            return result.mode.capitalized + factor
        }
    }

    private static func displayText(_ reading: Double?) -> String {
        reading.map(AutoDimSettings.percent) ?? "unreadable"
    }

    /// The dimming word for the why popover: "Auto-dim (schedule)",
    /// "Auto-dim (display)", "Auto-dim (ambient)". Ambient mode that fell
    /// back to the display says so: "Auto-dim (ambient, following display)".
    public static func dimmingWord(_ result: CoreAutoDim?) -> String {
        guard let result, result.mode != "off" else { return "Auto-dim" }
        if result.mode == "ambient", result.source != "ambient" {
            return "Auto-dim (ambient, following \(result.source))"
        }
        return "Auto-dim (\(result.mode))"
    }
}
