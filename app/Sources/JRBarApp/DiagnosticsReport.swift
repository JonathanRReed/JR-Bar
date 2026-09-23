import Foundation
import JRBarCore

/// Settings › Advanced › "Copy diagnostics": one plain-text block for a
/// bug report or a paste into a Claude session — the app's version,
/// build and commit beside the daemon's (a mismatch said out loud), the
/// Doctor's checks, every Setup permission and the core log's tail.
///
/// Pure on purpose: the store gathers the facts, this writes them, and
/// everything passes through `redact` on the way out, so a home folder,
/// a token, an address or a webhook's secret path never lands on the
/// pasteboard.
enum DiagnosticsReport {
    struct Facts: Sendable {
        var appVersion: String
        var appCommit: String?
        var system: String
        var bundlePath: String
        var connection: String
        var coreVersion: String?
        /// The `doctor` reply, nil while the monitor is not connected.
        var doctor: JSONValue?
        /// Setup's rows in their own order, title and status word.
        var permissions: [(title: String, status: String)]
        var log: [CoreLog]
        var home: String
        var generated: Date
        var timeZone: TimeZone = .current
    }

    /// Log lines the block carries — the same tail the page shows.
    static let logLines = 150

    nonisolated static func text(_ facts: Facts) -> String {
        var lines: [String] = []
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = facts.timeZone
        lines.append("JR-Bar diagnostics — \(stamp.string(from: facts.generated))")
        lines.append("")
        lines.append("App: \(facts.appVersion)")
        lines.append("System: \(facts.system)")
        lines.append("Bundle: \(facts.bundlePath)")
        lines.append("Monitor: \(facts.connection)")
        if let version = facts.coreVersion { lines.append("Core version: \(version)") }
        let daemonCommit = facts.doctor?["commit"]?.stringValue
        if let daemonCommit { lines.append("Core commit: \(shortCommit(daemonCommit))") }
        if commitsDiffer(app: facts.appCommit, daemon: daemonCommit) {
            lines.append("WARNING: the app (\(shortCommit(facts.appCommit ?? ""))) and the monitor "
                + "(\(shortCommit(daemonCommit ?? ""))) are different builds.")
        }

        lines.append("")
        lines.append("Doctor:")
        if let doctor = facts.doctor {
            if let error = doctor["error"]?.stringValue {
                lines.append("  failed: \(error)")
            } else {
                if let ok = doctor["ok"]?.boolValue { lines.append("  healthy: \(ok ? "yes" : "no")") }
                for key in ["uptime_seconds", "clients", "state_generation", "settings_generation"] {
                    if let value = doctor[key], let word = scalar(value) { lines.append("  \(key): \(word)") }
                }
                for check in doctor["checks"]?.arrayValue ?? [] {
                    let name = check["name"]?.stringValue ?? "?"
                    let ok = check["ok"]?.boolValue ?? false
                    let detail = check["detail"]?.stringValue.map { " — \($0)" } ?? ""
                    lines.append("  [\(ok ? "ok" : "!!")] \(name)\(detail)")
                }
                for key in ["hooks", "devices"] {
                    guard let members = doctor[key]?.objectValue, !members.isEmpty else { continue }
                    let pairs = members.keys.sorted().map { "\($0)=\(scalar(members[$0]!) ?? "…")" }
                    lines.append("  \(key): \(pairs.joined(separator: ", "))")
                }
            }
        } else {
            lines.append("  not run — the monitor is not connected")
        }

        lines.append("")
        lines.append("Permissions:")
        for row in facts.permissions {
            lines.append("  \(row.title): \(row.status)")
        }

        lines.append("")
        let tail = facts.log.suffix(logLines)
        lines.append("Core log (last \(tail.count) lines):")
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        clock.timeZone = facts.timeZone
        clock.locale = Locale(identifier: "en_US_POSIX")
        for entry in tail {
            let time = entry.at.map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--:--"
            let level = (entry.level ?? "info").uppercased()
            lines.append("  \(time) \(level) \(entry.message ?? "")")
        }
        return redact(lines.joined(separator: "\n"), home: facts.home) + "\n"
    }

    /// Two builds worth a warning: both commits known and not the same
    /// tree (a `-dirty` tail and a full hash against a short one match).
    nonisolated static func commitsDiffer(app: String?, daemon: String?) -> Bool {
        func key(_ commit: String?) -> String? {
            guard var commit = commit?.trimmingCharacters(in: .whitespaces), !commit.isEmpty,
                  commit != "unknown" else { return nil }
            if commit.hasSuffix("-dirty") { commit.removeLast("-dirty".count) }
            return String(commit.prefix(7)).lowercased()
        }
        guard let app = key(app), let daemon = key(daemon) else { return false }
        return app != daemon
    }

    nonisolated static func shortCommit(_ commit: String) -> String {
        let dirty = commit.hasSuffix("-dirty")
        let hash = dirty ? String(commit.dropLast("-dirty".count)) : commit
        return String(hash.prefix(7)) + (dirty ? "-dirty" : "")
    }

    private nonisolated static func scalar(_ value: JSONValue) -> String? {
        switch value {
        case .bool(let on): return on ? "true" : "false"
        case .number(let number): return number == number.rounded() ? "\(Int(number))" : "\(number)"
        case .string(let text): return text
        case .null: return "null"
        case .array, .object: return nil
        }
    }

    // MARK: Redaction

    /// `serve_token: abc…`, `"password": "…"`, `api_key=…` — the value
    /// after a secret-sounding key.
    private static let secretPair = try! NSRegularExpression(
        pattern: #"(?i)(\w*(?:token|secret|password|passwd|api[_-]?key|cookie)\w*)(["']?\s*[:=]\s*["']?)([^\s"',;}]{6,})"#)
    /// `Bearer abc…` / `Authorization: Basic abc…`.
    private static let scheme = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer|basic)(\s+)([A-Za-z0-9._~+/=-]{8,})"#)
    private static let email = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let url = try! NSRegularExpression(
        pattern: #"(https?://[^/\s"']+)(/[^\s"']*)?"#)

    /// The block with the person taken out: the home folder becomes `~`,
    /// a secret-looking value after token/password/key words becomes
    /// `<redacted>`, an address `<email>`, and a URL keeps only its host
    /// — a webhook's path is its secret.
    nonisolated static func redact(_ text: String, home: String) -> String {
        var out = text
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if home.count > 1 {
            // The folder itself, never a longer name it happens to start.
            out = out.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9._-])"#,
                                           with: "~", options: .regularExpression)
        }
        out = replace(secretPair, in: out, with: "$1$2<redacted>")
        out = replace(scheme, in: out, with: "$1$2<redacted>")
        out = replace(email, in: out, with: "<email>")
        // Last match first, so earlier ranges stay valid.
        for match in url.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let host = Range(match.range(at: 1), in: out) else { continue }
            let path = Range(match.range(at: 2), in: out).map { String(out[$0]) } ?? ""
            out.replaceSubrange(whole, with: String(out[host]) + (path.count > 1 ? "/…" : ""))
        }
        return out
    }

    private nonisolated static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
