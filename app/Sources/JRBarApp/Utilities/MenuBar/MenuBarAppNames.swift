import AppKit
import Observation

/// Saved picks can outlive their apps. Resolve each identity once, away
/// from the main actor, and let observing views redraw when it is ready.
@MainActor
@Observable
final class MenuBarAppNames {
    static let shared = MenuBarAppNames()
    private var version = 0
    @ObservationIgnored var lookup: @Sendable (String) -> String = MenuBarAppNames.lookupName
    @ObservationIgnored private lazy var cache = BackgroundLookupCache<String, String>(
        lifetime: 300,
        changed: { [weak self] in _ = Task { @MainActor in self?.version += 1 } },
        load: lookup)

    func name(for identity: String) -> String {
        _ = version
        return cache.value(for: identity) ?? Self.cleaned(identity)
    }

    func resolvedName(for identity: String) async -> String {
        await cache.resolve(identity) ?? Self.cleaned(identity)
    }

    nonisolated static func lookupName(_ identity: String) -> String {
        let url: URL?
        if identity.hasPrefix("/") || identity.hasPrefix("~/") {
            url = URL(fileURLWithPath: (identity as NSString).expandingTildeInPath)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identity)
        }
        if let url, let bundle = Bundle(url: url) {
            let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            for candidate in [display, name] {
                if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return candidate
                }
            }
            return cleaned(url.deletingPathExtension().lastPathComponent)
        }
        return cleaned(identity) + " (not installed)"
    }

    nonisolated static func cleaned(_ identity: String) -> String {
        var text = identity
        if text.contains("/") { text = URL(fileURLWithPath: text).deletingPathExtension().lastPathComponent }
        let parts = text.split(separator: ".").map(String.init)
        text = parts.last ?? text
        if text.lowercased() == "app", parts.count > 1 { text = parts[parts.count - 2] }
        text = text.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Z])([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[-_]"#, with: " ", options: .regularExpression)
        let name = text.split(whereSeparator: \.isWhitespace).map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        }.joined(separator: " ")
        return name.isEmpty ? "App" : name
    }

    /// Workspace names already carry the app's spelling and punctuation.
    nonisolated static func displayName(_ name: String) -> String {
        let identity = #"^(?:com|org|net|io|dev|app|test|synthetic)\.|^[a-z0-9]+[-_][a-z0-9_-]+$"#
        if name.contains("/") || name.range(of: identity, options: .regularExpression) != nil {
            return cleaned(name)
        }
        return name.isEmpty ? "App" : name
    }
}
