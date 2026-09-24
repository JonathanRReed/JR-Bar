import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// `closed_lid.sleep_error`: said once per distinct (error,
/// last_sleep_at), as a panel notice and a local banner.
@Suite("Closed-lid sleep error")
@MainActor
struct SleepErrorNoticeTests {
    @MainActor
    final class Banners {
        var bodies: [String] = []
    }

    private func lid(_ json: String) throws -> CoreClosedLid {
        try JSONDecoder().decode(CoreClosedLid.self, from: Data(json.utf8))
    }

    @Test("one failure is said once; a new failure is said again; none says nothing")
    func oncePerFailure() throws {
        let suite = "jrbar.tests.sleep-error.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = EventCoordinator(core: CoreModel(), hudAnchor: { nil })
        let notices = LaunchNotices()
        let banners = Banners()
        notices.deliverBanner = { _, _, body in banners.bodies.append(body) }
        coordinator.sleepErrorDefaults = defaults
        coordinator.notices = notices

        coordinator.noteClosedLid(try lid(#"{"holding":false}"#))
        #expect(notices.waiting.isEmpty && banners.bodies.isEmpty)

        let failed = try lid(#"{"sleep_error":"pmset exited 1","last_sleep_at":1800000000}"#)
        coordinator.noteClosedLid(failed)
        coordinator.noteClosedLid(failed)
        #expect(banners.bodies == ["The Mac didn't sleep when the closed-lid hold let go: pmset exited 1"])
        #expect(notices.waiting.map(\.key) == ["sleep-error"])

        coordinator.noteClosedLid(try lid(#"{"sleep_error":"pmset exited 1","last_sleep_at":1800009000}"#))
        #expect(banners.bodies.count == 2, "a later failure is news")
    }

    @Test("a long error is cut to a line")
    func cut() {
        let text = EventCoordinator.sleepErrorText(String(repeating: "x", count: 300) + "\nsecond line")
        #expect(text.hasSuffix("…"))
        #expect(!text.contains("second line"))
    }
}
