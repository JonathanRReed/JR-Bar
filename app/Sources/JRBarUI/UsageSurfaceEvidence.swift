import JRBarCore
import SwiftUI

/// Rendered usage models let tests catch a view that drops a forecast component.
public struct UsageGaugeEvidence: PreferenceKey {
    public static let defaultValue: [String: UsageGaugeReading] = [:]
    public static func reduce(value: inout [String: UsageGaugeReading], nextValue: () -> [String: UsageGaugeReading]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

public struct UsageForecastEvidence: PreferenceKey {
    public static let defaultValue: [String: UsageForecast] = [:]
    public static func reduce(value: inout [String: UsageForecast], nextValue: () -> [String: UsageForecast]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}
