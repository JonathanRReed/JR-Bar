import Foundation
import JRBarCore
import JRBarUI
import SwiftUI

struct NotchMeterCaption {
    let reading: UsageGaugeReading?
    let reset: String?

    init(meter: NotchIslandMeter, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) {
        reset = PanelStore.countdown(to: meter.resetsAt, now: now, fix: meter.fix)
        if let provider = meter.usage, let window = provider.headlineWindow {
            reading = UsageGaugeReading(window: window, provider: provider, now: now.timeIntervalSince1970,
                locale: locale, timeZone: timeZone, forecast: meter.forecast, abbreviatesMinutes: true)
        } else {
            reading = nil
        }
    }

    var tone: UsageGaugeReading.CaptionTone { reading?.captionTone ?? .secondary }
    var text: String? { tone == .secondary ? reset : reading?.footnote }
    var help: String { tone == .secondary ? "" : [text, reset].compactMap { $0 }.joined(separator: ". ") }
    var forecast: UsageForecast? { reading?.forecast }

    func color(fallback: Color) -> Color {
        switch tone {
        case .secondary: fallback
        case .attention: JRBarTokens.Ink.attention
        case .failure: JRBarTokens.Ink.failure
        }
    }
}

struct NotchMeterCaptionEvidence: PreferenceKey {
    static let defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
