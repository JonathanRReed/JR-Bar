import AppKit
import JRBarCore
import Observation
import QuartzCore

/// The spring behind the magnification wave (docs/TOY-PARITY.md:
/// "Spring magnification wave at display refresh"). A `CADisplayLink`
/// on the bar's own screen drives per-icon springs toward the pure
/// `DockMagnification.magnificationFactor` target, so the wave moves
/// at the display's refresh and settles without a timer running.
///
/// The view feeds it three things: the ordered item ids, the base
/// geometry (`iconSize`, `spacing`), and the pointer's position along
/// the dock axis in row coordinates (`nil` when the pointer is off the
/// bar). It publishes `scales` — the multiplier each tile renders at —
/// plus `scaleList` (the same values parallel to `itemIDs`) for the
/// panel's width math.
@MainActor
@Observable
final class DockMagnifier {
    /// Rendered scale per item id; absent means 1. Read by the view.
    private(set) var scales: [String: Double] = [:]
    /// Ordered ids — the model's item order, pushed in by the view.
    var itemIDs: [String] = [] {
        didSet {
            var keep: [String: Double] = [:]
            var keepV: [String: Double] = [:]
            for id in itemIDs {
                keep[id] = scales[id]
                keepV[id] = velocities[id]
            }
            scales = keep.compactMapValues { $0 }
            velocities = keepV.compactMapValues { $0 }
            refreshLink()
        }
    }

    /// The settings read, wired by the panel from `DockSettings`.
    var magnification: @MainActor () -> DockMagnification = { DockMagnification() }
    /// The scales moved — the panel re-anchors so the bar stays
    /// centred on its edge as the wave widens the row.
    var onScalesChanged: (@MainActor () -> Void)?

    /// Base icon edge and inter-icon spacing, in points — pushed by
    /// the view so centres are computed in the same space the pointer
    /// position arrives in.
    var iconSize: Double = DockSettings.defaultIconSize
    var spacing: Double = DockView.spacing
    /// Extra row width inserted *before* an item id — the separators
    /// the view draws between groups. Without it the wave's centre map
    /// drifts right of the real icons past a divider.
    var extraBefore: [String: Double] = [:]

    @ObservationIgnored private var velocities: [String: Double] = [:]
    @ObservationIgnored private var pointer: Double?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private weak var screen: NSScreen?
    @ObservationIgnored private let box = DockTickBox()

    /// Spring constants: just under critically damped, so the wave
    /// overtakes the pointer a touch instead of lagging dead behind it.
    static let stiffness: Double = 320
    static let damping: Double = 30

    init() {
        box.onTick = { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The display the link rides; called when the panel orders in.
    func attach(to screen: NSScreen?) {
        self.screen = screen
    }

    /// The view's hover report: pointer position along the dock axis,
    /// or nil off the bar. Either way the link runs until the springs
    /// settle — a wave has to relax back, not snap.
    func notePointer(_ position: Double?) {
        pointer = position
        refreshLink()
    }

    /// `scaleList` — `scales` parallel to `itemIDs` — for width math.
    var scaleList: [Double] { itemIDs.map { scales[$0] ?? 1 } }

    /// The row's rendered length: scaled icons plus spacing — the same
    /// formula the panel uses, kept here so the view and the frame can
    /// never disagree.
    func rowLength(padding: Double) -> Double {
        let list = scaleList
        let icons = list.reduce(0) { $0 + iconSize * $1 }
        // `extraBefore` values already carry the separator's width AND
        // the gap around it — the row's own children+spacing count.
        return icons + spacing * Double(max(0, list.count - 1))
            + extraBefore.values.reduce(0, +) + padding * 2
    }

    /// Centres under the *current* scales — the wave's own positions,
    /// which is what makes the wave travel smoothly instead of chasing
    /// a fixed lattice. Separator gaps count toward the cursor, the
    /// same air the row gives them.
    func currentCenters() -> [Double] {
        var centers: [Double] = []
        var cursor = 0.0
        for (index, id) in itemIDs.enumerated() {
            if index > 0 { cursor += extraBefore[id] ?? 0 }
            let width = iconSize * (scales[id] ?? 1)
            centers.append(cursor + width / 2)
            cursor += width + spacing
        }
        return centers
    }

    /// Nothing runs while the bar is flat and unpointed-at — the link
    /// exists only to move pixels (the FoldToy rule).
    private func refreshLink() {
        let settled = pointer == nil && scales.values.allSatisfy { $0 < 1.001 }
        if settled {
            link?.invalidate()
            link = nil
            if !scales.isEmpty {
                scales = [:]
                velocities = [:]
                onScalesChanged?()
            }
            return
        }
        guard link == nil else { return }
        let link = (screen ?? NSScreen.main)?.displayLink(target: box, selector: #selector(DockTickBox.tick))
        link?.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
        tick()
    }

    /// One heartbeat: retarget each spring from the pointer's distance
    /// to each icon's current centre, integrate, publish.
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 20.0, max(0.0005, now - lastTick))
        lastTick = now

        let mag = magnification()
        let active = pointer != nil && mag.enabled && mag.scale > 1
        let centers = currentCenters()

        var next: [String: Double] = [:]
        var allFlat = true
        for (index, id) in itemIDs.enumerated() {
            let target: Double
            if active, let pointer, index < centers.count {
                target = DockMagnification.magnificationFactor(
                    distance: centers[index] - pointer, scale: mag.scale, reach: mag.reach)
            } else {
                target = 1
            }
            let x = scales[id] ?? 1
            let v = velocities[id] ?? 0
            // Semi-implicit Euler — stable at any refresh rate.
            let accel = (target - x) * Self.stiffness - v * Self.damping
            let v2 = v + accel * dt
            let x2 = x + v2 * dt
            if abs(x2 - 1) > 0.0015 || abs(v2) > 0.002 {
                next[id] = x2
                velocities[id] = v2
                allFlat = false
            } else {
                next[id] = 1
                velocities[id] = 0
            }
        }
        scales = next
        onScalesChanged?()

        if pointer == nil && allFlat {
            link?.invalidate()
            link = nil
            scales = [:]
            velocities = [:]
            onScalesChanged?()
        }
    }

    func detach() {
        link?.invalidate()
        link = nil
        pointer = nil
        scales = [:]
        velocities = [:]
    }

    isolated deinit {
        link?.invalidate()
    }
}

/// The display link's target — `CADisplayLink` needs an NSObject with
/// an `@objc` selector, so the tick rides inside a closure (same shape
/// as Fold's `TickBox`).
private final class DockTickBox: NSObject {
    var onTick: () -> Void = {}
    @objc func tick() { onTick() }
}
