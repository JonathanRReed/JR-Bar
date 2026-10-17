import Foundation

/// Maps the strip's epoch anchor onto the app's media clock without
/// restarting a valid program because it has been running for a long time.
public enum ScreenBarPlaybackAnchor {
    public static func mediaTime(forEpoch epoch: TimeInterval,
                                 wallNow: TimeInterval,
                                 mediaNow: TimeInterval) -> TimeInterval? {
        guard epoch.isFinite, epoch > 0,
              wallNow.isFinite, wallNow > 0,
              mediaNow.isFinite, mediaNow >= 0 else { return nil }
        let age = wallNow - epoch
        guard age.isFinite, age >= -0.05 else { return nil }
        let anchor = mediaNow - age
        // A program started before boot has a negative media anchor.
        // Keeping it preserves the strip's phase after reconnect or wake.
        return anchor.isFinite ? anchor : nil
    }
}
