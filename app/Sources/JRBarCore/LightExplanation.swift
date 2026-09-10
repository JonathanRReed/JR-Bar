import Foundation

/// "Why is the light doing that": one line built from `lights.surfaces.*.why`
/// and `why_detail`, with the session that explains it, plus the detail
/// lines the hover popover shows (each surface's program and the settings
/// that shape brightness). Pure and testable; the panel and the Screen Bar
/// tooltip both read it.
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

    /// The daemon's `why`, normalised (`completed_unseen` → `completed`).
    public var why: String
    /// The documented case the `why` maps to; `.unknown` for anything else.
    public var kind: LightWhy
    /// "Amber pulse", "Breathing orange", "Dim ember".
    public var motion: String
    /// "Codex sidepulse-core is waiting on you (permission, 45 s)".
    public var reason: String
    /// The session the light is about, when there is one.
    public var session: String?
    public var details: [Detail]

    public init(why: String, kind: LightWhy = .unknown, motion: String, reason: String, session: String? = nil, details: [Detail] = []) {
        self.why = why
        self.kind = kind
        self.motion = motion
        self.reason = reason
        self.session = session
        self.details = details
    }

    /// "Amber pulse: Codex sidepulse-core is waiting on you (permission, 45 s)".
    public var headline: String { "\(motion): \(reason)" }
}

/// The documented `why` vocabulary (`docs/CORE-PROTOCOL.md`, lights).
public enum LightWhy: String, CaseIterable, Sendable {
    case idle, working, waiting, completed, failed, capacity, quiet
    case sleepDim = "sleep_dim"
    case idleDim = "idle_dim"
    case battery, calendar, reminder, escalation, preview, studio, unknown

    /// The documented word, or the older spellings the daemon and the
    /// Python attention model used for the same thing; nil for anything else.
    public static func parse(_ raw: String?) -> LightWhy? {
        guard let raw else { return nil }
        let key = LightExplainer.normalise(raw)
        if let exact = LightWhy(rawValue: key) { return exact }
        switch key {
        case "needs_you", "ask", "permission", "waiting_for_input", "input_required": return .waiting
        case "completed_unseen", "done", "completed_recently", "ready": return .completed
        case "error", "failure": return .failed
        case "quota", "quota_crossed", "quota_ember", "quota_warning", "limited": return .capacity
        case "dnd", "dim", "dark", "schedule", "focus", "pause", "quiet_hours": return .quiet
        case "sleep", "display_sleep", "asleep": return .sleepDim
        case "low_battery", "on_battery": return .battery
        case "meeting", "event": return .calendar
        case "effect", "effect_studio": return .studio
        default:
            if key.hasPrefix("escalation") { return .escalation }
            return nil
        }
    }
}

public enum LightExplainer {
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

