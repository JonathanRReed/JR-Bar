import AppKit
import JRBarCore
import OSLog

/// The macOS 27 hiding mechanism (docs/AUDIT-2026-09-16.md): the menu
/// bar is one surface `MenuBarAgent` draws, and the only thing that
/// truly removes another app's item from it is the agent's own
/// *assessment mode* — the exam-lockdown feature — driven through the
/// private `MenuBarClientCore` framework. An assertion carries an
/// allowlist of system items and bundle identifiers; the agent conceals
/// every other application's items itself. No spacer, no blank
/// stretch, no «, nothing of ours drawn.
///
/// The API surface is resolved at runtime (`dlopen` + class lookup +
/// selector checks) and every call fails soft: when a point release
/// changes it, `isAvailable` turns false and the spacer engine stands
/// in. Facts about the mechanism, measured on 27.0 by Ice (PR #995) and
/// Pelmet and confirmed here: only a signed app bundle's allowlist is
/// honoured; live assertions combine as a union of allowlists, so a
/// change activates the new assertion *before* invalidating the old and
/// an app concealed on both sides never flickers; the agent ignores
/// clicks on its own clock, battery and Wi-Fi while any assertion is
/// live (Control Center still opens) — `MenuBarSystemClickBridge` lifts
/// concealment for the click and replays it; concealed items leave the
/// Accessibility tree or report stale frames, so what is hidden is
/// tracked per application, never inferred from a frame; and the agent
/// reorders items on its own, so a section is a per-application setting
/// (`MenuBarSettings.concealedApps`), not a bar position.

// MARK: - Pure planning

enum MenuBarConcealPlan {
    /// The applications an assertion must conceal for a reveal state:
    /// the hidden apps unless the hidden run is revealed, the
    /// always-hidden apps unless that run is revealed too.
    nonisolated static func concealed(apps: [String: MenuBarItemSection],
                                      revealed: Set<MenuBarItemSection>) -> Set<String> {
        var out = Set<String>()
        for (bundleID, section) in apps {
            switch section {
            case .hidden where !revealed.contains(.hidden):
                out.insert(bundleID)
            case .alwaysHidden where !revealed.contains(.alwaysHidden):
                out.insert(bundleID)
            default:
                break
            }
        }
        return out
    }

    /// The allowlist that conceals exactly `concealed` among `running`:
    /// everything running that is not concealed. Sorted so two plans
    /// with the same content compare equal.
    nonisolated static func allowlist(running: Set<String>, concealed: Set<String>) -> [String] {
        running.subtracting(concealed).sorted()
    }

    /// The first app map, taken once from the spacer model's plan: the
    /// apps whose items sat left of the JR-Bar icon become hidden, the
    /// always-hidden overrides carry over. Protected owners (the
    /// system's items) and apps without a bundle identifier (a bare
    /// helper process the agent can never conceal) are skipped.
    nonisolated static func seed(hidden: [(item: MenuBarItem, bundleID: String?)],
                                 alwaysHidden: [(item: MenuBarItem, bundleID: String?)],
                                 own bundleID: String) -> [String: MenuBarItemSection] {
        var map: [String: MenuBarItemSection] = [:]
        for (item, id) in hidden {
            guard let id, id != bundleID, !MenuBarItemLister.isProtected(item) else { continue }
            map[id] = .hidden
        }
        for (item, id) in alwaysHidden {
            guard let id, id != bundleID, !MenuBarItemLister.isProtected(item) else { continue }
            map[id] = .alwaysHidden
        }
        return map
    }

    /// The system items the agent bridges a click for: its own clock,
    /// battery and Wi-Fi ignore a press under any assertion (measured
    /// on 27.0); Control Center answers an Accessibility press without
    /// a lift, and the « never stands while nothing overflows.
    nonisolated static let bridgedIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.battery",
        "com.apple.menuextra.wifi",
        "com.apple.menuextra.bluetooth",
        "com.apple.menuextra.sound",
        "com.apple.menuextra.display",
        "com.apple.menuextra.displays",
        "com.apple.menuextra.screen-mirroring",
    ]

    /// Whether a click at `point` (Quartz) lands on a bridged system
    /// item.
    nonisolated static func bridgedItem(at point: CGPoint, items: [MenuBarItem]) -> MenuBarItem? {
        items.first {
            $0.bounds.contains(point) && MenuBarItemLister.isProtected($0)
                && $0.identifier.map(bridgedIdentifiers.contains) == true
        }
    }
}

