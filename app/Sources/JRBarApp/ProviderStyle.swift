import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Synchronization

/// How a provider looks everywhere in the app: its name, the accent the
/// Python app assigns it today (`sidepulse.colors.default_agent_color`),
/// and its mark.
struct ProviderStyle: Hashable, Sendable {
    enum Glyph: Hashable, Sendable {
        case symbol(String)
        /// One or two characters drawn in the accent.
        case text(String)
        /// The provider's real mark: a `ProviderLogo` id ("openai" for
        /// Codex, since the mark is what it depicts).
        case logo(String)
    }

    let id: String
    let name: String
    let accentHex: String
    let glyph: Glyph
    /// The glyph the provider wore before it had its mark, drawn only if
    /// the mark ever fails to load (a test keeps that from happening for
    /// every provider in the table).
    var fallback: Glyph = .symbol(ProviderStyle.unknownSymbol)

    /// An unknown provider's symbol, and the fallback of last resort.
    static let unknownSymbol = "questionmark"

    /// What a surface draws for this provider, resolved: the mark itself
    /// when it loads, else the symbol or letters it falls back to.
    enum Mark {
        case logo(ProviderLogo)
        case symbol(String)
        case text(String)
    }

    var mark: Mark {
        switch glyph {
        case .logo(let id):
            if let logo = ProviderLogo.named(id) { return .logo(logo) }
            switch fallback {
            case .symbol(let name): return .symbol(name)
            case .text(let text): return .text(text)
            case .logo: return .symbol(Self.unknownSymbol)
            }
        case .symbol(let name): return .symbol(name)
        case .text(let text): return .text(text)
        }
    }

    var accent: Color { Color(nsColor: nsAccent) }

    var nsAccent: NSColor { NSColor(hex: accentHex) ?? .secondaryLabelColor }

    /// The accent as a mark's ink on `surface`: the accent itself where it
    /// reads, lifted or deepened to 3:1 where it would vanish (Grok's grey
    /// on a dark tile, Cursor's yellow on a light one). The contrast
    /// bisection is a pure function of (accent, surface), so the answer is
    /// kept — the Overview graph asks for it per node per drawn frame.
    func markInk(on surface: ProviderMarkInk.Surface) -> Color {
        let key = "\(accentHex)|\(surface)"
        let color = Self.inkCache.withLock { cache in
            if let hit = cache[key] { return hit }
            let made = ProviderMarkInk.ink(for: nsAccent, on: surface)
            cache[key] = made
            return made
        }
        return Color(nsColor: color)
    }

    private static let inkCache = Mutex<[String: NSColor]>([:])

    /// A tile's ink in the given colour scheme.
    func markInk(dark: Bool) -> Color { markInk(on: dark ? .darkPlate : .lightPlate) }

    /// Accent colours from `src/sidepulse/colors.py` (brand table plus the
    /// pinned palette slots), captured 2026-09-09. Marks from
    /// `ProviderLogoData` (sources in `app/Resources/ProviderLogos`); the
    /// data also carries the Codex app mark (`codex`), xAI's letter mark
    /// (`xai`), the full OpenClaw mascot (`openclaw.molty`) and the rounded
    /// Gemini sparkle (`gemini.lobe`), so a mark below can be swapped for one.
    static let table: [String: ProviderStyle] = Dictionary(uniqueKeysWithValues: [
        ProviderStyle(id: "claude", name: "Claude", accentHex: "#D97757", glyph: .logo("claude"),
                      fallback: .symbol("asterisk")),
        // The OpenAI blossom, the ChatGPT mark people know Codex by.
        ProviderStyle(id: "codex", name: "Codex", accentHex: "#2B8FFF", glyph: .logo("openai"),
                      fallback: .symbol("chevron.left.forwardslash.chevron.right")),
        ProviderStyle(id: "gemini", name: "Gemini", accentHex: "#34C759", glyph: .logo("gemini"),
                      fallback: .symbol("sparkle")),
        ProviderStyle(id: "pi", name: "Pi", accentHex: "#007AFF", glyph: .logo("pi"), fallback: .text("π")),
        ProviderStyle(id: "grok", name: "Grok", accentHex: "#636366", glyph: .logo("grok"), fallback: .symbol("bolt.fill")),
        ProviderStyle(id: "devin", name: "Devin", accentHex: "#5C84B0", glyph: .logo("devin"),
                      fallback: .symbol("diamond.fill")),
        ProviderStyle(id: "opencode", name: "OpenCode", accentHex: "#AF52DE", glyph: .logo("opencode"),
                      fallback: .symbol("terminal.fill")),
        // OpenClaw's own menu-bar critter: it reads at every size, where
        // the full mascot blurs below 16 pt.
        ProviderStyle(id: "openclaw", name: "OpenClaw", accentHex: "#B23400", glyph: .logo("openclaw"),
                      fallback: .symbol("pawprint.fill")),
        ProviderStyle(id: "antigravity", name: "Antigravity", accentHex: "#ABE17E", glyph: .logo("antigravity"),
                      fallback: .symbol("arrow.up.to.line")),
        ProviderStyle(id: "cursor", name: "Cursor", accentHex: "#FFCC00", glyph: .logo("cursor"),
                      fallback: .symbol("cursorarrow")),
        ProviderStyle(id: "hermes", name: "Hermes Agent", accentHex: "#FF9500", glyph: .logo("hermes"),
                      fallback: .symbol("paperplane.fill")),
        ProviderStyle(id: "kiro", name: "Kiro", accentHex: "#A00848", glyph: .logo("kiro"), fallback: .text("K")),
        // A usage source rather than an agent: the daemon reports it in
        // `state.usage.providers` (`provider_usage_cli.py`), so the Usage
        // Center needs a name for it that is not "Openai-api". The same
        // blossom as Codex; the colour and the name tell them apart.
        ProviderStyle(id: "openai-api", name: "OpenAI API", accentHex: "#10A37F", glyph: .logo("openai"),
                      fallback: .symbol("key.horizontal.fill")),
        // A usage source the daemon appends to the usage graph when its
        // T3 coverage exists — matches the daemon's own "T3 Code" label.
        ProviderStyle(id: "t3code", name: "T3 Code", accentHex: "#00B8D9", glyph: .logo("t3code"),
                      fallback: .symbol("cube")),
        // JR-Bar's own rows: the daemon bundles orphaned workers of mixed
        // providers into one "Background agents" row under this id
        // (`mailbox._candidate_for_orphan_workers`). JR-Bar's notch-cap mark.
        ProviderStyle(id: "jrbar", name: "JR-Bar", accentHex: "#5E5CE6", glyph: .logo("jrbar"),
                      fallback: .symbol("square.stack.3d.up.fill")),
    ].map { ($0.id, $0) })

    static func style(for provider: String) -> ProviderStyle {
        let key = provider.lowercased()
        if let known = table[key] { return known }
        // Unknown providers get a neutral tile and a readable name, never a blank.
        let name = key.isEmpty ? "Agent" : key.prefix(1).uppercased() + key.dropFirst()
        return ProviderStyle(id: key, name: name, accentHex: "#8E8E93", glyph: .symbol(unknownSymbol))
    }

    /// The default style with a configured `colors.agent_colors.<id>`
    /// applied over `accentHex` when the stored hex validates; the
    /// default unchanged when it does not.
    static func style(for provider: String, document: SettingsDocument?) -> ProviderStyle {
        let style = style(for: provider)
        guard let hex = document?.agentColorHex(provider) else { return style }
        return ProviderStyle(id: style.id, name: style.name, accentHex: hex, glyph: style.glyph,
                             fallback: style.fallback)
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
