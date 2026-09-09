import Foundation

/// "Why is the light doing that": one line built from `lights.surfaces.*.why`
/// with the session that explains it, plus the detail lines the hover
/// popover shows (each surface's program and the settings that shape
/// brightness). Pure and testable; the panel and the Screen Bar tooltip
/// both read it.
public struct LightExplanation: Hashable, Sendable {
    public struct Detail: Hashable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The daemon's `why`, normalised (`completed_unseen`).
    public var why: String
    /// "Amber pulse", "Breathing blue", "Dim ember".
    public var motion: String
    /// "Codex sidepulse-core is waiting on you (permission, 45 s)".
    public var reason: String
    /// The session the light is about, when there is one.
    public var session: String?
    public var details: [Detail]

    public init(why: String, motion: String, reason: String, session: String? = nil, details: [Detail] = []) {
        self.why = why
        self.motion = motion
        self.reason = reason
        self.session = session
        self.details = details
    }

    /// "Amber pulse: Codex sidepulse-core is waiting on you (permission, 45 s)".
    public var headline: String { "\(motion): \(reason)" }
}

public enum LightExplainer {
    /// One row of the table: how a `why` reads. `motion` nil means "derive
    /// it from the surface's motion word and colour".
    struct Entry: Sendable {
        var motion: String?
        var reason: @Sendable (Context) -> String
    }

    /// Everything a reason line may mention.
    public struct Context: Sendable {
        public var state: CoreState?
        public var settings: SettingsDocument?
        public var surface: CoreLightSurface?
        public var now: Date

        public init(state: CoreState? = nil, settings: SettingsDocument? = nil, surface: CoreLightSurface? = nil, now: Date = Date()) {
            self.state = state
            self.settings = settings
            self.surface = surface
            self.now = now
        }
    }

    /// The `why` values the daemon uses today (and the older names the
    /// Python attention model produced), each with a hand-written line.
    static let table: [String: Entry] = [
        "working": Entry(motion: nil) { context in
            let working = context.workingSessions
            guard let first = working.first else { return "An agent is working" }
            let more = working.count > 1 ? " and \(working.count - 1) more" : ""
            return "\(first.providerName) \(first.shortLabel) is working\(more)"
        },
        "needs_you": askEntry, "ask": askEntry, "waiting": askEntry, "waiting_for_input": askEntry, "permission": askEntry,
        "completed_unseen": doneEntry, "completed": doneEntry, "done": doneEntry, "completed_recently": doneEntry,
        "failed": Entry(motion: "Red flash") { context in
            guard let session = context.failedSession else { return "An agent failed" }
            let ago = Self.ago(session.updatedAt ?? session.since, now: context.now)
            return "\(session.providerName) \(session.shortLabel) failed\(ago.map { " \($0)" } ?? "")"
        },
        "idle": Entry(motion: "Idle breath") { context in
            let count = context.state?.mainSessions.count ?? 0
            return count == 0 ? "Nothing is running" : (count == 1 ? "1 session, nothing to do" : "\(count) sessions, nothing to do")
        },
        "quiet": quietEntry, "dnd": quietEntry, "dim": quietEntry, "dark": quietEntry, "schedule": quietEntry, "focus": quietEntry, "pause": quietEntry,
        "idle_dim": Entry(motion: "Dimmed") { context in
            let after = context.settings?.double("idle_dim_after_minutes").map { Int($0) } ?? 10
            let fraction = context.settings?.double("idle_dim_fraction") ?? 0.3
            return "Idle for \(after) min, dimmed to \(Int((fraction * 100).rounded()))%"
        },
        "sleep_dim": Entry(motion: "Dimmed") { _ in "Display asleep, keeping a faint glow" },
        "auto_off": Entry(motion: "Off") { context in
            let after = context.settings?.double("idle_auto_off_after_minutes").map { Int($0) } ?? 60
            return "Auto-off after \(after) min idle"
        },
        "off": Entry(motion: "Off") { _ in "Lights are off" },
        "quota": quotaEntry, "quota_crossed": quotaEntry, "quota_ember": quotaEntry, "quota_warning": quotaEntry,
        "escalation": escalationEntry, "escalation_ramp": escalationEntry, "escalation_menu_bar": escalationEntry, "escalation_final": escalationEntry,
        "preview": Entry(motion: "Preview") { _ in "Previewing a program from Settings" },
        "effect": Entry(motion: nil) { _ in "An Effect Studio program is assigned" },
        "first_light": Entry(motion: "Hello sweep") { _ in "The core just started" },
        "hello": Entry(motion: "Hello sweep") { _ in "The core just started" },
        "device_error": Entry(motion: "Red blink") { context in
            let broken = context.state?.devices.first { ($0.error ?? "").isEmpty == false }
            return broken.map { "\($0.name ?? $0.kind): \($0.error ?? "device error")" } ?? "A device reported an error"
        },
        "lid_closed": Entry(motion: "Amber sweep") { _ in "The lid closed while agents are running" },
        "lid_open": Entry(motion: "Green sweep") { _ in "Welcome back" },
    ]

