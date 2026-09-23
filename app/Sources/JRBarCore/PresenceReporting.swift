import Foundation

/// When the app tells the daemon what its sensors see (`presence`,
/// docs/CORE-PROTOCOL.md). A live microphone or camera is a call: the
/// daemon takes the sounds off the headset, holds the escalation ladder at
/// the light, asks Confetti to hold its burst and turns a `call` Dot red.
///
/// A report stands for 180 s, so the rules are few: an edge goes out at
/// once; while a sensor is live the same report is renewed every minute,
/// well inside that window; the call's end goes out once and then nothing
/// does — a quiet report left to go stale still reads as no call. The
/// first report of a connection always goes, quiet or not, so a call an
/// earlier run reported ends now instead of three minutes from now. Pure,
/// so the timing is pinned without a socket.
public struct PresenceReporting: Equatable, Sendable {
    /// Well inside the daemon's 180 s: a renewal that misses still leaves
    /// the report standing for the next one.
    public static let renewInterval: TimeInterval = 60
    /// A report the daemon did not take is tried again this soon — the
    /// same report only; a new edge never waits on an old failure.
    public static let retryInterval: TimeInterval = 10

    /// The last report the daemon took, and when.
    public private(set) var lastSent: CorePresenceReport?
    public private(set) var lastSentAt: Date?
    /// The last report the daemon did not take, and when; cleared by the
    /// next one it does.
    public private(set) var lastFailed: CorePresenceReport?
    public private(set) var lastFailedAt: Date?

    public init() {}

    /// The report a reading makes. Only the two sensors the app watches:
    /// no screen share, lock, idle or Focus — each of those stays the
    /// daemon's own reading until the app has one to give.
    public static func report(for reading: NotchSensorState) -> CorePresenceReport {
        CorePresenceReport(mic: reading.microphoneInUse, camera: reading.cameraInUse)
    }

    /// What to send now, if anything. Nothing while the daemon is away.
    public func due(reading: NotchSensorState, connected: Bool, now: Date) -> CorePresenceReport? {
        guard connected else { return nil }
        let report = Self.report(for: reading)
        if report == lastFailed, let lastFailedAt,
           now.timeIntervalSince(lastFailedAt) < Self.retryInterval {
            return nil
        }
        guard let lastSent, let lastSentAt else { return report }
        if report != lastSent { return report }
        if report.sensingCall, now.timeIntervalSince(lastSentAt) >= Self.renewInterval { return report }
        return nil
    }

    /// When `due` next owes something for an unchanged reading: the retry
    /// after a failure, else the renewal while a call is on; nil while
    /// nothing is owed (an edge asks on its own).
    public func nextCheck(connected: Bool) -> Date? {
        guard connected else { return nil }
        if lastFailed != nil, let lastFailedAt {
            return lastFailedAt.addingTimeInterval(Self.retryInterval)
        }
        guard let lastSent, lastSent.sensingCall, let lastSentAt else { return nil }
        return lastSentAt.addingTimeInterval(Self.renewInterval)
    }

    public mutating func sent(_ report: CorePresenceReport, at now: Date) {
        lastSent = report
        lastSentAt = now
        lastFailed = nil
        lastFailedAt = nil
    }

    public mutating func failed(_ report: CorePresenceReport, at now: Date) {
        lastFailed = report
        lastFailedAt = now
    }

    /// The connection went away: the next one hears the reading afresh.
    public mutating func reset() {
        self = PresenceReporting()
    }

    /// The call fact the toys go by. The app's own reading answers the
    /// moment it moves; the daemon's `state.presence` carries it, and
    /// `celebrations_held` is the daemon asking every celebration to wait.
    /// `presence` is nil while the daemon is away — a frame left over from
    /// before a disconnect is not a fact.
    public static func onCall(reading: NotchSensorState, presence: CorePresence?) -> Bool {
        reading.anyInUse || presence?.isOnCall == true || presence?.holdsCelebrations == true
    }
}
