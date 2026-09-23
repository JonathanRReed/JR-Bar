import Foundation

/// One reading of the machine's capture hardware — the island's
/// honest LEDs, and the call fact the daemon's presence report carries.
/// `microphoneInUse` is CoreAudio's per-process answer: another app is
/// running input from a real input device (a headset that is only
/// playing music is not a call, and neither is a visualizer's tap);
/// `cameraInUse` is CoreMediaIO's `DeviceIsRunningSomewhere` over the
/// camera list. Both are observations of system state only — asking
/// the question never opens a mic or a lens and never sees a frame or
/// a sample, so the dots can never become the thing they warn about.
public struct NotchSensorState: Equatable, Sendable {
    /// macOS's orange dot: another app is capturing from a microphone.
    public var microphoneInUse = false
    /// macOS's green dot: some camera is rolling.
    public var cameraInUse = false

    public init(microphoneInUse: Bool = false, cameraInUse: Bool = false) {
        self.microphoneInUse = microphoneInUse
        self.cameraInUse = cameraInUse
    }

    /// Any dot lit — the common "is there anything to draw" ask.
    public var anyInUse: Bool { microphoneInUse || cameraInUse }

    /// How many dots the state draws.
    public var dotCount: Int {
        (cameraInUse ? 1 : 0) + (microphoneInUse ? 1 : 0)
    }
}

extension NotchIsland {
    /// Room between the sensor dots and whatever shares their shoulder
    /// — a touch wider than the inter-dot gap so the pair reads as its
    /// own mark, not a stray provider dot.
    public static let sensorSeparatorWidth: CGFloat = 6

    /// The sensor dots' own width — 5 pt dots at the provider dots' 4 pt
    /// rhythm, deterministic so the frame is its drawn shape.
    static func sensorDotsWidth(_ sensors: NotchSensorState) -> CGFloat {
        let dots = sensors.dotCount
        return dots > 0 ? CGFloat(dots) * 5 + CGFloat(dots - 1) * 4 : 0
    }
}

extension NotchSensorState {
    /// The card's privacy line — who has the mic, whether a camera is
    /// rolling — or nil while neither is live. macOS names the camera's
    /// user nowhere public, so the camera is a fact; the microphone
    /// names up to two apps and counts the rest. Words live in the card,
    /// never on the ears.
    public func privacyLine(microphoneApps: [String]) -> String? {
        let apps = Self.namesList(microphoneApps)
        switch (cameraInUse, microphoneInUse) {
        case (true, true):
            return apps.map { "Camera and microphone in use · \($0)" } ?? "Camera and microphone in use"
        case (false, true):
            return apps.map { "Microphone · \($0)" } ?? "Microphone in use"
        case (true, false):
            return "Camera in use"
        case (false, false):
            return nil
        }
    }

    /// "Zoom", "Zoom, Chrome", "Zoom, Chrome +2" — nil for none.
    static func namesList(_ names: [String]) -> String? {
        var seen = Set<String>()
        let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        let shown = unique.prefix(2).joined(separator: ", ")
        return unique.count > 2 ? "\(shown) +\(unique.count - 2)" : shown
    }
}
