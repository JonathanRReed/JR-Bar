import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The update feed is the one this build was made with, and the log tells
/// "you are up to date" from a failed check.
@Suite("Sparkle updater")
struct SparkleUpdaterTests {
    @Test func onlyAnHttpsInfoPlistFeedIsPinned() {
        let feed = "https://github.com/JonathanRReed/JR-Bar/releases/download/updates/appcast.xml"
        #expect(SparkleUpdater.pinnedFeed(feed) == feed)
        #expect(SparkleUpdater.pinnedFeed("  \(feed)\n") == feed)
        #expect(SparkleUpdater.pinnedFeed("http://example.test/appcast.xml") == nil)
        #expect(SparkleUpdater.pinnedFeed("file:///tmp/appcast.xml") == nil)
        #expect(SparkleUpdater.pinnedFeed("https://") == nil)
        #expect(SparkleUpdater.pinnedFeed("") == nil)
        #expect(SparkleUpdater.pinnedFeed(nil) == nil)
    }

    @Test func upToDateIsNotAFailure() {
        let none = NSError(domain: "SUSparkleErrorDomain", code: 1001,
                           userInfo: [NSLocalizedDescriptionKey: "You're up to date!"])
        #expect(SparkleUpdater.cycleLine(error: nil) == "updater: check finished")
        #expect(SparkleUpdater.cycleLine(error: none) == "updater: check finished, nothing newer")
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                              userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        #expect(SparkleUpdater.cycleLine(error: offline)
                == "updater: check failed: The Internet connection appears to be offline.")
    }

    @Test func installationCancellationIsNotAFailure() {
        let canceled = NSError(domain: "SUSparkleErrorDomain", code: 4007)
        #expect(SparkleUpdater.cycleLine(error: canceled) == "updater: installation canceled")
        let unrelated = NSError(domain: "example.test", code: 4007,
                                userInfo: [NSLocalizedDescriptionKey: "A different failure"])
        #expect(SparkleUpdater.cycleLine(error: unrelated) == "updater: check failed: A different failure")
    }

    @Test func configuredBuildRequiresTheSignedFeedPolicy() {
        let feed = "https://example.test/appcast.xml"
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: true, feed: feed,
                                                       publicKey: key, requiresSignedFeed: true) == .ready)
        #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: true, feed: feed,
                                                       publicKey: key, requiresSignedFeed: false)
                == .misconfigured("this build does not require a signed update feed"))
    }

    @Test func incompleteBuildMetadataNeverEnablesUpdates() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: false, feed: nil,
                                                       publicKey: nil, requiresSignedFeed: false) == .missingFramework)
        #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: true, feed: nil,
                                                       publicKey: key, requiresSignedFeed: true)
                == .misconfigured("this build has no SUFeedURL / SUPublicEDKey"))
        #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: true, feed: "http://example.test",
                                                       publicKey: key, requiresSignedFeed: true)
                == .misconfigured("SUFeedURL is not an https address"))
        for invalidKey in ["invalid", Data(repeating: 7, count: 31).base64EncodedString(),
                           Data(repeating: 7, count: 33).base64EncodedString()] {
            #expect(SparkleUpdater.configurationAvailability(frameworkAvailable: true,
                                                           feed: "https://example.test", publicKey: invalidKey,
                                                           requiresSignedFeed: true)
                    == .misconfigured("SUPublicEDKey is not a 32-byte Ed25519 key"))
        }
    }

    @Test @MainActor func startupFailureDisablesTheUpdater() {
        let failure = NSError(domain: "SUSparkleErrorDomain", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid bundle version"])
        var starts = 0
        let failed = SparkleUpdater.startedAvailability(configuration: .ready) {
            starts += 1
            throw failure
        }
        #expect(failed == .misconfigured("updater could not start: Invalid bundle version"))
        #expect(starts == 1)
        #expect(SparkleUpdater.startedAvailability(configuration: .missingFramework) { starts += 1 }
                == .missingFramework)
        #expect(starts == 1)
        #expect(SparkleUpdater.startedAvailability(configuration: .ready) { starts += 1 } == .ready)
        #expect(starts == 2)
    }

    @Test @MainActor func completedCheckRefreshesSettingsWithoutReopeningThePage() {
        let center = NotificationCenter()
        let settings = SettingsStore(core: CoreModel())
        var checked: Date?
        settings.readLastUpdateCheck = { checked }
        let observers = settings.observeUpdaterChanges(in: center)
        defer { observers.forEach { center.removeObserver($0) } }
        settings.refreshUpdater()
        #expect(settings.lastUpdateCheck == nil)
        var lines: [String] = []
        checked = Date(timeIntervalSince1970: 1_790_000_000)
        SparkleUpdater.finishUpdateCycle(message: SparkleUpdater.cycleLine(error: nil),
                                        log: { lines.append($0) }, notificationCenter: center)
        #expect(settings.lastUpdateCheck == checked)
        #expect(lines == ["updater: check finished"])

        checked = Date(timeIntervalSince1970: 1_790_003_600)
        center.post(name: SparkleUpdater.automaticChecksDidChange, object: nil)
        #expect(settings.lastUpdateCheck == checked, "the existing notification still refreshes Settings")
    }

}
