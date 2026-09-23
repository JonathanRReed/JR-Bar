import Foundation

/// Saved calibration profiles (`calibration_profiles`) and the Focus →
/// profile rules (`focus_profile_rules`) as the Swift pages write them.
///
/// The daemon has kept both since the legacy window: a profile is a
/// snapshot of every remembered device's brightness, channel gains and
/// resting glow under a named slot, and a rule applies a slot's
/// brightness and gains when that Focus starts. Only the retiring PyObjC
/// window could reach them; these are the pure halves the Settings
/// window drives.
public enum LightProfiles {
    /// The fields a snapshot records per device —
    /// `AgentMonitorSettings.with_saved_calibration_profile`.
    public static let snapshotFields = ["brightness", "red_gain", "green_gain", "blue_gain", "resting_glow"]
    /// The fields applying a slot writes back —
    /// `with_applied_calibration_profile` restores brightness and the
    /// three gains, never the resting glow; a Focus rule and the Apply
    /// button do the same thing.
    public static let appliedFields = ["brightness", "red_gain", "green_gain", "blue_gain"]

    /// A slot's snapshot of the document's devices, by device id.
    public static func snapshot(of document: SettingsDocument) -> JSONValue {
        var devices: [String: JSONValue] = [:]
        for (_, id, entry) in document.deviceEntries {
            var fields: [String: JSONValue] = [:]
            for field in snapshotFields {
                if let value = entry[field], value.doubleValue != nil { fields[field] = value }
            }
            if !fields.isEmpty { devices[id] = .object(fields) }
        }
        return .object(devices)
    }

    /// The slots that hold a saved snapshot, in the daemon's slot order.
    public static func savedSlots(in document: SettingsDocument) -> [String] {
        let saved = document.object("calibration_profiles") ?? [:]
        return SettingsKey.calibrationProfileSlots.filter { saved[$0]?.objectValue != nil }
    }

    /// How many devices a saved slot covers.
    public static func deviceCount(slot: String, in document: SettingsDocument) -> Int {
        document.object("calibration_profiles")?[slot]?.objectValue?.count ?? 0
    }

    /// The per-field writes that put `slot` onto the document's devices:
    /// devices the profile names get its brightness and gains, devices it
    /// does not name are untouched, and a field already at the saved
    /// value is not rewritten. Empty when the slot is not saved.
    public static func applyWrites(slot: String, to document: SettingsDocument) -> [(path: String, value: JSONValue)] {
        guard let profile = document.object("calibration_profiles")?[slot]?.objectValue else { return [] }
        var writes: [(path: String, value: JSONValue)] = []
        for (index, id, entry) in document.deviceEntries {
            guard let saved = profile[id]?.objectValue else { continue }
            for field in appliedFields {
                guard let value = saved[field], let number = value.doubleValue else { continue }
                if entry[field]?.doubleValue == number { continue }
                writes.append(("devices.\(index).\(field)", .number(number)))
            }
        }
        return writes
    }

    /// Whether the devices already wear `slot` — every applied field of
    /// every device the profile names matches.
    public static func isApplied(slot: String, in document: SettingsDocument) -> Bool {
        guard document.object("calibration_profiles")?[slot]?.objectValue != nil else { return false }
        return applyWrites(slot: slot, to: document).isEmpty
    }

    /// The whole keyed-rules object with one entry set or removed.
    ///
    /// Focus identifiers are dotted (`com.apple.focus.work`), and a
    /// settings path splits on dots — `focus_profile_rules.com.apple…`
    /// would nest four objects deep and the daemon's loader drops it.
    /// The rows therefore write the rules object whole, with this.
    public static func rules(_ current: [String: JSONValue]?, setting key: String, to value: JSONValue?) -> JSONValue {
        var rules = current ?? [:]
        if let value, !value.isNull { rules[key] = value } else { rules[key] = nil }
        return .object(rules)
    }
}
