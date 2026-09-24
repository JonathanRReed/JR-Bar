import Foundation
import JRBarCore

/// A verb JR-Bar performs on request from outside its own surfaces: a
/// `jrbar://` link (Raycast Quicklinks, Alfred, Shortcuts' Open URLs, a
/// deck key, `open` in a script) or a global shortcut bound on Settings ›
/// Shortcuts. One vocabulary for both, so every route does exactly what
/// the others do.
///
/// Deliberately absent: answering an ask. Approve and Deny stay on the
/// panel, the banner and the island, where the ask itself is on screen —
/// a link that could approve would let any page that opens a URL answer
/// for you. So are the menu bar's Hide all / Show all, which rewrite the
/// curated item map.
enum AppCommand: Equatable, Sendable {
    /// The panel: open it, or toggle it (a shortcut's second press).
    case panel(toggle: Bool)
    /// Settings, on a page (a `SettingsStore.Page` raw value) or where it was.
    case settings(page: String?)
    case window(AppWindow)
    /// A Control Center chip: flip it, or set it (`on`) — a verb chip
    /// (Lock, Saver) just fires.
    case toggle(SystemToggle, on: Bool?)
    /// Keep the Mac awake for that many seconds, indefinitely (nil), or
    /// release the hold (0).
    case keepAwake(seconds: Int?)
    /// JR-Bar's quiet override: a mode (`pause`, `dim`, `mute`,
    /// `asks_only`, `dark`; nil keeps the panel's last one) for seconds.
    case quiet(mode: String?, seconds: Int)
    case endQuiet
    /// Deep work: asks-only quiet for that many seconds, then one line on
    /// what the agents did meanwhile (`DeepWork`).
    case deepWork(seconds: Int)
    /// The Screen Bar on, off, or flipped (nil).
    case screenBar(on: Bool?)
    /// A burst, like the card's Test burst, in the colours `tint` names.
    case confetti(tint: ConfettiTint = .focused)
    case menuBar(MenuBarVerb)
    /// A session by its daemon id — raises its terminal or app.
    case openSession(String)
    /// The ask that has waited longest, on the panel where it can be
    /// answered.
    case revealAsk
    /// The notch's shelf: open it, or fold it when it is open.
    case shelf

    /// A window by the name a link uses: `jrbar://open/<name>`,
    /// `jrbar://window/<name>`, or the bare `jrbar://<name>`.
    enum AppWindow: String, CaseIterable, Sendable {
        case overview, history, usage, effects, controlCenter = "control-center", setup
        case whatsNew = "whats-new"
    }

    /// Whose colours a linked burst wears: the focused session's (a bare
    /// `jrbar://confetti`), a provider's (`?provider=codex`), or a
    /// session's (`?session=<id>`, the daemon's id or the agent's own) —
    /// the same targets `jrbar confetti` takes.
    enum ConfettiTint: Equatable, Sendable {
        case focused
        case provider(String)
        case session(String)
    }

