import AppKit
import SwiftUI

// Match the app's property wrapper while the SDK also exposes a State macro.
typealias UIState<Value> = SwiftUICore.State<Value>

/// The approved 0.10.0 type, colour, spacing and motion vocabulary.
public enum JRBarTokens {
    public enum TypeStyle: CaseIterable, Sendable {
        case title, title1, heading, title3, headline, body, callout, caption, section

        public var size: CGFloat {
            switch self {
            case .title: 26
            case .title1: 22
            case .heading: 17
            case .title3: 15
            case .headline: 13
            case .section: 11
            case .body: 13
            case .callout: 12
            case .caption: 11
            }
        }

        public var lineHeight: CGFloat {
            switch self {
            case .title: 32
            case .title1: 28
            case .heading: 22
            case .title3: 20
            case .headline: 18
            case .section: 14
            case .body: 18
            case .callout: 16
            case .caption: 14
            }
        }

        var nsWeight: NSFont.Weight {
            switch self {
            case .title, .title1: .bold
            case .heading, .title3, .headline, .section: .semibold
            default: .regular
            }
        }

        var extraLeading: CGFloat {
            let font = NSFont.systemFont(ofSize: size, weight: nsWeight)
            return max(0, lineHeight - ceil(font.ascender - font.descender + font.leading))
        }

        public var font: Font {
            let weight = nsWeight == .bold ? Font.Weight.bold : nsWeight == .semibold ? .semibold : .regular
            return .system(size: size, weight: weight) // jrbar-token-exception: token definition
        }
    }

    public enum Radius {
        public static let swatch: CGFloat = 4
        public static let tile: CGFloat = 6
        public static let control: CGFloat = 8
        public static let group: CGFloat = 12
        public static let panel: CGFloat = 16
        public static let window: CGFloat = 18
        public static var pill: Capsule { Capsule() }
        public static func providerTile(size: CGFloat) -> CGFloat { size == 16 ? 5 : (size * 0.28).rounded() }
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    public enum Motion: CaseIterable, Sendable {
        case quick, panelEntrance, rowChange, notchSettle, notchClose, reduced

        public var duration: Double {
            switch self {
            case .quick: 0.100
            case .panelEntrance: 0.140
            case .rowChange: 0.160
            case .notchSettle: 0.250
            case .notchClose: 0.180
            case .reduced: 0.080
            }
        }

        public func animation(reduceMotion: Bool) -> Animation {
            reduceMotion ? Self.reduced.animation : animation
        }

        /// Use for layout transitions so Reduce Motion never scales or resizes content.
        public static func transition(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
        }

        private var controlPoints: (Double, Double, Double, Double) {
            if self == .reduced { return (0, 0, 1, 1) }
            if self == .quick || self == .notchClose { return (0.4, 0, 1, 1) }
            if self == .notchSettle { return (0.45, 0, 0.25, 1) }
            return (0.2, 0.8, 0.2, 1)
        }

        public var animation: Animation {
            let points = controlPoints
            return .timingCurve(points.0, points.1, points.2, points.3, duration: duration)
        }

        /// Native windows use the same curve as SwiftUI, with an exact end time.
        public func progress(at elapsed: Double) -> Double {
            let fraction = min(1, max(0, elapsed / duration))
            if fraction == 0 || fraction == 1 { return fraction }
            let points = controlPoints
            func cubic(_ time: Double, _ first: Double, _ second: Double) -> Double {
                let rest = 1 - time
                return 3 * rest * rest * time * first + 3 * rest * time * time * second + time * time * time
            }
            var low = 0.0, high = 1.0
            for _ in 0..<32 {
                let middle = (low + high) / 2
                if cubic(middle, points.0, points.2) < fraction { low = middle } else { high = middle }
            }
            return cubic((low + high) / 2, points.1, points.3)
        }

    }

