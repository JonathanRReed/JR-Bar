import Foundation
import Observation

/// How hard JR-Bar's decorative motion may work right now. The tank's
/// plants and light, the island's breathing, the playing bars and the
/// buddy's walk are set dressing: they cost battery and heat for a look,
/// so when the Mac asks for restraint they ease off. Low Power Mode or a
/// serious thermal state halves their frame rate; a critical thermal state
/// also stops the ones that only decorate. Everything recovers by itself
/// when the Mac does.
///
/// Only decoration obeys it. A functional state, an alert, a count or a
/// reading never reads this, and at normal power every interval and every
/// pause is exactly what it was before the policy existed.
///
/// The policy is pure: the two facts it reads are plain values, so a test
/// cranks it with injected ones. `PowerConditions` is the live feed.
public struct PowerPolicy: Equatable, Sendable {
    /// `ProcessInfo.ThermalState`, named for the policy.
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical

        public static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }
    }

    /// What the decorative motion may spend.
    public enum Budget: Int, Sendable {
        /// Normal power: nothing changes.
        case full
        /// Low Power Mode or a serious thermal state: half the frame rate.
        case halved
        /// A critical thermal state: half the frame rate, and the passes
        /// that only decorate stand still.
        case paused
    }

    public var lowPowerMode: Bool
    public var thermal: Thermal

    public init(lowPowerMode: Bool = false, thermal: Thermal = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    /// Normal power.
    public static let normal = PowerPolicy()

    public var budget: Budget {
        if thermal >= .critical { return .paused }
        if lowPowerMode || thermal >= .serious { return .halved }
        return .full
    }

    /// The gap between frames of a decorative pass whose normal gap is
    /// `base`. Under Reduce Motion the pass already runs at its own slow
    /// `heartbeat` and the policy leaves that alone.
    public func interval(_ base: TimeInterval, reduceMotion: Bool = false,
                         heartbeat: TimeInterval = 1) -> TimeInterval {
        if reduceMotion { return heartbeat }
        return budget == .full ? base : base * 2
    }

    /// Whether a pass that only decorates stands still: it is out of sight
    /// (`occluded`, the pause it always had) or the Mac is critically hot.
    /// A pass that carries state — a simulation, a count — never passes
    /// `decorativeOnly: false` here and keeps running, halved.
    public func pauses(occluded: Bool, decorativeOnly: Bool = true) -> Bool {
        occluded || (decorativeOnly && budget == .paused)
    }
}

/// The live power facts, read from the system and kept current. Low Power
/// Mode and the thermal state each post a notification when they change,
/// so nothing polls and no timer runs; views read `policy` in `body` and
/// redraw when it moves.
@MainActor
@Observable
public final class PowerConditions {
    public static let shared = PowerConditions()

    /// The policy right now.
    public private(set) var policy: PowerPolicy

    @ObservationIgnored private let read: @MainActor () -> PowerPolicy
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private nonisolated let center: NotificationCenter

    /// The system's own answer.
    public nonisolated static func systemPolicy(_ info: ProcessInfo = .processInfo) -> PowerPolicy {
        PowerPolicy(lowPowerMode: info.isLowPowerModeEnabled, thermal: PowerPolicy.Thermal(info.thermalState))
    }

    /// `read` is the system's answer in the app; a test hands in its own
    /// and a notification centre of its own.
    public init(read: @escaping @MainActor () -> PowerPolicy = { PowerConditions.systemPolicy() },
                center: NotificationCenter = .default) {
        self.read = read
        self.center = center
        self.policy = read()
        let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange,
                                          ProcessInfo.thermalStateDidChangeNotification]
        for name in names {
            // Posted on whatever thread the system chooses; the answer is
            // read on the main actor.
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refresh() }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
                }
            }
            observers.append(token)
        }
    }

    deinit {
        for token in observers { center.removeObserver(token) }
    }

    /// Read the facts again; an unchanged answer changes nothing, so no
    /// view redraws for a notification that moved nothing.
    public func refresh() {
        let latest = read()
        if latest != policy { policy = latest }
    }
}