    /// A provider id as a link may spell it: lowercased, `claude`,
    /// `codex`, `gemini`… — the daemon's own `confetti` grammar.
    nonisolated static func providerID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first), id.count <= 32,
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0) })
        else { return nil }
        return id
    }

    /// The provider a burst wears: the one named, else the named session's,
    /// else the focused session's; nil is the Toys tint. `providerOf`
    /// reads a watched session's provider by the daemon's id or the
    /// agent's own.
    nonisolated static func confettiProvider(_ tint: ConfettiTint, focused: String?,
                                             providerOf: (String) -> String?) -> String? {
        switch tint {
        case .provider(let id): return id
        case .session(let id): return providerOf(id)
        case .focused: return focused.flatMap(providerOf)
        }
    }

    /// A watched session's provider by the daemon's id (`claude:session:…`)
    /// or the agent's own session id — a hook's `session_id` names its main
    /// row, as the daemon's `confetti` reads it.
    nonisolated static func provider(ofSession id: String, in sessions: [CoreSession]) -> String? {
        (sessions.first { $0.id == id } ?? sessions.first { $0.id.hasSuffix(":session:\(id)") })?.provider
    }

    /// The menu-bar verbs safe to trigger from outside: reveals and the
    /// palette, never the curation-rewriting Hide all / Show all.
    enum MenuBarVerb: String, CaseIterable, Sendable {
        case reveal, toggle, alwaysHidden = "always-hidden", commandBar = "command-bar"
    }

    /// The quiet modes the daemon's `quiet` command takes.
    nonisolated static let quietModes: Set<String> = ["pause", "dim", "mute", "asks_only", "dark"]

    /// An hour of quiet when a link names no length.
    nonisolated static let defaultQuietSeconds = 3600
    /// A day: the longest quiet or hold a link may ask for.
    nonisolated static let maximumSeconds = 86_400

    // MARK: jrbar:// links

    nonisolated static let scheme = "jrbar"

    /// The command a `jrbar://` URL names, or nil for anything else. The
    /// first component is the verb (`jrbar://toggle/dark` reads the same
    /// as `jrbar:///toggle/dark`), the rest its object, the query its
    /// options. Unknown verbs, objects and option values are refused
    /// whole — a link never half-runs.
    nonisolated static func parse(_ url: URL) -> AppCommand? {
        parse(url, now: Date(), calendar: .current)
    }

    /// The same, with the clock an `until=` time is placed on.
    nonisolated static func parse(_ url: URL, now: Date, calendar: Calendar = .current) -> AppCommand? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = parts.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if let host = parts.host, !host.isEmpty { path.insert(host, at: 0) }
        guard let verb = path.first?.lowercased() else { return nil }
        let object = path.dropFirst().first
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }

        switch verb {
        case "panel":
            switch object?.lowercased() {
            case nil, "open", "show": return .panel(toggle: false)
            case "toggle": return .panel(toggle: true)
            default: return nil
            }
        case "settings":
            guard let object else { return .settings(page: nil) }
            let page = object.lowercased()
            return SettingsPageName.known.contains(page) ? .settings(page: page) : nil
        case "open", "window":
            guard let object, let window = AppWindow(rawValue: object.lowercased()) else { return nil }
            return .window(window)
        case "overview", "history", "usage", "effects", "control-center", "setup", "whats-new":
            return AppWindow(rawValue: verb).map(AppCommand.window)
        case "toggle":
            guard let object, let toggle = SystemToggle(name: object) else { return nil }
            guard let raw = query["on"] else { return .toggle(toggle, on: nil) }
            guard let on = flag(raw) else { return nil }
            return .toggle(toggle, on: on)
        case "awake":
            if let raw = query["until"] {
                guard query["for"] == nil, let seconds = secondsUntil(raw, now: now, calendar: calendar) else { return nil }
                return .keepAwake(seconds: seconds)
            }
            guard let raw = query["for"] else { return .keepAwake(seconds: nil) }
            if let off = flag(raw), !off { return .keepAwake(seconds: 0) }
            guard let seconds = duration(raw), seconds <= maximumSeconds else { return nil }
            return .keepAwake(seconds: seconds)
        case "quiet":
            if object?.lowercased() == "end" { return .endQuiet }
            guard object == nil else { return nil }
            var mode: String?
            if let raw = query["mode"]?.lowercased().replacingOccurrences(of: "-", with: "_") {
                let normalized = raw == "dnd" ? "pause" : raw
                guard quietModes.contains(normalized) else { return nil }
                mode = normalized
            }
            if let raw = query["until"] {
                guard query["for"] == nil, let seconds = secondsUntil(raw, now: now, calendar: calendar) else { return nil }
                return .quiet(mode: mode, seconds: seconds)
            }
            guard let raw = query["for"] else { return .quiet(mode: mode, seconds: defaultQuietSeconds) }
            if let on = flag(raw), !on { return .endQuiet }
            guard let seconds = duration(raw), seconds <= maximumSeconds else { return nil }
            return seconds == 0 ? .endQuiet : .quiet(mode: mode, seconds: seconds)
        case "deepwork", "deep-work":
            if let object {
                return ["end", "stop", "off"].contains(object.lowercased()) ? .endQuiet : nil
            }
            if let raw = query["until"] {
                guard query["for"] == nil, let seconds = secondsUntil(raw, now: now, calendar: calendar) else { return nil }
                return .deepWork(seconds: seconds)
            }
            guard let raw = query["for"] else { return .deepWork(seconds: DeepWork.defaultSeconds) }
            guard let seconds = duration(raw), (60...maximumSeconds).contains(seconds) else { return nil }
            return .deepWork(seconds: seconds)
        case "screenbar", "screen-bar":
            switch object?.lowercased() {
            case nil, "toggle": return .screenBar(on: nil)
            case let value?:
                return flag(value).map { .screenBar(on: $0) }
            }
        case "confetti":
            guard object == nil else { return nil }
            switch (query["provider"], query["session"]) {
            case (nil, nil):
                return .confetti()
            case (let raw?, nil):
                return providerID(raw).map { .confetti(tint: .provider($0)) }
            case (nil, let id?):
                guard !id.isEmpty, id.count <= 512 else { return nil }
                return .confetti(tint: .session(id))
            default:
                // One target, like `jrbar confetti`: both is refused whole.
                return nil
            }
        case "menubar", "menu-bar":
            guard let object, let menuVerb = MenuBarVerb(rawValue: object.lowercased()) else { return nil }
            return .menuBar(menuVerb)
        case "session":
            let id = query["id"] ?? object
            guard let id, !id.isEmpty, id.count <= 512 else { return nil }
            return .openSession(id)
        case "ask":
            return object == nil ? .revealAsk : nil
        case "shelf":
            return object == nil ? .shelf : nil
        default:
            return nil
        }
    }

    /// The `jrbar://` link that names this command, the one `parse` reads
    /// back: what a reminder, a deck key or a menu row carries to run it
    /// later. Values ride in the query, percent-encoded, so a session id
    /// keeps its colons out of the path and whatever else it holds
    /// arrives whole (`jrbar://session?id=claude:session:…`).
    nonisolated var link: URL {
        var path: [String]
        var query: [(name: String, value: String)] = []
        switch self {
        case .panel(let toggle):
            path = toggle ? ["panel", "toggle"] : ["panel"]
        case .settings(let page):
            path = ["settings"] + (page.map { [$0] } ?? [])
        case .window(let window):
            path = ["window", window.rawValue]
        case .toggle(let toggle, let on):
            path = ["toggle", toggle.rawValue]
            if let on { query.append(("on", on ? "1" : "0")) }
        case .keepAwake(let seconds):
            path = ["awake"]
            if let seconds { query.append(("for", String(seconds))) }
        case .quiet(let mode, let seconds):
            path = ["quiet"]
            if let mode { query.append(("mode", mode)) }
            query.append(("for", String(seconds)))
        case .endQuiet:
            path = ["quiet", "end"]
        case .deepWork(let seconds):
            path = ["deepwork"]
            query.append(("for", String(seconds)))
        case .screenBar(let on):
            path = ["screenbar", on.map { $0 ? "on" : "off" } ?? "toggle"]
        case .confetti(let tint):
            path = ["confetti"]
            switch tint {
            case .focused: break
            case .provider(let id): query.append(("provider", id))
            case .session(let id): query.append(("session", id))
            }
        case .menuBar(let verb):
            path = ["menubar", verb.rawValue]
        case .openSession(let id):
            path = ["session"]
            query.append(("id", id))
        case .revealAsk:
            path = ["ask"]
        case .shelf:
            path = ["shelf"]
        }
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = path[0]
        parts.percentEncodedPath = path.dropFirst().map { "/" + linkEncoded($0) }.joined()
        if !query.isEmpty {
            parts.percentEncodedQuery = query.map { $0.name + "=" + linkEncoded($0.value) }.joined(separator: "&")
        }
        // Every piece above is encoded down to URL-safe ASCII, so the
        // components always make a URL.
        return parts.url!
    }

    /// Everything but unreserved ASCII and the colon a daemon id is built
    /// from, percent-encoded: `&`, `=`, `+`, `#`, `/` and anything past
    /// ASCII can't be misread as structure.
    nonisolated private static let linkSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    nonisolated private func linkEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.linkSafe) ?? ""
    }

    /// Seconds from `now` to the next time the clock reads `raw` —
    /// `08:00`, `8am`, `8:30pm`, `20:30` — later today, or tomorrow
    /// once today's has passed; Amphetamine's "until 8 AM". nil for
    /// anything else, so a typo is refused rather than guessed at.
    nonisolated static func secondsUntil(_ raw: String, now: Date, calendar: Calendar) -> Int? {
        var text = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where text.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            text.removeLast(suffix.count)
            break
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(minute) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        } else if parts.count == 1 {
            // A bare "8" reads as a clock hour only with am/pm or a colon
            // form; a bare number is a duration elsewhere, so refuse it.
            return nil
        }
        guard (0...23).contains(hour),
              let next = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                           matchingPolicy: .nextTime) else { return nil }
        let seconds = Int(next.timeIntervalSince(now).rounded(.up))
        return (1...maximumSeconds).contains(seconds) ? seconds : nil
    }

    /// `1/0`, `true/false`, `on/off`, `yes/no`.
    nonisolated static func flag(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: return nil
        }
    }

    /// Seconds from `7200`, `90s`, `15m`, `2h`, `1d` or a run of them
    /// (`1h30m`). nil for anything else — including a zero-length unit
    /// or an overflow — so a typo is refused rather than read as zero.
    nonisolated static func duration(_ raw: String) -> Int? {
        let text = raw.lowercased().replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        if let plain = Int(text) { return plain >= 0 ? plain : nil }
        var total = 0
        var digits = ""
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            let unit: Int
            switch character {
            case "s": unit = 1
            case "m": unit = 60
            case "h": unit = 3600
            case "d": unit = 86_400
            default: return nil
            }
            guard let value = Int(digits) else { return nil }
            let (product, overflow) = value.multipliedReportingOverflow(by: unit)
            guard !overflow else { return nil }
            let (sum, sumOverflow) = total.addingReportingOverflow(product)
            guard !sumOverflow else { return nil }
            total = sum
            digits = ""
        }
        return digits.isEmpty ? total : nil
    }
}