    static let askEntry = Entry(motion: "Amber pulse") { context in
        guard let (session, ask) = context.openAsk else { return "An agent is waiting on you" }
        var qualifiers: [String] = []
        if let kind = ask.kind, !kind.isEmpty { qualifiers.append(kind.replacingOccurrences(of: "_", with: " ")) }
        if let opened = ask.openedAt, let elapsed = Self.elapsed(seconds: context.now.timeIntervalSince1970 - opened) {
            qualifiers.append(elapsed)
        }
        let suffix = qualifiers.isEmpty ? "" : " (\(qualifiers.joined(separator: ", ")))"
        return "\(session.providerName) \(session.shortLabel) is waiting on you\(suffix)"
    }

    static let doneEntry = Entry(motion: "Green sweep") { context in
        guard let session = context.completedSession else { return "An agent finished" }
        let ago = Self.ago(session.updatedAt ?? session.since, now: context.now)
        return "\(session.shortLabel) finished\(ago.map { " \($0)" } ?? "")"
    }

    static let quietEntry = Entry(motion: "Dim ember") { context in
        let focus = context.state?.focus
        let mode = focus?.mode ?? "quiet"
        let source = focus?.source ?? ""
        let word: String
        switch source {
        case "schedule": word = "quiet hours"
        case "manual", "override": word = "quiet (\(mode))"
        case "focus": word = "Focus is on"
        default: word = mode == "dnd" ? "Do Not Disturb" : "quiet mode (\(mode))"
        }
        if let until = focus?.until, until > context.now.timeIntervalSince1970 {
            return "\(word.prefix(1).uppercased() + word.dropFirst()) until \(Self.clock(until))"
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    static let quotaEntry = Entry(motion: "Amber ember") { context in
        guard let usage = context.state?.usage?.providers.max(by: { ($0.windows.first?.usedPct ?? 0) < ($1.windows.first?.usedPct ?? 0) }),
              let window = usage.windows.first else { return "A usage window is nearly spent" }
        return "\(Self.providerName(usage.id)) \(window.name) window at \(Int(window.usedPct.rounded()))%"
    }

    static let escalationEntry = Entry(motion: "Bright amber pulse") { context in
        let stage = context.state?.escalation?.stageNumber ?? 0
        let since = context.state?.escalation?.since ?? context.openAsk?.1.openedAt
        let waited = since.flatMap { Self.elapsed(seconds: context.now.timeIntervalSince1970 - $0) }
        let who = context.openAsk.map { "\($0.0.providerName) \($0.0.shortLabel)" } ?? "An ask"
        return "\(who) has waited\(waited.map { " \($0)" } ?? "") · escalation stage \(stage)"
    }

    // MARK: Entry point

    /// Nil when there are no lights to explain.
    public static func explain(lights: CoreLights?, state: CoreState?, settings: SettingsDocument?, now: Date = Date()) -> LightExplanation? {
        guard let lights, !lights.surfaces.isEmpty else { return nil }
        let surface = lights.screenBar ?? lights.hardware ?? lights.surfaces.values.first
        let rawWhy = surface?.why ?? lights.hardware?.why ?? lights.surfaces.values.compactMap(\.why).first ?? "unknown"
        let why = normalise(rawWhy)
        let context = Context(state: state, settings: settings, surface: surface, now: now)
        let entry = table[why]
        let motion = entry?.motion ?? derivedMotion(surface: surface, why: why)
        let reason = entry?.reason(context) ?? "Core says \(rawWhy.replacingOccurrences(of: "_", with: " "))"
        var session: String?
        switch why {
        case "needs_you", "ask", "waiting", "waiting_for_input", "permission", "escalation", "escalation_ramp", "escalation_menu_bar", "escalation_final":
            session = context.openAsk?.0.id
        case "working": session = context.workingSessions.first?.id
        case "completed_unseen", "completed", "done", "completed_recently": session = context.completedSession?.id
        case "failed": session = context.failedSession?.id
        default: session = nil
        }
        return LightExplanation(why: why, motion: motion, reason: reason, session: session, details: details(lights: lights, context: context))
    }

    public static func normalise(_ why: String) -> String {
        why.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    // MARK: Motion words

    /// "Breathing blue" / "Blue relay" / "Cyan pulse" / "Steady green" from
    /// the surface's motion word and fallback colour.
    static func derivedMotion(surface: CoreLightSurface?, why: String) -> String {
        let colour = surface?.staticFallback.flatMap(colourName) ?? "soft"
        let cap = colour.prefix(1).uppercased() + colour.dropFirst()
        switch surface?.motion?.lowercased() {
        case "breathe", "breathing": return "Breathing \(colour)"
        case "chase", "relay", "roll": return "\(cap) relay"
        case "beat", "pulse", "blink": return "\(cap) pulse"
        case "sweep": return "\(cap) sweep"
        case "static", "steady", "solid", "hold": return "Steady \(colour)"
        case "off": return "Off"
        case nil, "": return why == "working" ? "Breathing \(colour)" : "\(cap) light"
        case let other?: return "\(cap) \(other)"
        }
    }

    /// A plain-English colour for a `#RRGGBB` (the eight words a person
    /// would use looking at the strip).
    public static func colourName(_ hex: String) -> String? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return text.lowercased() == "off" ? "off" : nil
        }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        if maxC < 0.08 { return "dim" }
        if delta < 0.10 { return maxC > 0.7 ? "white" : "grey" }
        var hue: Double
        if maxC == r { hue = (g - b) / delta }
        else if maxC == g { hue = 2 + (b - r) / delta }
        else { hue = 4 + (r - g) / delta }
        hue *= 60
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 345...: return "red"
        case 15..<40: return "orange"
        case 40..<65: return "amber"
        case 65..<160: return "green"
        case 160..<200: return "cyan"
        case 200..<260: return "blue"
        case 260..<300: return "purple"
        default: return "pink"
        }
    }

