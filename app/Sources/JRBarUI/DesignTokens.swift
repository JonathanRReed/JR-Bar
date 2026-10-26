import AppKit
import SwiftUI

/// The approved 0.10.0 type, colour, spacing and motion vocabulary.
public enum JRBarTokens {
    public enum TypeStyle: CaseIterable, Sendable {
        case title, heading, body, callout, caption

        public var size: CGFloat {
            switch self {
            case .title: 26
            case .heading: 17
            case .body: 13
            case .callout: 12
            case .caption: 11
            }
        }

        public var lineHeight: CGFloat {
            switch self {
            case .title: 32
            case .heading: 22
            case .body: 18
            case .callout: 16
            case .caption: 14
            }
        }

        public var font: Font {
            let weight: Font.Weight = self == .title ? .bold : self == .heading ? .semibold : .regular
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
        case quick, panelEntrance, rowChange, notchSettle

        public var duration: Double {
            switch self {
            case .quick: 0.100
            case .panelEntrance: 0.140
            case .rowChange: 0.160
            case .notchSettle: 0.250
            }
        }

        public var animation: Animation {
            if self == .notchSettle {
                return .timingCurve(0.45, 0, 0.25, 1, duration: duration)
            }
            return .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        }
    }

    public enum Ink {
        public static let accent = Color.accentColor
        public static let label = neutral(light: 0.86, dark: 0.90)
        public static let secondary = neutral(light: 0.56, dark: 0.60)
        public static let tertiary = neutral(light: 0.32, dark: 0.36)
        public static let separator = neutral(light: 0.10, dark: 0.10)
        public static let strongSeparator = neutral(light: 0.16, dark: 0.16)
        public static let fill = neutral(light: 0.045, dark: 0.06)
        public static let secondaryFill = neutral(light: 0.075, dark: 0.10)
        public static let tertiaryFill = neutral(light: 0.11, dark: 0.15)
        public static let stale = neutral(light: 0.50, dark: 0.52)
        public static let live = adaptive(light: 0x30B0C7, dark: 0x40C8E0)
        public static let done = adaptive(light: 0x28A745, dark: 0x30D158)
        public static let attention = adaptive(light: 0xFF9500, dark: 0xFF9F0A)
        public static let failure = adaptive(light: 0xE5352B, dark: 0xFF453A)
        public static let reset = adaptive(light: 0x5E5CE6, dark: 0x7D7AFF)
        public static let content = adaptive(light: 0xFFFFFF, dark: 0x232325)
        public static let window = adaptive(light: 0xF3F3F5, dark: 0x1E1E20)

        private static func neutral(light: CGFloat, dark: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: isDark ? 1 : 0, alpha: isDark ? dark : light)
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
