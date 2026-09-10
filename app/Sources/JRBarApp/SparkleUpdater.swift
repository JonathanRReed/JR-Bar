import AppKit
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// The in-app updater over the embedded Sparkle.framework.
///
/// The packaged bundle carries `Contents/Frameworks/Sparkle.framework`, and
/// `Package.swift` links it when `JRBAR_SPARKLE_FRAMEWORK_DIR` names the
/// pinned distribution at build time (`app/scripts/build-app.sh` finds it
/// after one `make package`). A build without the framework compiles the
/// stub half of this file and reports `.missingFramework`: the menu item
/// stays visible and disabled so nothing else has to know.
///
/// Policy, per docs/PRODUCTION-RELEASE.md: the feed is signed and pinned
/// (`SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed` in the Info.plist),
/// automatic checks are off until Settings › General turns them on (the
/// first launch writes `SUEnableAutomaticChecks=false` into user defaults
/// so Sparkle never shows its own permission prompt), and the channel
/// picker's `updateChannel` default (`stable` / `beta`) becomes the set of
/// channels the delegate allows.
@MainActor
final class SparkleUpdater: NSObject {
    enum Availability: Equatable {
        case ready
        case missingFramework
        case misconfigured(String)

        var description: String {
            switch self {
            case .ready: return "ready"
            case .missingFramework: return "Sparkle.framework is not in this build"
            case .misconfigured(let why): return why
            }
        }
    }

    /// `SettingsStore.updateChannel` writes this default; the delegate reads it.
    nonisolated static let channelDefaultsKey = "updateChannel"
    nonisolated static let betaChannel = "beta"
    /// Sparkle's own defaults key for `automaticallyChecksForUpdates`.
    nonisolated static let automaticChecksDefaultsKey = "SUEnableAutomaticChecks"
    /// Posted (on the main queue) when `automaticallyChecksForUpdates` changes.
    nonisolated static let automaticChecksDidChange = Notification.Name("JRBarSparkleAutomaticChecksDidChange")

    /// The one updater the app owns; Settings reaches it through here.
    private(set) static var shared: SparkleUpdater?

    let availability: Availability
    private let log: (String) -> Void
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    init(bundle: Bundle = .main, log: @escaping (String) -> Void) {
        self.log = log
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        #if canImport(Sparkle)
        if feed.isEmpty || key.isEmpty {
            availability = .misconfigured("this build has no SUFeedURL / SUPublicEDKey")
        } else if Data(base64Encoded: key)?.count != 32 {
            availability = .misconfigured("SUPublicEDKey is not a 32-byte Ed25519 key")
        } else {
            availability = .ready
        }
        #else
        _ = feed; _ = key
        availability = .missingFramework
        #endif
        super.init()
        #if canImport(Sparkle)
        if availability == .ready {
            let defaults = UserDefaults.standard
            // Off until asked, and decided before the updater starts so
            // Sparkle never schedules a check or shows its permission
            // request on the second launch.
            if defaults.object(forKey: Self.automaticChecksDefaultsKey) == nil {
                defaults.set(false, forKey: Self.automaticChecksDefaultsKey)
            }
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            self.controller = controller
            controller.startUpdater()
            log("updater: Sparkle \(Self.frameworkVersion ?? "?") on \(feed), channel \(selectedChannel), automatic checks \(automaticallyChecksForUpdates ? "on" : "off")")
        } else {
            log("updater: \(availability.description)")
        }
        #else
        log("updater: \(availability.description)")
        #endif
        Self.shared = self
    }

    static var frameworkVersion: String? {
        #if canImport(Sparkle)
        return Bundle(for: SPUStandardUpdaterController.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #else
        return nil
        #endif
    }

    var isAvailable: Bool { availability == .ready }

    /// True when a manual check can start now (no session in progress).
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return controller?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }

    /// The user's "Check for Updates…": shows Sparkle's standard UI.
    func checkForUpdates(_ sender: Any? = nil) {
        #if canImport(Sparkle)
        guard let controller else { return }
        controller.checkForUpdates(sender)
        #endif
    }

    /// Settings › General › automatic checks. Sparkle persists it.
    var automaticallyChecksForUpdates: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            guard let controller, controller.updater.automaticallyChecksForUpdates != newValue else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            log("updater: automatic checks \(newValue ? "on" : "off")")
            NotificationCenter.default.post(name: Self.automaticChecksDidChange, object: self)
            #endif
        }
    }

    /// `stable` or `beta`, as Settings stores it.
    var selectedChannel: String {
        Self.channel(from: UserDefaults.standard)
    }

    nonisolated static func channel(from defaults: UserDefaults) -> String {
        defaults.string(forKey: channelDefaultsKey) == betaChannel ? betaChannel : "stable"
    }

    /// The channels Sparkle may offer: only the untagged stable items, or
    /// those plus `beta`-tagged ones.
    nonisolated static func allowedChannels(from defaults: UserDefaults) -> Set<String> {
        channel(from: defaults) == betaChannel ? [betaChannel] : []
    }

    /// The channel picker changed: the next cycle reads the new set.
    func channelDidChange() {
        #if canImport(Sparkle)
        controller?.updater.resetUpdateCycleAfterShortDelay()
        #endif
    }

    var lastUpdateCheckDate: Date? {
        #if canImport(Sparkle)
        return controller?.updater.lastUpdateCheckDate
        #else
        return nil
        #endif
    }
}

#if canImport(Sparkle)
extension SparkleUpdater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.allowedChannels(from: .standard)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let message = error.map { "updater: check finished with \($0.localizedDescription)" } ?? "updater: check finished, nothing newer"
        Task { @MainActor [weak self] in self?.log(message) }
    }
}
#endif