    // MARK: Details

    static func details(lights: CoreLights, context: Context) -> [LightExplanation.Detail] {
        var result: [LightExplanation.Detail] = []
        for (key, label) in [("hardware", "Hardware"), ("screen_bar", "Screen Bar"), ("dot", "Dot")] {
            guard let surface = lights.surfaces[key] else { continue }
            var parts: [String] = []
            if let leds = surface.ledCount { parts.append("\(leds) LEDs") }
            if let motion = surface.motion, !motion.isEmpty { parts.append(motion) }
            if let colour = surface.staticFallback.flatMap(colourName) { parts.append(colour) }
            if let brightness = surface.brightness { parts.append("\(Int((brightness * 100).rounded()))% bright") }
            if let anchor = surface.anchor, let ago = elapsed(seconds: context.now.timeIntervalSince1970 - anchor) { parts.append("started \(ago) ago") }
            if parts.isEmpty { parts.append(surface.program.isEmpty ? "no program" : "\(surface.program.split(separator: "\n").count) lines") }
            result.append(.init(label: label, value: parts.joined(separator: " · ")))
        }
        if lights.linked == true, lights.surfaces.count > 1 { result.append(.init(label: "Linked", value: "hardware and Screen Bar share one program")) }
        if let settings = context.settings {
            let global = settings.double("global_brightness_scale") ?? 1
            result.append(.init(label: "Global brightness", value: "\(Int((global * 100).rounded()))%"))
            if settings.bool("idle_dim_enabled") == true {
                let after = Int(settings.double("idle_dim_after_minutes") ?? 10)
                let fraction = Int(((settings.double("idle_dim_fraction") ?? 0.3) * 100).rounded())
                result.append(.init(label: "Idle dim", value: "to \(fraction)% after \(after) min"))
            } else {
                result.append(.init(label: "Idle dim", value: "off"))
            }
            if settings.bool("dnd_schedule_enabled") == true {
                let start = settings.double("dnd_schedule_start_minutes") ?? 1320
                let end = settings.double("dnd_schedule_end_minutes") ?? 420
                let mode = settings.string("dnd_schedule_mode") ?? "dark"
                result.append(.init(label: "Quiet hours", value: "\(mode) \(minutes(start))–\(minutes(end))"))
            } else {
                result.append(.init(label: "Quiet hours", value: "off"))
            }
        }
        if let focus = context.state?.focus, let mode = focus.mode, mode != "normal" {
            var value = mode
            if let source = focus.source { value += " (\(source))" }
            if let until = focus.until, until > context.now.timeIntervalSince1970 { value += " until \(clock(until))" }
            result.append(.init(label: "Focus", value: value))
        }
        return result
    }