/// The Settings pages a link may name — `SettingsStore.Page`'s raw
/// values, listed here so the pure parser needs no main-actor type.
enum SettingsPageName {
    nonisolated static let known: Set<String> = [
        "general", "agents", "usage", "devices", "utilities", "lighting", "toys",
        "notifications", "sounds", "shortcuts", "remote", "advanced",
    ]
}

extension SystemToggle {
    /// A chip by the name a link or a script would use: its raw value
    /// (`darkMode`), or the word on the chip and its obvious synonyms
    /// (`dark`, `awake`, `caffeinate`), case- and dash-insensitive.
    init?(name: String) {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if let exact = SystemToggle.allCases.first(where: { $0.rawValue.lowercased() == key }) {
            self = exact
            return
        }
        switch key {
        case "awake", "caffeinate", "keepawake": self = .keepAwake
        case "dark", "darkmode", "appearance": self = .darkMode
        case "desktop", "desktopicons", "icons": self = .desktopIcons
        case "hidden", "hiddenfiles", "dotfiles": self = .hiddenFiles
        case "mute", "sound", "output": self = .mute
        case "saver", "screensaver": self = .screenSaver
        case "lock", "lockscreen": self = .lock
        case "dock", "dockautohide", "autohide": self = .dockAutoHide
        case "mic", "microphone", "micmute", "mutemic": self = .micMute
        case "unmount", "ejectall": self = .eject
        case "sleepnow", "suspend": self = .sleep
        default: return nil
        }
    }
}
