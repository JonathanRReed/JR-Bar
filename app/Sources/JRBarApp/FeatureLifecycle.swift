import AppKit
import Foundation
import QuartzCore
import Observation

/// A cancellable subscription. The task owns the Observation registration;
/// stopping it removes the registration and rejects changes already queued.
@MainActor
final class LifecycleObservation {
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    func start(read: @escaping @MainActor @Sendable () -> Void,
               changed: @escaping @MainActor @Sendable () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor in
            let values = Observations { read(); return true }
            for await _ in values {
                guard !Task.isCancelled else { break }
                changed()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    isolated deinit { task?.cancel() }
}

/// Weak records let tests see resources retained by AppKit or the run loop
/// even after an owner drops its property. Tracking never extends their life.
@MainActor
final class FeatureLifecycleHandles {
    private final class Weak<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }
    private var timers: [Weak<Timer>] = []
    private var windows: [Weak<NSWindow>] = []
    private var links: [Weak<CADisplayLink>] = []
    private var observers: [Weak<AnyObject>] = []

    func track(timer: Timer) {
        timers.removeAll { $0.value?.isValid != true }
        if !timers.contains(where: { $0.value === timer }) { timers.append(Weak(timer)) }
    }
    func track(window: NSWindow) {
        windows.removeAll { $0.value == nil }
        if !windows.contains(where: { $0.value === window }) { windows.append(Weak(window)) }
    }
    func track(displayLink: CADisplayLink) {
        links.removeAll { $0.value == nil }
        if !links.contains(where: { $0.value === displayLink }) { links.append(Weak(displayLink)) }
    }
    func track(observer: NSObjectProtocol) {
        let object = observer as AnyObject
        observers.removeAll { $0.value == nil }
        if !observers.contains(where: { $0.value === object }) { observers.append(Weak(object)) }
    }
    var liveTimers: Int { timers.filter { $0.value?.isValid == true }.count }
    var liveWindows: Int { windows.filter { $0.value != nil }.count }
    var liveDisplayLinks: Int { links.filter { $0.value != nil }.count }
    var liveObservers: Int { observers.filter { $0.value != nil }.count }
}

/// The resources each optional owner must release when its gate closes.
struct FeatureLifecycleContract: Equatable, Sendable {
    let id: String
    let resources: [String]
}

enum FeatureLifecycleRegistry {
    static let daemonFeatures: [FeatureLifecycleContract] = [
        .init(id: "provider-usage", resources: ["collection jobs", "credential reads", "local quota reads", "refresh wake"]),
        .init(id: "ambient-cues", resources: ["event observers", "planners", "pending cue state"]),
        .init(id: "remote-peers", resources: ["refresh timer", "peer refresh worker"]),
        .init(id: "led-devices", resources: ["inventory jobs", "write jobs", "brightness reads"]),
        .init(id: "lid-observation", resources: ["lid poll", "IORegistry reads"]),
        .init(id: "phone-alerts", resources: ["delivery jobs", "HTTPS connections"]),
        .init(id: "usage-hooks", resources: ["queued rules", "subprocess groups"]),
        .init(id: "creator-micro", resources: ["HID connection", "input poll", "output worker", "automation runner"]),
        .init(id: "provider-updates", resources: ["update check worker"]),
    ]

    static let features: [FeatureLifecycleContract] = [
        .init(id: "aquarium", resources: ["window", "economy timer", "session observation", "connection observation", "save work", "wallpaper panels", "idle timers", "display observers"]),
        .init(id: "notch", resources: ["island window", "capsule tasks", "media subscription", "audio tap", "power monitor", "sensor monitor", "shake monitor", "meeting watcher"]),
        .init(id: "announcements", resources: ["Focus watcher", "Bluetooth registrations", "Caps Lock monitors", "display observer"]),
        .init(id: "screen-bar", resources: ["panel", "display link", "keyframes", "island timer", "notice monitors", "menu watcher", "plan work"]),
        .init(id: "confetti", resources: ["burst window", "burst timer", "held burst"]),
        .init(id: "fold", resources: ["overlay", "display link", "lid sensor", "capture streams", "demo timer", "notification observers"]),
        .init(id: "buddy", resources: ["panels", "session observation", "display observers", "lively work", "open task"]),
        .init(id: "presence", resources: ["sensor demand", "renewal task", "camera settling task", "send task"]),
        .init(id: "focus", resources: ["Focus poll", "app activation observer"]),
        .init(id: "shelf-media", resources: ["media subscription", "lyrics request", "power monitor", "audio output observer", "Control Center listeners"]),
        .init(id: "shelf-timers", resources: ["deadline timer", "clock and wake observers"]),
        .init(id: "sound", resources: ["chime timer"]),
    ]
}
