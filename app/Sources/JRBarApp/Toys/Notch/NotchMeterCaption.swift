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

    enum Kind: Hashable {
        case runOut, reset, other(String)
    }

    var kind: Kind {
        if tone == .attention, text?.hasPrefix("Runs out ") == true { return .runOut }
        if text?.hasPrefix("resets in ") == true { return .reset }
        return .other(text ?? "")
    }

    var forms: [String] {
        guard let text else { return [] }
        let candidates: [String]
        if tone == .attention, text.hasPrefix("Runs out in ") {
            let duration = String(text.dropFirst("Runs out in ".count))
            candidates = [text, text, "Out in \(duration)", "Out \(duration)"]
        } else if tone == .attention, text.hasPrefix("Runs out ") {
            let clock = String(text.dropFirst("Runs out ".count))
            let shortClock = dayPeriods.reduce(clock) { $0.replacingOccurrences(of: $1, with: "") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidates = [text, "Runs out \(shortClock)", "Out \(shortClock)", "Out \(shortClock)"]
        } else if text.hasPrefix("resets in ") {
            candidates = [text, String(text.dropFirst("resets in ".count))]
        } else if resetIsFix {
            candidates = [text, "Fix source", "Fix"]
        } else if text == "reset — waiting for a new reading" {
            candidates = [text, "Awaiting reading", "Waiting"]
        } else {
            candidates = [text]
        }
        // Keep wording aligned across clocks and durations, even when two forms match.
        return candidates
    }

    func color(fallback: Color) -> Color {
        switch tone {
        case .secondary: fallback
        case .attention: Tone.warning.color
        case .failure: Tone.failure.color
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

struct NotchMeterCaptionFit: Equatable {
    var kind: NotchMeterCaption.Kind
    var available: CGFloat?
    var widths: [Int: CGFloat] = [:]

    var fittingForm: Int {
        let ordered = widths.keys.sorted()
        return ordered.first { widths[$0]! <= (available ?? 0) } ?? ordered.last ?? 0
    }
}

struct NotchMeterCaptionFitEvidence: PreferenceKey {
    static let defaultValue: [String: NotchMeterCaptionFit] = [:]
    static func reduce(value: inout [String: NotchMeterCaptionFit],
                       nextValue: () -> [String: NotchMeterCaptionFit]) {
        value.merge(nextValue()) { old, new in
            NotchMeterCaptionFit(kind: new.kind, available: new.available ?? old.available,
                widths: old.widths.merging(new.widths, uniquingKeysWith: { _, new in new }))
        }
    }
}

/// Full-text placeholders keep row widths stable when the shared form changes.
/// Preferences change only with text or available width, never reveal opacity.
struct NotchUniformMeterRows<Content: View>: View {
    var meters: [NotchIslandMeter]
    @ViewBuilder var content: (Int, NotchIslandMeter, Int) -> Content
    @ViewState private var forms: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                content(index, meter, forms[meter.id] ?? 0)
            }
        }
        .onPreferenceChange(NotchMeterCaptionFitEvidence.self) { measurements in
            var shared: [NotchMeterCaption.Kind: Int] = [:]
            for measurement in measurements.values {
                shared[measurement.kind] = max(shared[measurement.kind] ?? 0, measurement.fittingForm)
            }
            let selected = measurements.mapValues { shared[$0.kind] ?? 0 }
            if forms != selected { forms = selected }
        }
    }
}
