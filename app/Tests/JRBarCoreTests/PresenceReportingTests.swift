import Foundation
import Testing
@testable import JRBarCore

/// When the app tells the daemon what its mic and camera see: an edge at
/// once, a renewal every minute while a call is on (the daemon holds a
/// report 180 s), the call's end once, and nothing after it.
@Suite("Presence reporting")
struct PresenceReportingTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let quiet = NotchSensorState()
    private let mic = NotchSensorState(microphoneInUse: true)
    private let camera = NotchSensorState(cameraInUse: true)

    @Test("the report carries the two sensors and nothing the app does not read")
    func reportShape() {
        let report = PresenceReporting.report(for: NotchSensorState(microphoneInUse: true, cameraInUse: true))
        #expect(report.mic && report.camera && !report.screenShared)
        #expect(report.sensingCall)
        #expect(report.arguments == ["mic": .bool(true), "camera": .bool(true), "screen_shared": .bool(false)],
                "no lock, idle or calendar keys, and no Focus the app did not read: those stay the daemon's")
        #expect(!PresenceReporting.report(for: quiet).sensingCall)
    }

    @Test("a Focus the app can read rides the report; one it cannot leaves the key out")
    func focusShape() {
        let focused = PresenceReporting.report(for: quiet, focus: true)
        #expect(focused.arguments["focus"] == .bool(true))
        #expect(!focused.sensingCall, "a Focus is not a call")
        #expect(PresenceReporting.report(for: quiet, focus: false).arguments["focus"] == .bool(false))
        #expect(PresenceReporting.report(for: quiet).arguments["focus"] == nil,
                "unread: the daemon keeps its own reading")
    }

    @Test("a Focus-only report is renewed every minute, and its end is said once")
    func focusRenews() throws {
        var reporting = PresenceReporting()
        reporting.sent(PresenceReporting.report(for: quiet, focus: false), at: t0)
        let started = try #require(reporting.due(reading: quiet, focus: true, connected: true,
                                                 now: t0.addingTimeInterval(3)), "the Focus coming on is an edge")
        reporting.sent(started, at: t0.addingTimeInterval(3))
        #expect(reporting.due(reading: quiet, focus: true, connected: true, now: t0.addingTimeInterval(40)) == nil)
        #expect(reporting.nextCheck(connected: true) == t0.addingTimeInterval(63))
        let renewed = try #require(reporting.due(reading: quiet, focus: true, connected: true,
                                                 now: t0.addingTimeInterval(63)))
        #expect(renewed == started)
        reporting.sent(renewed, at: t0.addingTimeInterval(63))
        let ended = try #require(reporting.due(reading: quiet, focus: false, connected: true,
                                             now: t0.addingTimeInterval(70)))
        #expect(ended.focus == false)
        reporting.sent(ended, at: t0.addingTimeInterval(70))
        #expect(reporting.nextCheck(connected: true) == nil, "a Focus that is off is not renewed")
        #expect(reporting.due(reading: quiet, focus: false, connected: true, now: t0.addingTimeInterval(500)) == nil)
    }

    @Test("nothing goes while the daemon is away")
    func disconnected() {
        let reporting = PresenceReporting()
        #expect(reporting.due(reading: mic, connected: false, now: t0) == nil)
        #expect(reporting.nextCheck(connected: false) == nil)
    }

    @Test("a connection's first report goes even when quiet, then only edges")
    func firstReport() {
        var reporting = PresenceReporting()
        let first = reporting.due(reading: quiet, connected: true, now: t0)
        #expect(first == CorePresenceReport(mic: false, camera: false),
                "a quiet first report ends a call an earlier run left standing")
        reporting.sent(first!, at: t0)
        #expect(reporting.due(reading: quiet, connected: true, now: t0.addingTimeInterval(600)) == nil,
                "a quiet reading is never renewed — stale already reads as no call")
        #expect(reporting.nextCheck(connected: true) == nil)
    }

    @Test("a call goes at once and is renewed every minute until it ends")
    func renewal() throws {
        var reporting = PresenceReporting()
        reporting.sent(PresenceReporting.report(for: quiet), at: t0)
        let start = try #require(reporting.due(reading: mic, connected: true, now: t0.addingTimeInterval(5)))
        #expect(start.mic)
        reporting.sent(start, at: t0.addingTimeInterval(5))
        #expect(reporting.due(reading: mic, connected: true, now: t0.addingTimeInterval(64)) == nil)
        #expect(reporting.nextCheck(connected: true) == t0.addingTimeInterval(65))
        #expect(PresenceReporting.renewInterval < 180, "renewed well inside the daemon's window")
        let renewed = try #require(reporting.due(reading: mic, connected: true, now: t0.addingTimeInterval(65)))
        #expect(renewed == start)
        reporting.sent(renewed, at: t0.addingTimeInterval(65))
        // The camera joining is an edge, not a renewal.
        let both = NotchSensorState(microphoneInUse: true, cameraInUse: true)
        #expect(reporting.due(reading: both, connected: true, now: t0.addingTimeInterval(66))?.camera == true)
        // The end goes once, and then nothing does.
        let end = try #require(reporting.due(reading: quiet, connected: true, now: t0.addingTimeInterval(70)))
        #expect(!end.sensingCall)
        reporting.sent(end, at: t0.addingTimeInterval(70))
        #expect(reporting.due(reading: quiet, connected: true, now: t0.addingTimeInterval(500)) == nil)
    }

    @Test("a refused report is retried, but a new edge never waits on it")
    func retry() throws {
        var reporting = PresenceReporting()
        let report = try #require(reporting.due(reading: camera, connected: true, now: t0))
        reporting.failed(report, at: t0)
        #expect(reporting.due(reading: camera, connected: true, now: t0.addingTimeInterval(3)) == nil)
        #expect(reporting.nextCheck(connected: true) == t0.addingTimeInterval(PresenceReporting.retryInterval))
        #expect(reporting.due(reading: camera, connected: true, now: t0.addingTimeInterval(10)) == report)
        // The camera went off inside the back-off: that report goes now.
        #expect(reporting.due(reading: quiet, connected: true, now: t0.addingTimeInterval(4)) != nil)
        reporting.sent(report, at: t0.addingTimeInterval(10))
        #expect(reporting.lastFailed == nil)
    }

    @Test("a new connection hears the reading afresh")
    func reset() throws {
        var reporting = PresenceReporting()
        let report = try #require(reporting.due(reading: quiet, connected: true, now: t0))
        reporting.sent(report, at: t0)
        reporting.reset()
        #expect(reporting.due(reading: quiet, connected: true, now: t0.addingTimeInterval(1)) == report)
    }

    @Test("the toys' call fact: the app's own reading, carried by the daemon's")
    func callFact() throws {
        #expect(!PresenceReporting.onCall(reading: quiet, presence: nil))
        #expect(PresenceReporting.onCall(reading: mic, presence: nil), "answers before the round trip")
        #expect(PresenceReporting.onCall(reading: camera, presence: nil))
        let held = try JSONDecoder().decode(CorePresence.self, from: Data(#"{"on_call":false,"celebrations_held":true}"#.utf8))
        #expect(PresenceReporting.onCall(reading: quiet, presence: held),
                "the daemon asking celebrations to wait is a call to the toys")
        let onCall = try JSONDecoder().decode(CorePresence.self, from: Data(#"{"on_call":true}"#.utf8))
        #expect(PresenceReporting.onCall(reading: quiet, presence: onCall))
        let stale = try JSONDecoder().decode(CorePresence.self, from: Data(#"{"on_call":false,"fresh":false}"#.utf8))
        #expect(!PresenceReporting.onCall(reading: quiet, presence: stale))
    }
}