        var detail: CoreWhyDetail? { surface?.whyDetail }
    }

    // MARK: Entry point

    /// Nil when there are no lights to explain.
    public static func explain(lights: CoreLights?, state: CoreState?, settings: SettingsDocument?, now: Date = Date()) -> LightExplanation? {
        guard let lights, !lights.surfaces.isEmpty else { return nil }
        let surface = lights.screenBar ?? lights.hardware ?? lights.surfaces.values.first
        let rawWhy = surface?.why ?? lights.hardware?.why ?? lights.surfaces.values.compactMap(\.why).first ?? "unknown"
        let why = normalise(rawWhy)
        let kind = LightWhy.parse(rawWhy) ?? .unknown
        let context = Context(state: state, settings: settings, surface: surface, now: now)
        let (motion, reason, session) = line(kind: kind, raw: rawWhy, context: context)
        return LightExplanation(why: why, kind: kind, motion: motion, reason: reason, session: session,
                                details: details(lights: lights, context: context))
    }

    public static func normalise(_ why: String) -> String {
        why.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    // MARK: The sentence

    /// Motion word, reason and the session for one `why`.
    static func line(kind: LightWhy, raw: String, context: Context) -> (String, String, String?) {
        let derived = derivedMotion(surface: context.surface, kind: kind)
        let subject = context.subject(for: kind)
        switch kind {
        case .working:
            let working = context.workingSessions
            let who = subject ?? working.first.map(context.who)
            guard let who else { return (derived, "An agent is working", nil) }
            let others = working.filter { $0.id != (context.detail?.session ?? working.first?.id) }.count
            let more = others > 0 ? " and \(others) more" : ""
            return (derived, "\(who.name) is working\(more)", who.id)
        case .waiting:
            guard let who = subject ?? context.openAsk.map({ context.who($0.0) }) else { return ("Amber pulse", "An agent is waiting on you", nil) }
            var qualifiers: [String] = []
            let ask = context.openAsk?.1 ?? context.state?.session(withID: who.id ?? "")?.ask
            if let kind = ask?.kind, !kind.isEmpty { qualifiers.append(kind.replacingOccurrences(of: "_", with: " ")) }
            let waited = ask?.openedAt.map { context.now.timeIntervalSince1970 - $0 } ?? context.detail?.secondsInState
            if let waited, let elapsed = elapsed(seconds: waited) { qualifiers.append(elapsed) }
            let suffix = qualifiers.isEmpty ? "" : " (\(qualifiers.joined(separator: ", ")))"
            return ("Amber pulse", "\(who.name) is waiting on you\(suffix)", who.id)
        case .completed:
            guard let who = subject ?? context.completedSession.map(context.who) else { return ("Green sweep", "An agent finished", nil) }
            let ago = context.agoText(for: who.id, fallback: context.detail?.secondsInState)
            return ("Green sweep", "\(who.name) finished\(ago.map { " \($0)" } ?? "")", who.id)
        case .failed:
            guard let who = subject ?? context.failedSession.map(context.who) else { return ("Red flash", "An agent failed", nil) }
            let ago = context.agoText(for: who.id, fallback: context.detail?.secondsInState)
            return ("Red flash", "\(who.name) failed\(ago.map { " \($0)" } ?? "")", who.id)
        case .idle:
            let count = context.state?.mainSessions.count ?? 0
            let reason = count == 0 ? "Nothing is running" : (count == 1 ? "1 session, nothing to do" : "\(count) sessions, nothing to do")
            let colour = context.surface?.staticFallback.flatMap(dominantColourName)
            return (colour == nil || colour == "dim" ? "Idle breath" : derived, reason, nil)
        case .capacity:
            // Only a window with a reading can be named as nearly spent. A
            // window the provider stated no number for has nothing to put
            // in the sentence, and must not be read as an empty one.
            let measured = (context.state?.usage?.providers ?? []).compactMap { provider -> (provider: CoreProviderUsage, window: CoreUsageWindow, pct: Double)? in
                guard let fullest = provider.windows.compactMap({ window in window.usedPct.map { (window, $0) } }).max(by: { $0.1 < $1.1 }) else { return nil }
                return (provider, fullest.0, fullest.1)
            }
            guard let top = measured.max(by: { $0.pct < $1.pct }) else { return ("Amber ember", "A usage window is nearly spent", nil) }
            return ("Amber ember", "\(SessionLabel.providerName(top.provider.id)) \(top.window.shortName) window at \(Int(top.pct.rounded()))%", nil)
        case .quiet:
            return ("Dim ember", quietReason(context), nil)
        case .sleepDim:
            return ("Dimmed", "Display asleep, keeping a faint glow", nil)
        case .idleDim:
            let after = context.settings?.double("idle_dim_after_minutes").map { Int($0) } ?? 10
            let fraction = context.detail?.brightnessFactor ?? context.settings?.double("idle_dim_fraction") ?? 0.3
            return ("Dimmed", "Idle for \(after) min, dimmed to \(percent(fraction))", nil)
        case .battery:
            let dimmed = context.detail?.brightnessFactor.map { ", dimmed to \(percent($0))" } ?? ""
            return ("Dimmed", "On battery\(dimmed)", nil)
        case .calendar:
            let dimmed = context.detail?.brightnessFactor.map { $0 < 0.999 ? ", dimmed to \(percent($0))" : "" } ?? ""
            return (derived, "In a calendar event\(dimmed)", nil)
        case .reminder:
            return (derived, "A reminder is due", nil)
        case .escalation:
            let stage = context.state?.escalation?.stageNumber ?? 0
            let since = context.state?.escalation?.since ?? context.openAsk?.1.openedAt
            let waited = since.map { context.now.timeIntervalSince1970 - $0 } ?? context.detail?.secondsInState
            let who = subject ?? context.openAsk.map { context.who($0.0) }
            let name = who?.name ?? "An ask"
            let waitedText = waited.flatMap { elapsed(seconds: $0) }.map { " \($0)" } ?? ""
            let stageText = stage > 0 ? " · escalation stage \(stage)" : " · escalating"
            return ("Bright amber pulse", "\(name) has waited\(waitedText)\(stageText)", who?.id)
        case .preview:
            return ("Preview", "Previewing a program", nil)
        case .studio:
            return ("Preview", "Effect Studio is previewing", nil)
        case .unknown:
            // Today's daemon may send a word the table has no line for: say
            // what the light looks like and who is on top, never a UUID.
            let who = subject ?? context.topSession.map(context.who)
            let humanised = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ")
            let unexplained = normalise(raw) == "unknown" || humanised.isEmpty
            if let who {
                let verb = context.activityWord(for: who.id)
                let suffix = unexplained ? "" : " (\(humanised))"
                return (derived, "\(who.name) \(verb)\(suffix)", who.id)
            }
            return (derived, unexplained ? "Core gave no reason" : "Core says \(humanised)", nil)
        }
    }

    static func quietReason(_ context: Context) -> String {
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
        let capitalised = word.prefix(1).uppercased() + word.dropFirst()
        if let until = focus?.until, until > context.now.timeIntervalSince1970 {
            return "\(capitalised) until \(clock(until))"
        }
        return capitalised
    }

    // MARK: Motion words

    /// "Breathing orange" / "Orange sweep" / "Steady green" from the
    /// surface's motion word (`static`, `finite`, `continuous`, or the
    /// older `breathe` / `chase` / `beat` / `sweep`) and its fallback colour.
    static func derivedMotion(surface: CoreLightSurface?, kind: LightWhy) -> String {
        let colour = surface?.staticFallback.flatMap(dominantColourName)
        let cap = colour.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if colour == "off" { return "Off" }
        switch surface?.motion?.lowercased() {
        case "breathe", "breathing", "continuous", "loop":
            return colour.map { "Breathing \($0)" } ?? "Breathing"
        case "chase", "relay", "roll":
            return cap.map { "\($0) relay" } ?? "Relay"
        case "beat", "pulse", "blink":
            return cap.map { "\($0) pulse" } ?? "Pulse"
        case "sweep", "finite":
            return cap.map { "\($0) sweep" } ?? "Sweep"
        case "static", "steady", "solid", "hold":
            return colour.map { "Steady \($0)" } ?? "Steady light"
        case "off":
            return "Off"
        case nil, "":
            if kind == .working { return colour.map { "Breathing \($0)" } ?? "Breathing" }
            return cap.map { "\($0) light" } ?? "Light"
        case let other?:
            return cap.map { "\($0) \(other)" } ?? other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    /// The brightest colour named in a fallback: a bare `#RRGGBB`, or the
    /// brightest hex code in a whole static program (`0:#0B0604; 3:#8D4D39; …`).
    public static func dominantColourName(_ fallback: String) -> String? {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = colourName(trimmed) { return single }
        var best: (value: UInt32, brightness: Int)?
        var index = trimmed.startIndex
        while let hash = trimmed[index...].firstIndex(of: "#") {
            let start = trimmed.index(after: hash)
            let end = trimmed.index(start, offsetBy: 6, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            if let value = UInt32(trimmed[start..<end], radix: 16), trimmed.distance(from: start, to: end) == 6 {
                let r = Int((value >> 16) & 0xFF), g = Int((value >> 8) & 0xFF), b = Int(value & 0xFF)
                let brightness = max(r, g, b)
                if best == nil || brightness > best!.brightness { best = (value, brightness) }
            }
            index = end
        }
        guard let best else { return nil }
        return colourName(String(format: "#%06X", best.value))
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
        // A fully saturated red-orange (#FF3A00) reads red; the same hue at
        // lower saturation (terracotta, #D97757) reads orange.
        let redEnd: Double = delta / maxC > 0.85 ? 15 : 10
        switch hue {
        case ..<redEnd, 345...: return "red"
        case redEnd..<40: return "orange"
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
            if let colour = surface.staticFallback.flatMap(dominantColourName) { parts.append(colour) }
            if let brightness = surface.brightness { parts.append("\(Int((brightness * 100).rounded()))% bright") }
            if let anchor = surface.anchor, let ago = elapsed(seconds: context.now.timeIntervalSince1970 - anchor) { parts.append("started \(ago) ago") }
            if parts.isEmpty { parts.append(surface.program.isEmpty ? "no program" : "\(surface.program.split(separator: "\n").count) lines") }
            result.append(.init(label: label, value: parts.joined(separator: " · ")))
            // The Dot's role decides its program and its `why`, so the
            // popover says which one is driving it — or that nothing is
            // (`role` absent means the Dot renders its own display).
            if key == "dot" {
                let role = surface.role.map(DotRole.parse)
                result.append(.init(label: "Dot role", value: role.map(\.label) ?? "Status · its own display"))
            }
        }
        if lights.linked == true, lights.surfaces.count > 1 { result.append(.init(label: "Linked", value: "hardware and Screen Bar share one program")) }
        if let detail = context.detail {
            if let seconds = detail.secondsInState, let text = elapsed(seconds: seconds) { result.append(.init(label: "In this state", value: text)) }
            if !detail.dimming.isEmpty {
                let factor = detail.brightnessFactor.map { " · \(percent($0))" } ?? ""
                result.append(.init(label: "Dimming", value: detail.dimming.map { dimmingWord($0, lights: lights) }.joined(separator: ", ") + factor))
            }
        }
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
            if AutoDimSettings.isProvided(in: settings) {
                let autoDim = AutoDimSettings(document: settings)
                var value = autoDim.summary
                if autoDim.mode != .off, let line = AutoDimReadout.line(lights.autoDim, settings: autoDim) { value += " · \(line)" }
                result.append(.init(label: "Auto-dim", value: value))
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

    /// The `why_detail.dimming` words as the popover shows them: `idle_dim`
    /// → "idle dim", `quiet` → "quiet", `sleep` → "sleep", `auto_dim` →
    /// "Auto-dim (schedule)" from `lights.auto_dim`.
    static func dimmingWord(_ word: String, lights: CoreLights) -> String {
        switch word {
        case "auto_dim", "night_dim": return AutoDimReadout.dimmingWord(lights.autoDim)
        default: return word.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: Formatting

    /// No light state has held for more than a year, so anything past that
    /// is not a duration. The daemon has been seen sending an epoch in
    /// `why_detail.seconds_in_state` (1.79e9 on 2026-09-10, which would
    /// have read "20704 d"); saying nothing beats saying that.
    static let longestPlausibleState: Double = 400 * 24 * 60 * 60

    static func elapsed(seconds: Double) -> String? {
        guard seconds.isFinite, seconds < longestPlausibleState else { return nil }
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

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
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

    static func providerName(_ id: String) -> String { SessionLabel.providerName(id) }
}

extension LightExplainer.Context {
    /// "Claude jr-bar-67" and the session id it names.
    struct Subject {
        var name: String
        var id: String?
    }

    var mains: [CoreSession] { state?.mainSessions ?? [] }

    func who(_ session: CoreSession) -> Subject {
        Subject(name: "\(session.providerName) \(session.displayLabel)", id: session.id)
    }

    /// The subject `why_detail` names, when the daemon sent one: its
    /// session (looked up for the full record), else its label and provider.
    func subject(for kind: LightWhy) -> Subject? {
        guard let detail else { return nil }
        if let id = detail.session, let session = state?.session(withID: id) { return who(session) }
        let provider = detail.provider ?? state?.session(withID: detail.session ?? "")?.provider ?? ""
        let hasName = (detail.label?.isEmpty == false) || (detail.session?.isEmpty == false)
        guard hasName else { return nil }
        let label = SessionLabel.display(label: detail.label, shortId: nil, id: detail.session ?? "", provider: provider)
        let name = provider.isEmpty ? label : "\(SessionLabel.providerName(provider)) \(label)"
        return Subject(name: name, id: detail.session)
    }

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

    /// The session the panel lists first: an ask, then waiting, failed,
    /// working, done, idle; ties by the most recent change.
    /// An ask embedded in the session or pinned in `state.asks`.
    func hasAsk(_ session: CoreSession) -> Bool {
        session.ask != nil || (state?.asks ?? []).contains { $0.session == session.id }
    }

    var topSession: CoreSession? {
        func rank(_ session: CoreSession) -> Int {
            if hasAsk(session) { return 0 }
            let mode = (session.mode ?? "").lowercased()
            let lifecycle = (session.lifecycle ?? "active").lowercased()
            if lifecycle == "failed" || mode == "failed" || mode == "error" { return 2 }
            if lifecycle == "completed" || lifecycle == "done" || mode == "completed" { return 4 }
            if mode == "waiting" || mode == "ask" || session.nextActor == "user" { return 1 }
            if ["working", "tool_running", "thinking", "running", "active"].contains(mode) { return 3 }
            return 5
        }
        return mains.min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.since ?? 0) > (b.since ?? 0)
        }
    }

    /// "is working" / "is waiting on you" / "finished" / "failed" / "is idle" for a session id.
    func activityWord(for id: String?) -> String {
        guard let id, let session = state?.session(withID: id) else { return "is on top" }
        let mode = (session.mode ?? "").lowercased()
        let lifecycle = (session.lifecycle ?? "active").lowercased()
        if lifecycle == "failed" || mode == "failed" || mode == "error" { return "failed" }
        if lifecycle == "completed" || lifecycle == "done" || mode == "completed" { return "finished" }
        if hasAsk(session) || mode == "waiting" || mode == "ask" || session.nextActor == "user" { return "is waiting on you" }
        if ["working", "tool_running", "thinking", "running", "active"].contains(mode) { return "is working" }
        return "is idle"
    }

    /// "12 s ago" from the session's last change, else from `seconds_in_state`.
    func agoText(for id: String?, fallback seconds: Double?) -> String? {
        if let id, let session = state?.session(withID: id), let text = LightExplainer.ago(session.updatedAt ?? session.since, now: now) { return text }
        if let seconds, let text = LightExplainer.elapsed(seconds: seconds) { return "\(text) ago" }
        return nil
    }
}

extension CoreSession {
    /// The label the panel shows: no provider prefix, no UUID (see `SessionLabel`).
    public var displayLabel: String {
        SessionLabel.display(label: label, shortId: shortId, id: id, provider: provider)
    }

    /// The label, or the provider's name when the session has none.
    public var shortLabel: String {
        if let label, !label.isEmpty { return label }
        return providerName
    }

    public var providerName: String { SessionLabel.providerName(provider) }

    /// A worker or sub-agent rather than a main session.
    public var isSubagent: Bool { kind != "main" || parent != nil }
}
