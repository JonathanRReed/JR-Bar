import Foundation
import JRBarCore
import JRBarUI
import SwiftUI

struct NotchMeterCaption {
    let reading: UsageGaugeReading?
    let reset: String?
    private let dayPeriods: [String]
    private let resetIsFix: Bool

    init(meter: NotchIslandMeter, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) {
        reset = PanelStore.countdown(to: meter.resetsAt, now: now, fix: meter.fix)
        resetIsFix = meter.fix != nil && reset == meter.fix
        let formatter = DateFormatter()
        formatter.locale = locale
        dayPeriods = [formatter.amSymbol, formatter.pmSymbol].filter { !$0.isEmpty }
        if let provider = meter.usage, let window = provider.headlineWindow {
            reading = UsageGaugeReading(window: window, provider: provider, now: now.timeIntervalSince1970,
                locale: locale, timeZone: timeZone, forecast: meter.forecast, abbreviatesMinutes: true)
        } else {
            reading = nil
        }
    }

    var tone: UsageGaugeReading.CaptionTone { reading?.captionTone ?? .secondary }
    var text: String? { tone == .secondary ? reset : reading?.footnote }
    var help: String { tone == .secondary ? text ?? "" : [text, reset].compactMap { $0 }.joined(separator: ". ") }
    var forecast: UsageForecast? { reading?.forecast }

    var forms: [String] {
        guard let text else { return [] }
        let candidates: [String]
        if tone == .attention, text.hasPrefix("Runs out in ") {
            let duration = String(text.dropFirst("Runs out in ".count))
            candidates = [text, "Out in \(duration)", "Out \(duration)"]
        } else if tone == .attention, text.hasPrefix("Runs out ") {
            let clock = String(text.dropFirst("Runs out ".count))
            let shortClock = dayPeriods.reduce(clock) { $0.replacingOccurrences(of: $1, with: "") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidates = [text, "Runs out \(shortClock)", "Out \(shortClock)"]
        } else if text.hasPrefix("resets in ") {
            candidates = [text, String(text.dropFirst("resets in ".count))]
        } else if resetIsFix {
            candidates = [text, "Fix source", "Fix"]
        } else if text == "reset — waiting for a new reading" {
            candidates = [text, "Awaiting reading", "Waiting"]
        } else {
            candidates = [text]
        }
        return candidates.reduce(into: []) { forms, candidate in
            if !forms.contains(candidate) { forms.append(candidate) }
        }
    }

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

struct NotchMeterCaptionWidthEvidence: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct NotchMeterCaptionFontEvidence: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
