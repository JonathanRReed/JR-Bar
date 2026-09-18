import Foundation

/// Splits a running app's localized name into the product name and its
/// release-channel tag so cards can show "T3 Code" with a small
/// `Nightly` chip instead of one long "T3 Code (Nightly)" line.
///
/// Three spellings are recognised, longest channel words first:
/// a parenthesised tail ("T3 Code (Nightly)"), a spaced dash
/// ("Code - Insiders"), a bare hyphen ("Xcode-beta"), and a trailing
/// channel word ("Firefox Developer Edition", "Discord PTB"). The base
/// must survive non-empty — "Preview" the app is not a channel tag.
/// Pure: the tests pin the table.
enum AppNameChannel {
    /// Channel words that may follow a separator or stand as the last
    /// word. Ordered longest-first so "Technology Preview" wins over
    /// "Preview".
    static let channelWords = [
        "Technology Preview", "Developer Preview", "Developer Edition",
        "Early Access", "Insiders", "Insider", "Nightly", "Canary",
        "Beta", "Alpha", "Dev", "Preview", "PTB",
    ]

    /// `(base, channel)` — channel nil when the name carries no tag.
    static func split(_ name: String) -> (base: String, channel: String?) {
        let n = name.trimmingCharacters(in: .whitespaces)
        // "T3 Code (Nightly)"
        if n.hasSuffix(")"), let open = n.lastIndex(of: "(") {
            let inner = String(n[n.index(after: open)..<n.index(before: n.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let base = String(n[..<open]).trimmingCharacters(in: .whitespaces)
            if isChannel(inner), !base.isEmpty { return (base, inner) }
            return (name, nil)
        }
        // "Code - Insiders" / spaced em/en dashes
        for sep in [" - ", " – ", " — "] {
            guard let range = n.range(of: sep, options: .backwards) else { continue }
            let tail = String(n[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let base = String(n[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if isChannel(tail), !base.isEmpty { return (base, tail) }
        }
        // "Firefox Developer Edition" — a channel word standing as the
        // tail, word-boundary checked so "Devonshire" can't match "Dev".
        for word in channelWords where n.count > word.count + 1 {
            if n.hasSuffix(word), n[n.index(n.endIndex, offsetBy: -(word.count + 1))] == " " {
                let base = String(n.dropLast(word.count + 1)).trimmingCharacters(in: .whitespaces)
                if !base.isEmpty { return (base, word) }
            }
        }
        // "Xcode-beta" — a bare hyphen is only a separator when the tail
        // is a channel word, so "Day-One" never splits.
        if let dash = n.lastIndex(of: "-"), dash > n.startIndex {
            let tail = String(n[n.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            let base = String(n[..<dash]).trimmingCharacters(in: .whitespaces)
            if isChannel(tail), !base.isEmpty { return (base, tail) }
        }
        return (name, nil)
    }

    static func isChannel(_ word: String) -> Bool {
        if channelWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            return true
        }
        // RC, RC1, RC2… — a release candidate counts as a channel too.
        let upper = word.uppercased()
        guard upper.hasPrefix("RC"), upper.count > 2 || upper == "RC" else { return false }
        return upper == "RC" || upper.dropFirst(2).allSatisfy(\.isNumber)
    }
}
