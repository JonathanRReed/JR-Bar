import JRBarLEDS
import SwiftUI

/// Parsed programs for the previews, keyed by text and LED count, so a view
/// that re-renders thirty times a second never re-parses.
@MainActor
enum LEDPreviewSamplers {
    private static var cache: [String: LEDSSampler] = [:]
    private static var order: [String] = []
    private static let limit = 96

    static func sampler(for program: String, ledCount: Int) -> LEDSSampler? {
        let key = "\(ledCount)|\(program)"
        if let hit = cache[key] { return hit }
        // Everything shown goes through the presentation-safety compiler,
        // exactly like the Screen Bar: a 3 Hz strobe never reaches the preview.
        guard let (parsed, _) = LEDSPresentationCompiler.compileProgram(program, ledCount: ledCount) else { return nil }
        let sampler = LEDSSampler(program: parsed, ledCount: ledCount)
        cache[key] = sampler
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        return sampler
    }
}

/// A live rendering of a LEDS program: a row of glowing dots (the strip)
/// or one blended band (the Screen Bar). Driven by a 30 Hz timeline that
/// pauses for static programs and under Reduce Motion, where the frame
/// shown is the program's brightest moment instead of a black start.
struct LEDStripPreview: View {
    enum Style { case dots, band }

    let program: String
    var ledCount: Int = 8
    var style: Style = .dots
    var dotSize: CGFloat = 14
    var spacing: CGFloat = 8
    /// Finite programs start over after they end (plus a short rest).
    var loops: Bool = true
    var paused: Bool = false
    var showsBackground: Bool = true
    var cornerRadius: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var origin = Date()

    private var sampler: LEDSSampler? { LEDPreviewSamplers.sampler(for: program, ledCount: ledCount) }

    var body: some View {
        let sampler = self.sampler
        let still = paused || reduceMotion || (sampler?.isStatic ?? true)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { context in
            let colors = colors(sampler: sampler, at: context.date, still: reduceMotion)
            frame(colors)
        }
        .onChange(of: program) { _, _ in origin = Date() }
        .accessibilityLabel(sampler == nil ? "Program refused" : "LED preview")
    }

    private func colors(sampler: LEDSSampler?, at date: Date, still: Bool) -> [RGB] {
        guard let sampler else { return Array(repeating: RGB(r: 0.35, g: 0.05, b: 0.05), count: ledCount) }
        var t = date.timeIntervalSince(origin)
        if still {
            // The brightest instant of the first cycle, so a breathe is not shown at its floor.
            let span = sampler.cycleDuration ?? sampler.motionEndsAt ?? 0
            if span > 0 {
                var best = 0.0, bestLevel = -1.0
                for k in 0..<12 {
                    let probe = span * Double(k) / 12
                    let level = sampler.colors(at: probe).map(\.maxChannel).reduce(0, +)
                    if level > bestLevel { bestLevel = level; best = probe }
                }
                t = best
            } else {
                t = 0
            }
        } else if loops, sampler.cycleDuration == nil, let ends = sampler.motionEndsAt, ends > 0 {
            t = t.truncatingRemainder(dividingBy: ends + 0.8)
        }
        return sampler.colors(at: t)
    }

    @ViewBuilder
    private func frame(_ colors: [RGB]) -> some View {
        switch style {
        case .dots:
            HStack(spacing: spacing) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, rgb in
                    let color = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                        .shadow(color: color.opacity(0.75 * rgb.maxChannel), radius: dotSize * 0.45)
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .padding(.horizontal, showsBackground ? dotSize * 0.9 : 0)
            .padding(.vertical, showsBackground ? dotSize * 0.7 : 0)
            .frame(maxWidth: showsBackground ? .infinity : nil)
            .background {
                if showsBackground {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black.opacity(0.86))
                }
            }
        case .band:
            let stops = colors.enumerated().map { index, rgb in
                Gradient.Stop(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b), location: colors.count > 1 ? CGFloat(index) / CGFloat(colors.count - 1) : 0.5)
            }
            let glow = colors.map(\.maxChannel).max() ?? 0
            Capsule()
                .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color(red: colors[colors.count / 2].r, green: colors[colors.count / 2].g, blue: colors[colors.count / 2].b).opacity(0.6 * glow), radius: dotSize * 0.4)
                .frame(height: dotSize)
                .padding(showsBackground ? dotSize * 0.6 : 0)
                .background {
                    if showsBackground {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black.opacity(0.86))
                    }
                }
        }
    }
}

