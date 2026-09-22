import Foundation

/// One reading of the machine's capture hardware — the island's
/// honest LEDs. `microphoneInUse` is CoreAudio's "the default input
/// device is running somewhere"; `cameraInUse` is the CoreMediaIO
/// twin, `DeviceIsRunningSomewhere` over the camera list. Both are
/// observations of system state only — asking the question never
/// opens a mic or a lens and never sees a frame or a sample, so the
/// dots can never become the thing they warn about.
public struct NotchSensorState: Equatable, Sendable {
    /// macOS's orange dot: some microphone is capturing.
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
