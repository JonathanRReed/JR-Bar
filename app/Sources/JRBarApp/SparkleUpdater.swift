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

    /// A scheduled check found an update and Sparkle left the showing to
    /// us (a gentle reminder): the display version. The delegate says so
    /// on JR-Bar's own surfaces instead of a window stealing focus from
    /// whatever the person is doing.
    var onUpdateReady: ((String) -> Void)?
    /// The person has looked at the update (or the session ended), so any
    /// reminder can go.
    var onUpdateAttended: (() -> Void)?

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
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
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

/// What the running build is, in the words the Version row uses:
/// "0.9.9 (build 1801, 1800c0a)". The marketing version alone cannot
/// tell two rebuilds apart — Sparkle orders by `CFBundleVersion`, the
/// monotonic build number the packager stamps — and the commit is the
/// `JRBarCommit` key it writes beside it, so a bug report names the
/// exact tree that was running.
enum AppVersion {
    /// The row's text from the three Info.plist facts. A build number
    /// equal to the marketing version (a bundle from before the build
    /// number, which stamped the version twice) says nothing new and is
    /// left out; so is an `unknown` or missing commit. A full hash
    /// shortens to its first seven characters and keeps a `-dirty` tail.
    nonisolated static func describe(shortVersion: String?, build: String?, commit: String?) -> String {
        let version = trimmed(shortVersion) ?? "dev"
        var details: [String] = []
        if let build = trimmed(build), build != version {
            details.append("build \(build)")
        }
        if let commit = trimmed(commit), commit != "unknown" {
            let dirty = commit.hasSuffix("-dirty")
            let hash = dirty ? String(commit.dropLast("-dirty".count)) : commit
            details.append(String(hash.prefix(7)) + (dirty ? "-dirty" : ""))
        }
        return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
    }

    private nonisolated static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// The running bundle's own answer.
    static func describe(bundle: Bundle = .main) -> String {
        describe(shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                 build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                 commit: bundle.object(forInfoDictionaryKey: "JRBarCommit") as? String)
    }
}

/// Other installed copies of JR-Bar. An update replaces only the bundle
/// that is running, so a second install — /Applications beside
/// ~/Applications — goes stale, and Spotlight or a Login Item can start
/// the old one. Only install locations count: the build folders a
/// source checkout leaves behind are not installs.
enum InstalledCopies {
    /// The copies worth a word: under /Applications or ~/Applications,
    /// not the running bundle, each once.
    nonisolated static func stale(among copies: [URL], running: URL, home: URL) -> [URL] {
        let runningPath = running.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications", home.appending(path: "Applications").standardizedFileURL.path]
        var seen = Set<String>()
        return copies.filter { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != runningPath, seen.insert(path).inserted else { return false }
            return roots.contains { path.hasPrefix($0 + "/") }
        }
    }

    /// Where the "already mentioned" marks live — one per stale path, so
    /// a copy kept on purpose is named once, not on every launch.
    nonisolated static func noticedKey(_ url: URL) -> String { "staleCopyNoticed.\(url.path)" }

    /// Names one not-yet-mentioned stale copy on the panel, with Show to
    /// reveal it, so Spotlight or a Login Item never starts it unseen.
    @MainActor
    static func mentionOnce(notices: LaunchNotices = .shared, defaults: UserDefaults = .standard) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        let stale = stale(among: copies, running: Bundle.main.bundleURL, home: home)
        guard let first = stale.first(where: { !defaults.bool(forKey: noticedKey($0)) }) else { return }
        defaults.set(true, forKey: noticedKey(first))
        let folder = first.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
        notices.say(.init(key: "stale-copy",
                          text: "Another JR-Bar is installed in \(folder) — updates replace only this one",
                          actionTitle: "Show") {
            NSWorkspace.shared.activateFileViewerSelecting([first])
        })
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

/// Gentle reminders: a menu-bar app has no window the person is looking
/// at, so Sparkle's alert for a scheduled find either steals focus or
/// sits behind everything. Unless Sparkle judges the moment right for
/// immediate focus (just launched, or the Mac has been idle), JR-Bar
/// shows the reminder itself and the alert waits for Check for Updates.
extension SparkleUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { @MainActor [weak self] in
            self?.log("updater: \(version) is ready — reminding gently")
            self?.onUpdateReady?(version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.onUpdateAttended?() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak self] in self?.onUpdateAttended?() }
    }
}
#endif