// MARK: - The private API

/// One live assertion — the handle the agent hands back. Process-bound:
/// the agent restores the bar itself when the process dies.
final class MenuBarAssertionToken {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}

/// The runtime face of `MenuBarClientCore`'s assessment mode. Every
/// symbol is looked up by name; nothing links against the framework.
@MainActor
protocol MenuBarConcealBackend: AnyObject {
    func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken
    func invalidate(_ token: MenuBarAssertionToken)
}

@MainActor
final class MenuBarAssessmentBackend: MenuBarConcealBackend {
    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case rejected(String)
        case timedOut
        var description: String {
            switch self {
            case .unavailable: "MenuBarClientCore did not resolve"
            case .rejected(let why): "MenuBarAgent refused the assertion: \(why)"
            case .timedOut: "MenuBarAgent did not answer in 3 s"
            }
        }
    }

    nonisolated private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    nonisolated private static let configurationSelector =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    nonisolated private static let activateSelector =
        NSSelectorFromString("activateWithConfiguration:completionHandler:")
    nonisolated private static let invalidateSelector = NSSelectorFromString("invalidate")
    /// `MBSystemItemIdentifier` 0…8 on 27.0 — battery, Bluetooth, clock,
    /// displays, keyboard, volume, Wi-Fi, screen mirroring, Control
    /// Center. All of them stay: the system's items are never ours.
    nonisolated private static let allSystemItems: [Int] = Array(0...8)

    nonisolated private static let classes: (configuration: AnyClass, assertion: AnyClass)? = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
              let assertion = NSClassFromString("MBAssessmentModeAssertion"),
              configuration.instancesRespond(to: configurationSelector),
              assertion.instancesRespond(to: activateSelector),
              assertion.instancesRespond(to: invalidateSelector) else { return nil }
        return (configuration, assertion)
    }()

    /// Whether this macOS build offers the mechanism.
    nonisolated static var isAvailable: Bool { classes != nil }

    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
    }

    func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
        guard let classes = Self.classes else { throw Failure.unavailable }
        let allocSelector = NSSelectorFromString("alloc")
        guard let configuration = (classes.configuration as AnyObject).perform(allocSelector)?
                .takeUnretainedValue()
                .perform(Self.configurationSelector,
                         with: Self.allSystemItems.map { NSNumber(value: $0) } as NSArray,
                         with: allowedBundleIDs as NSArray)?
                .takeUnretainedValue(),
              let assertion = (classes.assertion as AnyObject).perform(allocSelector)?
                .takeUnretainedValue()
                .perform(NSSelectorFromString("init"))?
                .takeUnretainedValue() else { throw Failure.unavailable }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                let completion: @convention(block) (Any?) -> Void = { error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: Failure.rejected(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
                _ = assertion.perform(Self.activateSelector, with: configuration, with: completion)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard once.claim() else { return }
                    continuation.resume(throwing: Failure.timedOut)
                }
            }
        } catch {
            _ = assertion.perform(Self.invalidateSelector)
            throw error
        }
        return MenuBarAssertionToken(assertion)
    }

    func invalidate(_ token: MenuBarAssertionToken) {
        _ = token.object.perform(Self.invalidateSelector)
    }
}

// MARK: - The controller

/// Keeps one live assertion in step with a target concealed set.
/// `apply` is serialized: a call that lands while one is in flight
/// waits its turn, so the bar never sees two half-transitions.
@MainActor
final class MenuBarConcealer {
    private struct Live {
        let concealed: Set<String>
        let allowlist: [String]
        let token: MenuBarAssertionToken
    }

    private let backend: any MenuBarConcealBackend
    private var live: Live?
    private var queue: Task<Void, Never>?
    /// The last set asked for — what a suspend restores.
    private(set) var target: Set<String> = []
    private(set) var running: Set<String> = []
    /// The last failure, for the card. nil while the agent answers.
    private(set) var lastError: String?
    var onChange: (@MainActor () -> Void)?

    /// The assertion-free beat a newly registered item needs to be
    /// adopted by the agent.
    nonisolated static let adoptionBeat: TimeInterval = 0.35

    init(backend: any MenuBarConcealBackend = MenuBarAssessmentBackend()) {
        self.backend = backend
    }

    var isConcealing: Bool { live != nil }
    var concealedApps: Set<String> { live?.concealed ?? [] }

