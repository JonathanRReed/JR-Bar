import AppKit
import Foundation

/// What the watchdog can see of JR-Bar's own icon.
struct StatusIconProof: Equatable {
    /// The status item's `isVisible` flag.
    var itemVisibleFlag = true
    /// The real item's window stands on a bar row.
    var itemOnRow = false
    /// The configured style draws an icon at all.
    var styleDrawsIcon = true

    /// An icon the person can click right now, by what we can tell.
    var proven: Bool {
        if !styleDrawsIcon { return true }
        return itemOnRow
    }
}

enum StatusIconAction: Equatable {
    case none
    /// The item's flag says hidden: show it.
    case showItem
    /// The real item is not on the bar: give the bar a fresh one.
    case recreateItem(resetPlacement: Bool, reason: String)
}

/// The last resort behind every other guard: if JR-Bar's own icon cannot
/// be proven on the bar some seconds after launch, recreate the item, and
/// say why. Pure and clocked by its caller — a
/// test feeds it proofs and times.
struct StatusIconWatchdogState: Equatable {
    /// How long an icon may stay unproven before the first step.
    static let patience: TimeInterval = 6
    /// Between steps, so a recreated item gets time to register.
    static let escalationSpacing: TimeInterval = 8
    /// A bar that keeps refusing a fresh item is not helped by more.
    static let maxRecreations = 3
    /// After launch the item is recreated freely; later only a person
    /// asking (`reopened`) earns it, so a fullscreen app's hidden bar
    /// never churns the item.
    static let launchWindow: TimeInterval = 120

    private(set) var recreateUntil: Date
    private(set) var unprovenSince: Date?
    private(set) var lastStepAt: Date?
    private(set) var recreations = 0

    init(launchedAt: Date) {
        recreateUntil = launchedAt.addingTimeInterval(Self.launchWindow)
    }

    /// The person opened JR-Bar again while it runs — a sign they cannot
    /// find it. The next evaluation acts at once, whatever the clock says.
    mutating func reopened(now: Date) {
        recreateUntil = max(recreateUntil, now.addingTimeInterval(Self.launchWindow))
        unprovenSince = unprovenSince.map { min($0, now.addingTimeInterval(-Self.patience)) }
            ?? now.addingTimeInterval(-Self.patience)
        lastStepAt = nil
    }

    mutating func evaluate(_ proof: StatusIconProof, now: Date) -> StatusIconAction {
        if !proof.itemVisibleFlag { return .showItem }
        if proof.proven {
            unprovenSince = nil
            return .none
        }
        if unprovenSince == nil { unprovenSince = now }
        guard let unprovenSince, now.timeIntervalSince(unprovenSince) >= Self.patience else { return .none }
        if let lastStepAt, now.timeIntervalSince(lastStepAt) < Self.escalationSpacing { return .none }
        guard now < recreateUntil, recreations < Self.maxRecreations else { return .none }
        lastStepAt = now
        recreations += 1
        // The first try keeps the person's placement; a second means the
        // placement itself may be the trouble.
        return .recreateItem(resetPlacement: recreations >= 2,
                             reason: "our icon was not on the bar \(Int(Self.patience)) s after it was due")
    }
}

/// Runs `StatusIconWatchdogState` on a slow timer for the life of the app.
@MainActor
final class StatusIconWatchdog {
    private var state: StatusIconWatchdogState
    private let proof: () -> StatusIconProof
    private let act: (StatusIconAction) -> Void
    private let clock: () -> Date
    private var timer: Timer?

    init(launchedAt: Date = Date(),
         clock: @escaping () -> Date = Date.init,
         proof: @escaping () -> StatusIconProof,
         act: @escaping (StatusIconAction) -> Void) {
        state = StatusIconWatchdogState(launchedAt: launchedAt)
        self.clock = clock
        self.proof = proof
        self.act = act
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One look. Public so a test, or a reopen, drives it by hand.
    func tick() {
        let action = state.evaluate(proof(), now: clock())
        if action != .none { act(action) }
    }

    /// The app was opened again while running.
    func reopened() {
        state.reopened(now: clock())
        tick()
    }
}
