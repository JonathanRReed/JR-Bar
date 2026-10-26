import AppKit
import SwiftUI

/// Fixed provider defaults. Studio overrides belong to the daemon's
/// `colors.agent_colors`; callers can pass that colour to the shared views.
public enum ProviderPalette {
    public static let hexes: [String: String] = [
        "claude": "#D97757", "codex": "#2B8FFF", "gemini": "#34C759",
        "antigravity": "#ABE17E", "cursor": "#FFCC00", "factory": "#E76F32",
        "devin": "#5C84B0", "opencode": "#AF52DE", "kiro": "#A00848",
        "grok": "#8E8E93", "openclaw": "#B23400", "pi": "#007AFF",
        "hermes": "#FF9500", "kimi": "#3178D4", "kilo": "#C27C00",
        "openai-api": "#10A37F", "jrbar": "#5E5CE6", "t3code": "#00B8D9",
    ]

    public static func hex(for provider: String) -> String { hexes[provider.lowercased()] ?? "#8E8E93" }

    public static func color(for provider: String) -> Color { Color(nsColor: nsColor(for: provider)) }

    public static func nsColor(for provider: String) -> NSColor {
        let value = UInt32(hex(for: provider).dropFirst(), radix: 16) ?? 0x8E8E93
        return nsColor(hex: value)
    }

    static func nsColor(hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    public static func logoID(for provider: String) -> String {
        switch provider.lowercased() {
        case "codex", "openai-api": "openai"
        default: provider.lowercased()
        }
    }
}