    // MARK: Formatting

    static func elapsed(seconds: Double) -> String? {
        let seconds = Int(seconds.rounded())
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) d"
    }

    static func ago(_ epoch: Double?, now: Date) -> String? {
        guard let epoch, let text = elapsed(seconds: now.timeIntervalSince1970 - epoch) else { return nil }
        return "\(text) ago"
    }

    static func clock(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func minutes(_ total: Double) -> String {
        let value = Int(total) % (24 * 60)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    static func providerName(_ id: String) -> String {
        switch id.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "openclaw": return "OpenClaw"
        case "pi": return "Pi"
        case "": return "Agent"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

extension LightExplainer.Context {
    var mains: [CoreSession] { state?.mainSessions ?? [] }

    var workingSessions: [CoreSession] {
        mains.filter { ["working", "tool_running", "thinking", "running"].contains(($0.mode ?? "").lowercased()) && ($0.lifecycle ?? "active") == "active" }
            .sorted { ($0.since ?? 0) > ($1.since ?? 0) }
    }

    /// The oldest open ask with its session (asks pinned in `state.asks`
    /// first, then embedded ones).
    var openAsk: (CoreSession, CoreAsk)? {
        var candidates: [(CoreSession, CoreAsk)] = []
        for ask in state?.asks ?? [] {
            if let id = ask.session, let session = state?.session(withID: id) { candidates.append((session, ask)) }
        }
        for session in mains where session.ask != nil && !candidates.contains(where: { $0.0.id == session.id }) {
            candidates.append((session, session.ask!))
        }
        return candidates.min { ($0.1.openedAt ?? 0) < ($1.1.openedAt ?? 0) }
    }

    var completedSession: CoreSession? {
        mains.filter { ["completed", "done"].contains(($0.lifecycle ?? "").lowercased()) || ($0.mode ?? "") == "completed" }
            .max { ($0.updatedAt ?? $0.since ?? 0) < ($1.updatedAt ?? $1.since ?? 0) }
    }

    var failedSession: CoreSession? {
        mains.filter { ($0.lifecycle ?? "").lowercased() == "failed" || ["failed", "error"].contains(($0.mode ?? "").lowercased()) }
            .max { ($0.updatedAt ?? $0.since ?? 0) < ($1.updatedAt ?? $1.since ?? 0) }
    }
}

extension CoreSession {
    /// The label, or the provider's name when the session has none.
    public var shortLabel: String {
        if let label, !label.isEmpty { return label }
        return providerName
    }

    public var providerName: String { LightExplainer.providerName(provider) }

    /// A worker or sub-agent rather than a main session.
    public var isSubagent: Bool { kind != "main" || parent != nil }
}
