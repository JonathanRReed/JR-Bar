import Foundation
import JRBarCore

/// The one-time step that follows the "one status item" decision: an
/// older JR-Bar could draw a second item (the "one system item", the agent
/// item, spacer items) and hid Control Center's own items while it did.
/// At launch this puts those Control Center items back, logs what it did,
/// and says so once in plain words. Everything it touches arrives as an
/// argument, so a test hands in fakes and never the real preferences.
@MainActor
enum OneItemMigration {
    /// The notice's key on the launch-notice queue.
    static let noticeKey = "one-status-item"

    @discardableResult
    static func run(retired: [String],
                    clearRetired: @escaping @MainActor () -> Void,
                    controlCenter: DefaultsStoring,
                    ours: DefaultsStoring,
                    relaunchControlCenter: () -> Void,
                    log: (String) -> Void,
                    notices: LaunchNotices,
                    openSettings: @escaping @MainActor () -> Void) -> ControlCenterRestore.Outcome {
        let outcome = ControlCenterRestore.run(controlCenter: controlCenter, ours: ours,
                                               relaunchControlCenter: relaunchControlCenter)
        // A launch with no saved record is every launch after the first:
        // nothing happened, so nothing is logged.
        if outcome.skipped == nil { log(outcome.logLine) }
        guard let text = ControlCenterRestore.noticeText(retired: retired, restored: outcome.restored) else {
            return outcome
        }
        // The "told them" mark is saved when the panel shows it, so a notice
        // lost with a quit is said again next launch.
        notices.say(.init(key: noticeKey, text: text, actionTitle: "Open Settings",
                          onShown: clearRetired, action: openSettings))
        return outcome
    }

    /// The saved slots of the retired items in JR-Bar's own preferences
    /// (the combined item, the agent item and the spacer rows). They are
    /// JR-Bar's keys and mean nothing now. The real icon's own key is not
    /// among them.
    static func forgetRetiredItemPlacements(in defaults: UserDefaults) {
        let prefixes = ["NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-",
                        "NSStatusItem Visible com.jonathanreed.jrbar.menubar-"]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Control Center reads its items' visibility as it starts, so a put-back
    /// value needs it relaunched; launchd starts it again at once.
    nonisolated static func relaunchControlCenter() {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["ControlCenter"]
            try? process.run()
        }
    }
}
