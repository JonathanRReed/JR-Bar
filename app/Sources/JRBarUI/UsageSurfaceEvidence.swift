import JRBarCore
import SwiftUI

/// Rendered usage models let tests catch a view that drops a forecast component.
public struct UsageGaugeEvidence: PreferenceKey {
    public static let defaultValue: [String: UsageGaugeReading] = [:]
    public static func reduce(value: inout [String: UsageGaugeReading], nextValue: () -> [String: UsageGaugeReading]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

public enum UsageGaugeCellState: String, Decodable, Sendable {
    case empty, dash, reading
}

/// Column evidence distinguishes a missing window from a missing reading.
public struct UsageGaugeCellEvidence: PreferenceKey {
    public static let defaultValue: [String: UsageGaugeCellState] = [:]
    public static func reduce(value: inout [String: UsageGaugeCellState], nextValue: () -> [String: UsageGaugeCellState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

public struct UsageForecastEvidence: PreferenceKey {
    public static let defaultValue: [String: UsageForecast] = [:]
    public static func reduce(value: inout [String: UsageForecast], nextValue: () -> [String: UsageForecast]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}