    public enum Ink {
        public static let accent = Color.accentColor
        public static let label = Palette().label
        public static let secondary = Palette().secondary
        public static let tertiary = Palette().tertiary
        public static let separator = Palette().separator
        public static let strongSeparator = Palette().strongSeparator
        public static let fill = Palette().fill
        public static let secondaryFill = Palette().secondaryFill
        public static let tertiaryFill = Palette().tertiaryFill
        public static let stale = Palette().stale
        public static let quaternary = Palette().quaternary
        public static let hover = Palette().hover
        public static let group = Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: 1, alpha: dark ? 0.055 : 0.90)
        })
        public static let groupEdge = Palette().groupEdge
        public static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.22 : 0.12)
        })
        public static let working = adaptive(light: 0x007AFF, dark: 0x0A84FF)
        public static let grok = adaptive(light: 0x1C1C1E, dark: 0xF2F2F2)
        public static let grokOnBlack = adaptive(light: 0xF2F2F2, dark: 0xF2F2F2)
        public static let live = adaptive(light: 0x30B0C7, dark: 0x40C8E0)
        public static let done = adaptive(light: 0x28A745, dark: 0x30D158)
        public static let attention = adaptive(light: 0xFF9500, dark: 0xFF9F0A)
        public static let failure = adaptive(light: 0xE5352B, dark: 0xFF453A)
        public static let reset = adaptive(light: 0x5E5CE6, dark: 0x7D7AFF)
        public static let content = adaptive(light: 0xFFFFFF, dark: 0x232325)
        public static let window = adaptive(light: 0xF3F3F5, dark: 0x1E1E20)

        struct Palette: Sendable {
            var increased = false
            var label: Color { neutral(light: 0.86, dark: 0.90, increasedContrast: increased) }
            var secondary: Color { neutral(light: 0.56, dark: 0.60, increasedContrast: increased) }
            var tertiary: Color { neutral(light: 0.32, dark: 0.36, increasedContrast: increased) }
            var separator: Color { neutral(light: 0.10, dark: 0.10, increasedContrast: increased) }
            var strongSeparator: Color { neutral(light: 0.16, dark: 0.16, increasedContrast: increased) }
            var fill: Color { neutral(light: 0.045, dark: 0.06, increasedContrast: increased) }
            var secondaryFill: Color { neutral(light: 0.075, dark: 0.10, increasedContrast: increased) }
            var tertiaryFill: Color { neutral(light: 0.11, dark: 0.15, increasedContrast: increased) }
            var stale: Color { neutral(light: 0.56, dark: 0.52, increasedContrast: increased) }
            var quaternary: Color { neutral(light: 0.18, dark: 0.20, increasedContrast: increased) }
            var hover: Color { neutral(light: 0.05, dark: 0.07, increasedContrast: increased) }
            var groupEdge: Color { neutral(light: 0.08, dark: 0.07, increasedContrast: increased) }
        }

        private static func neutral(light: CGFloat, dark: CGFloat, increasedContrast: Bool = false) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let increased = increasedContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                    || [NSAppearance.Name.accessibilityHighContrastAqua,
                                 .accessibilityHighContrastDarkAqua,
                                 .accessibilityHighContrastVibrantLight,
                                 .accessibilityHighContrastVibrantDark].contains(appearance.name)
                let opacity = isDark ? dark : light
                return NSColor(white: isDark ? 1 : 0, alpha: increased ? min(1, opacity * 1.35) : opacity)
            })
        }

        private static func adaptive(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return ProviderPalette.nsColor(hex: isDark ? dark : light)
            })
        }
    }
}

private struct TokenType: ViewModifier {
    @Environment(\.jrbarInk) private var ink
    let style: JRBarTokens.TypeStyle

    func body(content: Content) -> some View {
        content.font(style.font)
            .lineSpacing(style.extraLeading)
            .padding(.vertical, style.extraLeading / 2)
            .foregroundStyle(style == .section ? ink.secondary : ink.label)
    }
}

public extension View {
    /// Apply the approved font and leading, including wrapped lines.
    func jrbarType(_ style: JRBarTokens.TypeStyle) -> some View {
        modifier(TokenType(style: style))
    }
}
