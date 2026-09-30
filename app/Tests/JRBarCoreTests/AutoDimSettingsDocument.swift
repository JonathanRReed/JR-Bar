import Foundation
@testable import JRBarCore

extension AutoDimSettings {
    /// Every path the daemon's `auto_dim` document carries.
    static let allPaths: [SettingsPath] = [
        modePath, scheduleStartPath, scheduleEndPath, scheduleFractionPath, displayMinFractionPath,
        ambientMinFractionPath, ambientLuxFloorPath, ambientLuxCeilingPath,
    ]

    /// `AutoDimSettings.to_dict()`: the whole document under `auto_dim`,
    /// for the round trip through `init(document:)`.
    var document: JSONValue {
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
}
