import Foundation
import JRBarCore

/// The five-minute heads-up before a timed Keep Awake session ends: one
/// scheduled event, armed for `fireAt` and dropped the moment the hold
/// changes. Nothing ticks — `sync` runs only when the hold itself moves
/// (`SystemTogglesStore.State.syncAwakeChip`), and the event fires once.
///
/// At the moment it fires the notice still has to be allowed: the card's
/// "Heads-up before it ends" switch, and the quiet that holds banners
/// (Focus, quiet hours, Pause), the same rule every courtesy banner obeys.
/// A notice already shown is taken back when the session it was about
/// ends or changes.
@MainActor
final class KeepAwakeHeadsUpScheduler {
    /// Hands back a way to cancel; a test passes its own and fires it by hand.
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any KeepAwakeHeadsUpTicket

    /// Where the card's switch lives — app-local, on by default.
    nonisolated static let enabledDefaultsKey = "jrbar.keepAwakeHeadsUp"

    let defaults: UserDefaults
    var schedule: Schedule = KeepAwakeHeadsUpScheduler.dispatchOnce
    /// Posts the notice; nil until the app wires its notifications, and
    /// while it is nil nothing is armed at all.
    var deliver: (@MainActor (KeepAwakeHeadsUp) -> Void)?
    var withdraw: (@MainActor () -> Void)?
    /// The quiet that holds banners right now (`state.focus`).
    var focus: @MainActor () -> CoreFocus? = { nil }

    private(set) var armed: KeepAwakeHeadsUp?
    private(set) var shown: KeepAwakeHeadsUp?
    private var ticket: (any KeepAwakeHeadsUpTicket)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    /// Whether an event is waiting to fire — what "off leaves nothing
    /// behind" checks.
    var isArmed: Bool { ticket != nil }

    /// The hold moved: arm one event for its plan, or none.
    func sync(reading: KeepAwakeReading, now: Date) {
        let plan = deliver != nil && enabled ? KeepAwakeHeadsUp.plan(for: reading, now: now) : nil
        // A notice on screen stays only while its own session holds.
        if let shown, !Self.sameSession(shown, reading) {
            withdraw?()
            self.shown = nil
        }
        guard plan != armed else { return }
        ticket?.cancel()
        ticket = nil
        armed = plan
        guard let plan else { return }
        let delay = max(0, plan.fireAt.timeIntervalSince(now))
        ticket = schedule(delay) { [weak self] in self?.fire(plan) }
    }

    /// The session the notice spoke of is still the one holding the Mac.
    private static func sameSession(_ shown: KeepAwakeHeadsUp, _ reading: KeepAwakeReading) -> Bool {
        guard reading.holding, case .lease(.until(let end)) = reading.state else { return false }
        return end == shown.end
    }

    private func fire(_ plan: KeepAwakeHeadsUp) {
        ticket = nil
        guard plan == armed, enabled, let deliver else { return }
        guard Self.allowed(focus: focus()) else { return }
        shown = plan
        deliver(plan)
    }

    /// The quiet rule every courtesy banner obeys (`EventPolicy.holdingQuiet`).
    nonisolated static func allowed(focus: CoreFocus?) -> Bool {
        let probe = EventDelivery(notification: .init(identifier: KeepAwakeHeadsUp.identifier,
                                                      title: "", body: "", category: .plain))
        let event = CoreEvent(id: KeepAwakeHeadsUp.identifier, kind: "keep_awake_heads_up")
        return EventPolicy.holdingQuiet(probe, for: event, focus: focus).notification != nil
    }

    /// Off: nothing armed, nothing left on screen.
    func stop() {
        ticket?.cancel()
        ticket = nil
        armed = nil
        if shown != nil { withdraw?() }
        shown = nil
    }

    /// The real schedule: one main-queue work item at a wall-clock deadline,
    /// so a session counted in wall time is warned in wall time.
    static let dispatchOnce: Schedule = { delay, fire in
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
        return DispatchTicket(item: item)
    }

    final class DispatchTicket: KeepAwakeHeadsUpTicket {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

/// One scheduled heads-up, cancellable.
@MainActor
protocol KeepAwakeHeadsUpTicket: AnyObject {
    func cancel()
}
