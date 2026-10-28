import AppKit
import SwiftUI

/// The buddy's eyes on the pointer. When the pointer comes within about
/// `reach` points of the buddy, its pupils ease toward it, a little and
/// inside the eye; further off they go back to the mood's own look.
///
/// It runs on the app's shared `PointerWatcher`: the watcher hears moves
/// off one listen-only tap and wakes this at most 20 times a second, so a
/// still pointer costs nothing and no timer runs. The view subscribes only
/// while the buddy is on screen, awake, and Reduce Motion is off; the last
/// subscriber leaving stops the tap. The easing is drawn by the buddy's
/// own frame clock from three stored values, so it needs no clock either.
@MainActor
@Observable
final class BuddyGaze {
    /// Where the pupils look, in the eye's own points at 1×, and how much
    /// of the mood's look it replaces (0 is the mood's look whole).
    struct Look: Equatable, Sendable {
        var x = 0.0
        var y = 0.0
        var weight = 0.0

        static let rest = Look()

        static func mix(_ a: Look, _ b: Look, _ t: Double) -> Look {
            Look(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                 weight: a.weight + (b.weight - a.weight) * t)
        }
    }

    /// How close the pointer comes, in points at 1×, before the eyes
    /// follow it fully. They let go over half as far again past it.
    nonisolated static let reach: Double = 160
    /// The farthest a pupil travels, in points at 1×: inside the eye,
    /// about what the mood poses already use.
    nonisolated static let travel = CGSize(width: 0.8, height: 0.55)
    /// How long a new look takes to settle.
    nonisolated static let ease: TimeInterval = 0.2

    /// Where the pupils look for a pointer at `pointer`, with the buddy's
    /// eyes at `eyes`. Both are screen points (y up); `scale` is the
    /// floating size, which widens the reach with the pet. Rounded to
    /// small steps so a hand drifting a point or two writes nothing.
    nonisolated static func target(pointer: CGPoint, eyes: CGPoint, scale: Double = 1) -> Look {
        let size = max(1, scale.isFinite ? scale : 1)
        let dx = Double(pointer.x - eyes.x)
        let dy = Double(eyes.y - pointer.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let reach = Self.reach * size
        guard distance < reach * 1.5 else { return .rest }
        let weight = distance <= reach ? 1 : 1 - (distance - reach) / (reach * 0.5)
        // On the face the eyes look straight out rather than cross.
        let near = min(1, distance / (14 * size))
        let x = distance > 0 ? dx / distance * travel.width * near : 0
        let y = distance > 0 ? dy / distance * travel.height * near : 0
        return Look(x: rounded(x, 0.05), y: rounded(y, 0.05), weight: rounded(weight, 0.1))
    }

    nonisolated private static func rounded(_ value: Double, _ step: Double) -> Double {
        (value / step).rounded() * step
    }

    /// The look at `now`: from the last settled point toward the target,
    /// smoothstep-eased over `ease`.
    func look(at now: TimeInterval) -> Look {
        let t = min(1, max(0, (now - since) / Self.ease))
        return Look.mix(from, to, t * t * (3 - 2 * t))
    }

    private(set) var from = Look.rest
    private(set) var to = Look.rest
    private(set) var since: TimeInterval = 0

    /// Where moves come from; a test hands in its own.
    @ObservationIgnored var watch: any PointerWatching = PointerWatcher.shared
    /// The pointer, in screen points; a test hands in its own.
    @ObservationIgnored var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    /// The buddy's eyes on screen, or nil while it has no window.
    @ObservationIgnored var eyes: @MainActor () -> CGPoint? = { nil }
    /// The same clock the buddy's frames draw on.
    @ObservationIgnored var clock: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// The floating size multiplier.
    @ObservationIgnored var scale: Double = 1
    @ObservationIgnored private var token: Int?

    /// Whether it is listening for moves right now.
    var isWatching: Bool { token != nil }

    /// Listen while `active`, let go otherwise. Letting go eases the eyes
    /// back to the mood's own look.
    func setActive(_ active: Bool) {
        if active {
            guard token == nil else { return }
            token = watch.subscribe({ [weak self] in self?.moved() },
                                    onLost: { [weak self] in self?.lost() })
            if token != nil { moved() }
        } else {
            if let token { watch.unsubscribe(token) }
            token = nil
            aim(.rest)
        }
    }

    /// Whether the eyes should follow at all: on screen, awake, moving.
    /// Mini has no eyes; Reduce Motion keeps them centred.
    nonisolated static func wanted(visible: Bool, awake: Bool, still: Bool, mini: Bool) -> Bool {
        visible && awake && !still && !mini
    }

    /// The watcher's tap died; the token is gone with it.
    private func lost() {
        token = nil
        aim(.rest)
    }

    /// A move: read the pointer and the eyes, and aim if the look changed.
    func moved() {
        guard let eyes = eyes() else { return }
        aim(Self.target(pointer: pointer(), eyes: eyes, scale: scale))
    }

    private func aim(_ target: Look) {
        guard target != to else { return }
        let now = clock()
        from = look(at: now)
        to = target
        since = now
    }
}

/// A point inside the buddy's frame that reports where it is on screen,
/// read only when a move arrives. It takes no clicks.
struct BuddyGazeAnchor: NSViewRepresentable {
    let gaze: BuddyGaze

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        attach(view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        attach(view)
    }

    private func attach(_ view: AnchorView) {
        gaze.eyes = { [weak view] in view?.eyesOnScreen }
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The frame's centre, a touch above it where the eyes sit.
        var eyesOnScreen: CGPoint? {
            guard let window else { return nil }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            return CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.06)
        }
    }
}
