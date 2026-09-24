import Foundation

/// The SD eject guard as launchd really has it (`eject_guard` reply,
/// `docs/CORE-PROTOCOL.md`), in words for the SidePulse's card.
///
/// The guard shipped installed without a volume UUID, so launchd had never
/// run it: "installed" said nothing about whether anything was protected.
/// `protects` is the one word that matters, and the card offers "Protect
/// this SidePulse" whenever it is false for the SidePulse plugged in now.
public struct EjectGuardReading: Equatable, Sendable {
    public var installed: Bool
    public var protects: Bool
    public var protectsMounted: Bool
    public var running: Bool
    public var runs: Int?
    public var volumeUUID: String?
    public var mountedVolumeUUID: String?
    public var mountedName: String?

    public init(installed: Bool = false, protects: Bool = false, protectsMounted: Bool = false,
                running: Bool = false, runs: Int? = nil, volumeUUID: String? = nil,
                mountedVolumeUUID: String? = nil, mountedName: String? = nil) {
        self.installed = installed
        self.protects = protects
        self.protectsMounted = protectsMounted
        self.running = running
        self.runs = runs
        self.volumeUUID = volumeUUID
        self.mountedVolumeUUID = mountedVolumeUUID
        self.mountedName = mountedName
    }

    /// nil when the reply is not an eject-guard reading at all.
    public static func parse(_ json: JSONValue?) -> EjectGuardReading? {
        guard let json, let installed = json["installed"]?.boolValue else { return nil }
        return EjectGuardReading(
            installed: installed,
            protects: json["protects"]?.boolValue ?? false,
            protectsMounted: json["protects_mounted"]?.boolValue ?? false,
            running: json["running"]?.boolValue ?? false,
            runs: json["runs"]?.intValue,
            volumeUUID: json["volume_uuid"]?.stringValue,
            mountedVolumeUUID: json["mounted_volume_uuid"]?.stringValue,
            mountedName: json["mounted_name"]?.stringValue)
    }

    /// Whether "Protect this SidePulse" has something to do.
    public var canProtect: Bool { mountedVolumeUUID != nil && !protectsMounted }

    /// One line for the card: what is protected, never just "installed".
    public var words: String {
        if protectsMounted {
            return running
                ? "Protecting this SidePulse: nothing ejects it in software, even a wake while locked. Pull it out to remove it."
                : "Set up for this SidePulse; launchd starts it when the card mounts."
        }
        if protects {
            return "Protecting a different SidePulse. Protect this one to move the guard to it."
        }
        if installed {
            return "Installed, but it has never run: it was never told which SidePulse to protect."
        }
        return "Not installed. macOS can eject the SidePulse when the Mac wakes locked."
    }
}

/// A device card's receipt from `lights.device_receipts`: another writer
/// changed the device's program behind JR-Bar's back.
public enum DeviceReceiptWords {
    /// nil when there is nothing to say.
    public static func line(_ receipt: CoreDeviceReceipt?, deviceName: String) -> String? {
        guard let receipt, receipt.foreignWrites > 0 else { return nil }
        if receipt.paused {
            return "Another app keeps writing to this \(deviceName). JR-Bar stopped rewriting it, so the two don't fight over the device; it takes over again with its next change."
        }
        return "Another app wrote to this \(deviceName). JR-Bar put its own program back."
    }
}
