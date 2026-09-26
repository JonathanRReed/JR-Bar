import Foundation

/// Presentation only: the renderer and arming machine remain the authorities.
/// A zero displayed angle is not evidence that capture has delivered a frame.
enum FoldReadiness {
    static func detail(tilted: Double, movement: Bool, activationAngle: Double,
                       captureStarted: Bool, hasFrame: Bool, hasTexture: Bool,
                       visible: Bool) -> String {
        if captureStarted && !hasFrame { return "Waiting for a screen frame" }
        guard tilted > 0.1 else {
            return movement ? "Parked — the next move folds from here"
                : "Parked — close the lid past \(Int(activationAngle.rounded()))°"
        }
        if !hasFrame { return "Tilted \(Int(tilted))° — waiting for a screen frame" }
        if !hasTexture { return "Tilted \(Int(tilted))° — frames not reaching the GPU" }
        return visible ? "Holding \(Int(tilted))° of tilt" : "Tilted \(Int(tilted))° — overlay hidden"
    }
}