/// Builds the small programs the Lighting page previews: a provider's
/// working animation under the chosen blend mode and cycle speed, and the
/// done celebration in a colour. Kept local so the page needs no daemon
/// round trip; the daemon's own compiler is the authority for the strip.
enum LightingPreviewPrograms {
    static func working(colorHex: String, blendMode: String, cycleSeconds: Double, ledCount: Int = 8) -> String {
        let hex = normalized(colorHex)
        let ms = max(300, Int(cycleSeconds * 1000))
        let floor = scaled(hex, 0.10)
        let n = max(2, ledCount)
        switch blendMode {
        case "relay":
            // Spotlight: one agent flares along the strip.
            let step = max(40, ms / n)
            let segments = (0..<n).map { "\($0):\(hex) \(ms)ms pulse \($0 * step)ms" }.joined(separator: "; ")
            return "\(floor)\n\(segments)\nrepeat"
        case "spatial_split":
            // Split: this agent owns the left half, breathing.
            let mine = (0..<(n / 2)).map { "\($0):\(hex) \(ms)ms pulse 0ms" }.joined(separator: "; ")
            let rest = (n / 2..<n).map { "\($0):\(scaled(hex, 0.18))" }.joined(separator: "; ")
            return "\(rest)\n\(mine)\nrepeat"
        case "color_blend":
            // Smooth: a gradient of the colour rolling by.
            let shades = (0..<n).map { i in mixed(hex, scaled(hex, 0.25), Double(i) / Double(n - 1)) }.joined(separator: " ")
            return "\(shades)\nroll \(max(600, ms * 2))ms linear\nrepeat"
        case "cycle":
            // One at a time: the whole strip is this agent, then hands over.
            return "\(hex) \(ms / 2)ms cosine\n\(hex) \(ms)ms none\n\(scaled(hex, 0.05)) \(ms / 2)ms cosine\n\(scaled(hex, 0.05)) \(ms)ms none\nrepeat"
        case "classic":
            // Status only: a steady colour.
            return hex
        default:
            // Everyone: a swell, every LED together.
            return "\(floor)\n\(hex) \(ms)ms pulse\nrepeat"
        }
    }

    /// The celebration: a fast ripple, a bloom, a hold, then off (the
    /// reference program in Tests/JRBarLEDSTests/Fixtures/programs).
    static func celebration(colorHex: String = "#00FF66", ledCount: Int = 8) -> String {
        let hex = normalized(colorHex)
        let n = max(2, ledCount)
        let ripple = (0..<n).map { "\($0):\(hex) 70ms none \($0 * 45)ms" }.joined(separator: "; ")
        return "off 90ms cosine\n\(ripple)\noff 70ms none\n\(hex) 280ms cosine\n\(mixed(hex, "#FFFFFF", 0.18)) 240ms cosine\n\(hex) 200ms cosine\n\(hex) 1400ms none\noff 900ms cosine"
    }

    static func normalized(_ hex: String) -> String {
        RGB8(hex: hex)?.hex ?? "#8E8E93"
    }

    static func scaled(_ hex: String, _ factor: Double) -> String {
        guard let rgb = RGB8(hex: hex) else { return hex }
        return RGB8(r: UInt8(Double(rgb.r) * factor), g: UInt8(Double(rgb.g) * factor), b: UInt8(Double(rgb.b) * factor)).hex
    }

    static func mixed(_ a: String, _ b: String, _ t: Double) -> String {
        guard let x = RGB8(hex: a), let y = RGB8(hex: b) else { return a }
        func lerp(_ p: UInt8, _ q: UInt8) -> UInt8 { UInt8(max(0, min(255, Double(p) + (Double(q) - Double(p)) * t))) }
        return RGB8(r: lerp(x.r, y.r), g: lerp(x.g, y.g), b: lerp(x.b, y.b)).hex
    }
}
