import AppKit
import JRBarCore
import SwiftUI

/// How a provider looks everywhere in the app: its name, the accent the
/// Python app assigns it today (`sidepulse.colors.default_agent_color`),
/// and a small glyph.
struct ProviderStyle: Hashable, Sendable {
    enum Glyph: Hashable, Sendable {
        case symbol(String)
        /// One or two characters drawn in the accent, for logos SF Symbols cannot approximate.
        case text(String)
    }

    let id: String
    let name: String
    let accentHex: String
    let glyph: Glyph

    var accent: Color { Color(nsColor: nsAccent) }

    var nsAccent: NSColor { NSColor(hex: accentHex) ?? .secondaryLabelColor }

    /// Accent colours from `src/sidepulse/colors.py` (brand table plus the
    /// pinned palette slots), captured 2026-09-09.
    static let table: [String: ProviderStyle] = Dictionary(uniqueKeysWithValues: [
        ProviderStyle(id: "claude", name: "Claude", accentHex: "#D97757", glyph: .symbol("asterisk")),
        ProviderStyle(id: "codex", name: "Codex", accentHex: "#2B8FFF", glyph: .symbol("chevron.left.forwardslash.chevron.right")),
        ProviderStyle(id: "gemini", name: "Gemini", accentHex: "#34C759", glyph: .symbol("sparkle")),
        ProviderStyle(id: "pi", name: "Pi", accentHex: "#007AFF", glyph: .text("π")),
        ProviderStyle(id: "grok", name: "Grok", accentHex: "#636366", glyph: .symbol("bolt.fill")),
        ProviderStyle(id: "devin", name: "Devin", accentHex: "#5C84B0", glyph: .symbol("hammer.fill")),
        ProviderStyle(id: "opencode", name: "OpenCode", accentHex: "#AF52DE", glyph: .symbol("terminal.fill")),
        ProviderStyle(id: "openclaw", name: "OpenClaw", accentHex: "#B23400", glyph: .symbol("pawprint.fill")),
        ProviderStyle(id: "antigravity", name: "Antigravity", accentHex: "#ABE17E", glyph: .symbol("arrow.up.to.line")),
        ProviderStyle(id: "cursor", name: "Cursor", accentHex: "#FFCC00", glyph: .symbol("cursorarrow")),
        ProviderStyle(id: "hermes", name: "Hermes Agent", accentHex: "#FF9500", glyph: .symbol("paperplane.fill")),
        ProviderStyle(id: "kiro", name: "Kiro", accentHex: "#A00848", glyph: .text("K")),
        // A usage source rather than an agent: the daemon reports it in
        // `state.usage.providers` (`provider_usage_cli.py`), so the Usage
        // Center needs a name for it that is not "Openai-api".
        ProviderStyle(id: "openai-api", name: "OpenAI API", accentHex: "#10A37F", glyph: .symbol("key.horizontal.fill")),
    ].map { ($0.id, $0) })

    static func style(for provider: String) -> ProviderStyle {
        let key = provider.lowercased()
        if let known = table[key] { return known }
        // Unknown providers get a neutral tile and a readable name, never a blank.
        let name = key.isEmpty ? "Agent" : key.prefix(1).uppercased() + key.dropFirst()
        return ProviderStyle(id: key, name: name, accentHex: "#8E8E93", glyph: .symbol("questionmark"))
    }

    /// The default style with a configured `colors.agent_colors.<id>`
    /// applied over `accentHex` when the stored hex validates; the
    /// default unchanged when it does not.
    static func style(for provider: String, document: SettingsDocument?) -> ProviderStyle {
        let style = style(for: provider)
        guard let hex = document?.agentColorHex(provider) else { return style }
        return ProviderStyle(id: style.id, name: style.name, accentHex: hex, glyph: style.glyph)
    }

}

/// What colour a state is, everywhere in the app. One place, because the
/// alternative is what shipped: `Color.orange` and `Color.red` written out
/// at each call site, some rows colouring a failure and some not, and the
/// hardware meanwhile painting failures in the Ask colour.
///
/// These are the system's semantic colours rather than the hardware hexes
/// (`colors.MODE_*`) on purpose -- a menu is not a strip and should follow
/// the user's accent and contrast settings -- but the vocabulary is the
/// same one, and the split that matters is the same split: waiting is
/// amber, failed is red, and they are never each other.
extension SessionActivity {
    var tint: Color {
        switch self {
        case .working: return .accentColor
        case .waiting: return .orange
        case .done: return .green
        case .failed: return .red
        case .ended, .idle: return .secondary
        }
    }

    /// Whether the state word is worth shouting. Waiting shouts because it
    /// is costing you time; failed shouts because it is over and you do not
    /// know it. Everything else is quiet.
    var wordIsLoud: Bool { self == .waiting || self == .failed }

    /// The colour the state WORD takes in a row.
    var wordColor: Color {
        if wordIsLoud { return tint }
        return self == .ended ? Color.secondary.opacity(0.65) : .secondary
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                  green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(value & 0xFF) / 255.0,
                  alpha: 1)
    }
}
