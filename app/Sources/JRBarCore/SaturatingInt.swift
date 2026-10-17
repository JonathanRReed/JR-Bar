import Foundation

extension Int {
    /// A whole number from a daemon-supplied double that cannot trap. `Int(_:)`
    /// crashes the app for NaN, infinity and anything past the range of an
    /// integer, and a quota figure or a timestamp comes from a file somebody
    /// can edit. Out-of-range values stop at a quadrillion (far past any
    /// count of seconds or tokens this app prints) and NaN reads as zero.
    public init(saturating value: Double) {
        let limit = 1_000_000_000_000_000.0
        if value.isNaN {
            self = 0
        } else if value >= limit {
            self = Int(limit)
        } else if value <= -limit {
            self = -Int(limit)
        } else {
            self = Int(value)
        }
    }
}
