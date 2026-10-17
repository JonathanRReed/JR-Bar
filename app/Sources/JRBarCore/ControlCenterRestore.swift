import Foundation

/// The two preference stores the one-time Control Center restore touches,
/// as the few calls it needs. `UserDefaults` is both of them in the app; a
/// test hands in a fake, never the real `com.apple.controlcenter` domain.
public protocol DefaultsStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: DefaultsStoring {}

/// Puts back the Control Center items an older JR-Bar hid.
///
/// JR-Bar used to draw a second "one system item" and, while it showed,
/// set `NSStatusItem Visible <name>` to false in Control Center's own
/// preferences for Battery, Wi-Fi, Bluetooth, Sound, Now Playing and
/// Focus. It kept the originals in its own preferences
/// (`jrbar.menubar.ccOriginals`). JR-Bar now has one status item and
/// writes no Control Center preference, so this runs once at launch to
/// undo what that build did, and never writes anything else:
///
/// - With no saved record, nothing was hidden by JR-Bar: it does nothing.
/// - A key is put back only while it still holds the `false` JR-Bar wrote.
///   A key the person has changed since is theirs and is left alone.
/// - A key with a saved original gets that value back; a key that was never
///   set is removed again.
/// - The record is removed afterwards, so a second run finds nothing to do.
public enum ControlCenterRestore {
    /// The Control Center items the old build hid.
    public static let coveredKeys = ["Battery", "WiFi", "Bluetooth", "Sound", "NowPlaying", "FocusModes"]
    /// Where the originals were kept, in JR-Bar's own preferences.
    public static let savedKey = "jrbar.menubar.ccOriginals"

    public struct Outcome: Equatable, Sendable {
        /// The items that were hidden and are visible again.
        public var restored: [String] = []
        /// Why nothing was written, when nothing was.
        public var skipped: String?

        public init(restored: [String] = [], skipped: String? = nil) {
            self.restored = restored
            self.skipped = skipped
        }

        /// A line for the log that says what happened and no more.
        public var logLine: String {
            if let skipped { return "controlcenter restore: skipped, \(skipped)" }
            if restored.isEmpty { return "controlcenter restore: the saved record held nothing hidden, record cleared" }
            return "controlcenter restore: put back \(restored.joined(separator: ", ")), record cleared"
        }
    }

    /// The Control Center preference key for one item.
    static func defaultsKey(_ name: String) -> String { "NSStatusItem Visible \(name)" }

    /// Runs the restore. `relaunchControlCenter` is called once, only when a
    /// value was written, because Control Center reads the key as it starts.
    @discardableResult
    public static func run(controlCenter: DefaultsStoring, ours: DefaultsStoring,
                           relaunchControlCenter: () -> Void) -> Outcome {
        guard let record = ours.object(forKey: savedKey) as? [String: Any] else {
            return Outcome(skipped: "no saved record, so JR-Bar did not hide anything")
        }
        var restored: [String] = []
        for name in coveredKeys {
            let key = defaultsKey(name)
            // Only a value that is still the `false` JR-Bar wrote.
            guard let current = controlCenter.object(forKey: key) as? Bool, current == false else { continue }
            if let original = record[name] as? Bool {
                // An original of false was already false: nothing to put back.
                guard original else { continue }
                controlCenter.set(original, forKey: key)
            } else {
                controlCenter.removeObject(forKey: key)
            }
            restored.append(name)
        }
        ours.removeObject(forKey: savedKey)
        if !restored.isEmpty { relaunchControlCenter() }
        return Outcome(restored: restored)
    }

    /// The one-time launch notice, in plain words, or nil when there is
    /// nothing to say. `retired` is `MenuBarSettings.retiredExtras`.
    public static func noticeText(retired: [String], restored: [String]) -> String? {
        var parts: [String] = []
        if retired.contains("combined") {
            parts.append("The system item is now a readout on the JR-Bar icon's face (Settings, Menu Bar, More).")
        }
        if retired.contains("agents") {
            parts.append("The agent item is gone; the icon's Agents style shows the same state.")
        }
        if retired.contains("spacers") {
            parts.append("Spacer items are gone.")
        }
        if !restored.isEmpty {
            let names = restored.map(displayName).joined(separator: ", ")
            parts.append("Control Center's \(names) \(restored.count == 1 ? "item is" : "items are") back.")
        }
        guard !parts.isEmpty else { return nil }
        return "JR-Bar now has one menu bar item, the icon. " + parts.joined(separator: " ")
    }

    private static func displayName(_ key: String) -> String {
        switch key {
        case "WiFi": return "Wi-Fi"
        case "NowPlaying": return "Now Playing"
        case "FocusModes": return "Focus"
        default: return key
        }
    }
}
