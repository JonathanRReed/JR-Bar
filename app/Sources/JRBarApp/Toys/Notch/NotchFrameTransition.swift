import Foundation
import JRBarCore
import JRBarUI

/// An interrupted move starts at the frame already on screen and lands without overshoot.
struct NotchFrameTransition: Equatable {
    private(set) var frame: CGRect
    private(set) var target: CGRect
    private var origin: CGRect
    private var elapsed = 0.0
    private(set) var token: JRBarTokens.Motion = .notchSettle
    // Stage sizing still accepts a spring descriptor. Critical damping reserves no bounce.
    private(set) var motion = NotchFrameSpring.Motion(response: JRBarTokens.Motion.notchSettle.duration, dampingFraction: 1)

    init(at frame: CGRect) {
        self.frame = frame
        target = frame
        origin = frame
    }

    mutating func retarget(_ target: CGRect) {
        origin = frame
        self.target = target
        elapsed = 0
        let width = target.width - frame.width
        let height = target.height - frame.height
        let grows = abs(height) >= abs(width) ? height > 0 : width > 0
        token = grows ? .notchSettle : .notchClose
        motion = NotchFrameSpring.Motion(response: token.duration, dampingFraction: 1)
    }

    @discardableResult
    mutating func integrate(dt: TimeInterval) -> Bool {
        guard dt.isFinite, dt > 0 else { return frame != target }
        elapsed += dt
        let progress = token.progress(at: elapsed)
        func mix(_ first: CGFloat, _ last: CGFloat) -> CGFloat { first + (last - first) * progress }
        frame = CGRect(x: mix(origin.minX, target.minX), y: mix(origin.minY, target.minY),
                       width: mix(origin.width, target.width), height: mix(origin.height, target.height))
        return elapsed < token.duration && origin != target
    }
}