    /// Conceal exactly `concealed` among `running`. An empty set
    /// releases everything — no assertion at all, so the system's
    /// items take clicks natively again.
    func apply(concealed: Set<String>, running: Set<String>) {
        target = concealed
        self.running = running
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.converge()
        }
    }

    /// Everything back — the deliberate release (a disable, a quit).
    func releaseAll() {
        target = []
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            self?.dropLive()
        }
    }

    /// Lift concealment for `interval` and put it back: the click
    /// bridge's window. Returns once the lift has landed.
    func suspend(for interval: TimeInterval) async {
        let previous = queue
        let task = Task { [weak self] in
            await previous?.value
            self?.dropLive()
        }
        queue = task
        await task.value
        let restore = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            await self?.converge()
        }
        let before = queue
        queue = Task { await before?.value; await restore.value }
    }

    private func converge() async {
        let concealed = target.intersection(running)
        if concealed.isEmpty {
            dropLive()
            return
        }
        let allowlist = MenuBarConcealPlan.allowlist(running: running, concealed: concealed)
        if let live, live.concealed == concealed, live.allowlist == allowlist { return }
        do {
            let token = try await backend.activate(allowedBundleIDs: allowlist)
            let old = live
            live = Live(concealed: concealed, allowlist: allowlist, token: token)
            if let old { backend.invalidate(old.token) }
            lastError = nil
            MenuBarAssessmentBackend.log.notice("conceal: \(concealed.count, privacy: .public) apps hidden by the agent (\(concealed.sorted().joined(separator: ", "), privacy: .public))")
        } catch {
            lastError = String(describing: error)
            MenuBarAssessmentBackend.log.error("conceal: \(String(describing: error), privacy: .public)")
        }
        onChange?()
    }

    private func dropLive() {
        guard let live else { return }
        backend.invalidate(live.token)
        self.live = nil
        MenuBarAssessmentBackend.log.notice("conceal: released")
        onChange?()
    }
}

// MARK: - The click bridge

/// While an assertion is live the agent ignores a click on its own
/// clock, battery or Wi-Fi. The bridge holds such a click back at the
/// session event tap, lifts concealment, replays the click at the
/// same point (the pointer never moves), and lets concealment return
/// a moment later. Replays carry a marker so the tap passes them.
final class MenuBarSystemClickBridge: @unchecked Sendable {
    nonisolated static let replayMarker: Int64 = 0x4A52_4241_5231
    /// The lift a replay needs before the agent will act on it — 80 ms
    /// lost none of sixteen clicks in Ice's measurement; 100 leaves
    /// room.
    nonisolated static let liftDelay: TimeInterval = 0.10
    /// How long concealment stays lifted after the replay — the clock's
    /// panel opens ~166 ms after its click; it stays open when
    /// concealment returns.
    nonisolated static let liftWindow: TimeInterval = 0.45

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var items: [MenuBarItem] = []
    private var concealing = false
    private var swallowUp = false
    private let onBridge: @MainActor (CGPoint) -> Void

    init(onBridge: @escaping @MainActor (CGPoint) -> Void) {
        self.onBridge = onBridge
    }

    /// The listing's protected items and whether an assertion is live —
    /// the tap reads copies under the lock.
    func update(items: [MenuBarItem], concealing: Bool) {
        lock.withLock {
            self.items = items.filter { MenuBarItemLister.isProtected($0) }
            self.concealing = concealing
        }
    }

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<MenuBarSystemClickBridge>.fromOpaque(info).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: pointer) else {
            MenuBarAssessmentBackend.log.error("click bridge: no event tap — system item clicks stay native")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp {
            let eat = lock.withLock { () -> Bool in
                defer { swallowUp = false }
                return swallowUp
            }
            return eat ? nil : Unmanaged.passUnretained(event)
        }
        let point = event.location
        let hit: Bool = lock.withLock {
            guard concealing else { return false }
            return MenuBarConcealPlan.bridgedItem(at: point, items: items) != nil
        }
        guard hit else { return Unmanaged.passUnretained(event) }
        lock.withLock { swallowUp = true }
        let onBridge = onBridge
        Task { @MainActor in onBridge(point) }
        return nil
    }

    /// One synthetic click at `point`, tagged so the tap lets it pass.
    nonisolated static func replay(at point: CGPoint) {
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: kind,
                                      mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
