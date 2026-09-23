import AppKit
import JRBarCore

/// The palette's rows for everything past the menu bar. Each builder is
/// pure over plain values plus a struct of verbs, so what a row says
/// and which verbs it offers are tests; the wiring (`PaletteWiring`)
/// binds the verbs to the stores that already own each write — the
/// panel's answer path, the daemon's quiet, the Effect Studio's scene,
/// the notch card's Control Center strip.

// MARK: - Agents: open asks and sessions

/// The session verbs, bound to `PanelStore` — the same guarded paths
/// the panel's own rows use, so the palette can never answer an ask
/// the panel would refuse.
struct AgentPaletteVerbs {
    var open: @MainActor (SessionRow) -> Void
    var approve: @MainActor (CoreAsk) -> Void
    var deny: @MainActor (CoreAsk) -> Void
    var snooze: @MainActor (SessionRow, Int) -> Void
    var copyPath: @MainActor (SessionRow) -> Void
    var reveal: @MainActor (SessionRow) -> Void
    var dismiss: @MainActor (SessionRow) -> Void
    var clear: @MainActor (SessionRow) -> Void
    /// A reply-kind ask's words, through the panel's `reply` — the same
    /// `answer_ask` with `reply_text`, pinned to the request.
    var reply: @MainActor (CoreAsk, String) -> Void = { _, _ in }
    /// The panel's half-typed reply for the ask, both ways, so a line
    /// started in the panel finishes here and the other way round.
    var replyDraft: @MainActor (CoreAsk) -> String = { _ in "" }
    var setReplyDraft: @MainActor (CoreAsk, String) -> Void = { _, _ in }
}

enum AgentPaletteRows {
    static let approveChord = PaletteShortcut.secondary
    static let denyChord = PaletteShortcut.command("d")
    static let copyPathChord = PaletteShortcut.commandShift("c")
    static let revealChord = PaletteShortcut.commandShift("f")
    static let clearChord = PaletteShortcut(.delete, .command)

    /// Asks become urgent rows (Needs You); every other session is a
    /// row under Sessions. `rows` arrive in the panel's order — asks
    /// longest-waiting first — and keep it.
    @MainActor
    static func items(rows: [SessionRow], now: Date, verbs: AgentPaletteVerbs) -> [PaletteItem] {
        rows.map { row in
            if let ask = row.ask { return askItem(row: row, ask: ask, now: now, verbs: verbs) }
            return sessionItem(row: row, now: now, verbs: verbs)
        }
    }

    /// An open ask. Return opens the session — the one verb that is
    /// safe to fire without reading — and ⌘↩ answers: Approve (with
    /// Deny on ⌘D, the panel's own chords), or for an ask that wants
    /// words, Reply…, which opens the palette's field for them. Either
    /// appears only where the daemon says an answer can land: not for a
    /// peer's row, not where `canAnswer` is false.
    @MainActor
    static func askItem(row: SessionRow, ask: CoreAsk, now: Date, verbs: AgentPaletteVerbs) -> PaletteItem {
        var actions = [PaletteAction(id: "open", title: "Open Session", symbol: "macwindow") {
            verbs.open(row)
            return nil
        }]
        let answerable = ask.canAnswer && !row.isRemote && !ask.wantsTextReply
        // A field is only worth opening where the words can land: the
        // panel's own reply row asks the same of the ask.
        if ask.canAnswer, !row.isRemote, ask.wantsTextReply, ask.session?.isEmpty == false {
            actions.append(PaletteAction(
                id: "reply", title: "Reply…", symbol: "text.bubble", shortcut: approveChord,
                input: PaletteInput(
                    prompt: "Reply to \(row.label)…", submitTitle: "Send Reply",
                    initial: { verbs.replyDraft(ask) },
                    onChange: { verbs.setReplyDraft(ask, $0) },
                    submit: { words in
                        verbs.reply(ask, words)
                        return nil
                    })))
        }
        if answerable {
            actions.append(PaletteAction(id: "approve", title: "Approve", symbol: "checkmark.circle",
                                         shortcut: approveChord) {
                verbs.approve(ask)
                return nil
            })
            actions.append(PaletteAction(id: "deny", title: "Deny", symbol: "xmark.circle",
                                         shortcut: denyChord, isDestructive: true) {
                verbs.deny(ask)
                return nil
            })
        }
        actions += pathActions(row: row, verbs: verbs)
        if !row.isRemote {
            actions.append(PaletteAction(id: "snooze", title: "Snooze 1 Hour", symbol: "moon.zzz") {
                verbs.snooze(row, 3600)
                return nil
            })
        }
        var tags = [PaletteTag(text: "Needs You", tone: .attention)]
        if let age = PanelStore.elapsed(since: ask.openedAt.map { Date(timeIntervalSince1970: $0) } ?? row.since,
                                        now: now) {
            tags.append(PaletteTag(text: age))
        }
        let note: String?
        if row.isRemote {
            note = "Runs on \(row.remoteMachine ?? "another Mac") — answer it there"
        } else if !ask.canAnswer {
            note = "Answer it in the session's own window"
        } else {
            note = nil
        }
        return PaletteItem(
            id: "ask.\(row.id)", title: row.label,
            subtitle: ask.summary ?? (ask.wantsTextReply ? "Wants a typed reply" : "Needs your answer"),
            keywords: ["answer", "ask", row.style.name] + (ask.wantsTextReply ? ["reply"] : [])
                + (row.cwdTail.map { [$0] } ?? []),
            icon: .provider(row.style.id), tags: tags, kind: "Ask", section: .needsYou,
            actions: actions, urgent: true, accessibilityNote: note)
    }

    /// A session. Return opens it; the rest are the panel row's menu.
    @MainActor
    static func sessionItem(row: SessionRow, now: Date, verbs: AgentPaletteVerbs) -> PaletteItem {
        var actions = [PaletteAction(id: "open", title: "Open Session", symbol: "macwindow") {
            verbs.open(row)
            return nil
        }]
        actions += pathActions(row: row, verbs: verbs)
        if !row.isRemote {
            if row.isSnoozed(now: now) {
                actions.append(PaletteAction(id: "unsnooze", title: "Unsnooze", symbol: "bell") {
                    verbs.snooze(row, 0)
                    return nil
                })
            } else {
                actions.append(PaletteAction(id: "snooze", title: "Snooze 1 Hour", symbol: "moon.zzz") {
                    verbs.snooze(row, 3600)
                    return nil
                })
                actions.append(PaletteAction(id: "snoozeMorning", title: "Snooze Until Morning",
                                             symbol: "sunrise") {
                    verbs.snooze(row, PanelStore.secondsUntilMorning(from: now))
                    return nil
                })
            }
        }
        if row.activity.isClearable || row.stale {
            actions.append(PaletteAction(id: "clear", title: "Clear", symbol: "checkmark.circle.badge.xmark",
                                         shortcut: clearChord, isDestructive: true) {
                verbs.clear(row)
                return nil
            })
        }
        if row.isDismissible {
            let clearTaken = actions.contains { $0.shortcut == clearChord }
            actions.append(PaletteAction(id: "dismiss", title: "Dismiss Until It Speaks",
                                         symbol: "eye.slash",
                                         shortcut: clearTaken ? nil : clearChord, isDestructive: true) {
                verbs.dismiss(row)
                return nil
            })
        }
        var tags = [PaletteTag(text: row.activity == .waiting ? "Waiting" : row.activity.word,
                               tone: tone(for: row.activity))]
        if row.isSnoozed(now: now) { tags.append(PaletteTag(text: "Snoozed")) }
        if row.stale { tags.append(PaletteTag(text: "Stale")) }
        if let elapsed = row.elapsedText(now: now) { tags.append(PaletteTag(text: elapsed)) }
        var subtitle = row.activityFact ?? row.cwdTail
        if row.isRemote, let machine = row.remoteMachine { subtitle = "on \(machine)" }
        return PaletteItem(
            id: "session.\(row.id)", title: row.label, subtitle: subtitle,
            keywords: [row.style.name] + (row.cwdTail.map { [$0] } ?? []),
            icon: .provider(row.style.id), tags: tags, kind: "Session", section: .sessions,
            actions: actions)
    }

    @MainActor
    private static func pathActions(row: SessionRow, verbs: AgentPaletteVerbs) -> [PaletteAction] {
        guard row.cwd?.isEmpty == false else { return [] }
        return [
            PaletteAction(id: "copyPath", title: "Copy Path", symbol: "doc.on.doc",
                          shortcut: copyPathChord) {
                verbs.copyPath(row)
                return nil
            },
            PaletteAction(id: "reveal", title: "Reveal in Finder", symbol: "folder",
                          shortcut: revealChord) {
                verbs.reveal(row)
                return nil
            },
        ]
    }

    /// The roster-wide verbs the panel's footer holds, offered only when
    /// they would do something — and, while the daemon is away, one
    /// honest row saying so instead of an empty Sessions section.
    struct Commands {
        var live: Bool
        /// The panel header's connection line.
        var connection: String
        /// The app supervises the daemon, so a restart is ours to make.
        var canRestart: Bool
        var completed: Int
        /// Rows the standing undo would put back, while it stands.
        var undoable: Int?
    }

    struct CommandVerbs {
        var restart: @MainActor () -> Void
        var openPanel: @MainActor () -> Void
        var clearFinished: @MainActor () -> Void
        var undoClear: @MainActor () -> Void
    }

    @MainActor
    static func commandItems(_ state: Commands, verbs: CommandVerbs) -> [PaletteItem] {
        guard state.live else {
            var actions: [PaletteAction] = []
            if state.canRestart {
                actions.append(PaletteAction(id: "restart", title: "Restart Monitor",
                                             symbol: "arrow.clockwise") {
                    verbs.restart()
                    return nil
                })
            }
            actions.append(PaletteAction(id: "panel", title: "Open JR-Bar Panel", symbol: "menubar.dock.rectangle") {
                verbs.openPanel()
                return nil
            })
            return [PaletteItem(
                id: "agents.offline", title: "Monitor Not Connected", subtitle: state.connection,
                keywords: ["daemon", "core", "restart", "sessions"],
                icon: .symbol("bolt.horizontal.circle.fill", .red), kind: "JR-Bar", section: .sessions,
                actions: actions)]
        }
        var items: [PaletteItem] = []
        if state.completed > 0 {
            items.append(PaletteItem(
                id: "agents.clearFinished", title: "Clear Finished Sessions",
                subtitle: "\(state.completed) done, ended or stale",
                keywords: ["acknowledge", "tidy", "completed"],
                icon: .symbol("checkmark.circle.fill", .green), kind: "Command", section: .sessions,
                actions: [PaletteAction(id: "clear", title: "Clear Finished", symbol: "checkmark.circle") {
                    verbs.clearFinished()
                    return nil
                }]))
        }
        if let undoable = state.undoable {
            items.append(PaletteItem(
                id: "agents.undoClear", title: "Undo Clear",
                subtitle: undoable == 1 ? "Puts back the session just cleared"
                    : "Puts back the \(undoable) sessions just cleared",
                keywords: ["restore", "uncleared"],
                icon: .symbol("arrow.uturn.backward.circle.fill", .blue), kind: "Command", section: .sessions,
                actions: [PaletteAction(id: "undo", title: "Undo Clear", symbol: "arrow.uturn.backward") {
                    verbs.undoClear()
                    return nil
                }]))
        }
        return items
    }

    static func tone(for activity: SessionActivity) -> PaletteTag.Tone {
        switch activity {
        case .waiting: return .attention
        case .failed: return .alert
        case .done: return .positive
        case .working: return .accent
        case .ended, .idle: return .neutral
        }
    }
}

// MARK: - Quiet

struct QuietPaletteVerbs {
    /// `quiet {mode, seconds}` — the panel's preset, which remembers
    /// the mode for next time.
    var quiet: @MainActor (_ mode: String, _ seconds: Int) -> Void
    var end: @MainActor () -> Void
}

enum QuietPaletteRows {
    /// What each mode does, in the words the footer's help uses.
    static let modeLines: [String: String] = [
        "pause": "hides everything",
        "dim": "stills the lights",
        "mute": "stills the sounds",
        "asks_only": "lets only asks through",
        "dark": "turns the hardware off",
    ]

    /// The panel's presets — 30 minutes, an hour, four, until 08:00 —
    /// each running the remembered mode on Return, with every other
    /// mode one ⌘K away; plus End Quiet while a quiet this palette or
    /// the panel set is running (a schedule's or Focus's is not ours to
    /// end).
    @MainActor
    static func items(mode: String, quietLabel: String?, quietIsOurs: Bool, now: Date,
                      verbs: QuietPaletteVerbs) -> [PaletteItem] {
        let toMorning = PanelStore.secondsUntilMorning(from: now)
        // Whole seconds toward 08:00 land a fraction short of it; the
        // label names the minute the quiet actually ends on.
        let morning = Date(timeIntervalSince1970:
            ((now.timeIntervalSince1970 + Double(toMorning)) / 60).rounded() * 60)
        let presets: [(id: String, label: String, seconds: Int)] =
            fixedPresets.map { ($0.id, PaletteArguments.durationLabel($0.seconds), $0.seconds) }
            + [("morning", PanelStore.morningLabel(verb: "Until", target: morning), toMorning)]
        let current = PanelStore.quietModes.first { $0.id == mode } ?? PanelStore.quietModes[0]
        var items: [PaletteItem] = []
        if let quietLabel, quietIsOurs {
            items.append(PaletteItem(
                id: "quiet.end", title: "End Quiet", subtitle: quietLabel,
                keywords: ["resume", "unmute", "wake"],
                icon: .symbol("sun.max.fill", .yellow),
                tags: [PaletteTag(text: PanelStore.quietWord(mode), tone: .accent)],
                kind: "Quiet", section: .quiet,
                actions: [PaletteAction(id: "end", title: "End Quiet", symbol: "sun.max") {
                    verbs.end()
                    return nil
                }]))
        }
        for preset in presets {
            let phrase = preset.id == "morning" ? preset.label : "for \(preset.label)"
            let title = preset.id == "morning" ? "Quiet \(preset.label)" : "Quiet for \(preset.label)"
            items.append(PaletteItem(
                id: "quiet.\(preset.id)", title: title,
                subtitle: "\(current.label) — \(modeLines[current.id] ?? "quiet")",
                keywords: ["dnd", "do not disturb", "pause", "mute", "silence", "snooze"],
                icon: .symbol("moon.zzz.fill", .purple), kind: "Quiet", section: .quiet,
                actions: modeActions(leading: current.id, phrase: phrase, seconds: preset.seconds, verbs: verbs)))
        }
        return items
    }

    /// The presets with a fixed length — their ids are what a typed
    /// length of the same size answers to.
    static let fixedPresets: [(id: String, seconds: Int)] = [
        ("30m", 30 * 60), ("1h", 60 * 60), ("4h", 4 * 60 * 60),
    ]

    /// Every mode for one length: `leading` first (Return), the rest one
    /// ⌘K away.
    @MainActor
    static func modeActions(leading: String, phrase: String, seconds: Int,
                            verbs: QuietPaletteVerbs) -> [PaletteAction] {
        let lead = PanelStore.quietModes.first { $0.id == leading } ?? PanelStore.quietModes[0]
        return ([lead] + PanelStore.quietModes.filter { $0.id != lead.id })
            .map { mode in
                PaletteAction(id: mode.id, title: "\(mode.label) \(phrase)", symbol: symbol(for: mode.id)) {
                    verbs.quiet(mode.id, seconds)
                    return nil
                }
            }
    }

    /// A quiet of a typed length — "quiet 45m", "dim for 2h", "mute
    /// 1:30". The named mode leads (the remembered one for "quiet"),
    /// the subtitle names the minute it ends, and a length a preset
    /// already has takes that preset's row and its habit.
    @MainActor
    static func typedItems(query: String, mode remembered: String, now: Date,
                           verbs: QuietPaletteVerbs) -> [PaletteItem] {
        guard let asked = PaletteArguments.quiet(query) else { return [] }
        let lead = PanelStore.quietModes.first { $0.id == (asked.mode ?? remembered) }
            ?? PanelStore.quietModes[0]
        let label = PaletteArguments.durationLabel(asked.seconds)
        let ends = PanelStore.clockTime(now.addingTimeInterval(TimeInterval(asked.seconds)))
        let preset = fixedPresets.first { $0.seconds == asked.seconds }
        return [PaletteItem(
            id: "quiet.\(preset?.id ?? "typed")", title: "Quiet for \(label)",
            subtitle: "\(lead.label) — \(modeLines[lead.id] ?? "quiet"), until \(ends)",
            icon: .symbol("moon.zzz.fill", .purple), kind: "Quiet", section: .quiet,
            actions: modeActions(leading: lead.id, phrase: "for \(label)", seconds: asked.seconds, verbs: verbs))]
    }

    static func symbol(for mode: String) -> String {
        switch mode {
        case "pause": return "pause.circle"
        case "dim": return "sun.min"
        case "mute": return "speaker.slash"
        case "asks_only": return "questionmark.bubble"
        case "dark": return "lightbulb.slash"
        default: return "moon"
        }
    }
}

// MARK: - Lights

struct LightsPaletteVerbs {
    var setScene: @MainActor (String) -> Void
    var setBrightness: @MainActor (Double) -> Void
    var setScreenBar: @MainActor (Bool) -> Void
}

enum LightsPaletteRows {
    /// The brightness steps the Brightness row offers.
    static let brightnessSteps: [Double] = [0.1, 0.25, 0.5, 0.75, 1]

    /// A row per scene (the live one tagged Current), a Brightness row
    /// that is only a menu of steps, and the Screen Bar's switch. Scene
    /// switches report in the HUD; the scene list is Lighting's own.
    @MainActor
    static func items(activeScene: String, brightness: Double?, screenBarShown: Bool,
                      verbs: LightsPaletteVerbs) -> [PaletteItem] {
        var items: [PaletteItem] = LightingPage.scenes.map { scene in
            let current = scene.value == activeScene
            return PaletteItem(
                id: "scene.\(scene.value)", title: "\(scene.label) Scene",
                subtitle: current ? "The lights' live scene" : nil,
                keywords: ["scene", "lights", "led", "strip"],
                icon: .symbol(symbol(forScene: scene.value), tint(forScene: scene.value)),
                tags: current ? [PaletteTag(text: "Current", tone: .accent)] : [],
                kind: "Scene", section: .lights,
                actions: [PaletteAction(id: "switch", title: "Switch Scene", symbol: "lightbulb") {
                    verbs.setScene(scene.value)
                    return "Scene: \(scene.label)"
                }])
        }
        if let brightness {
            items.append(PaletteItem(
                id: "lights.brightness", title: "LED Brightness",
                subtitle: "Now \(percent(brightness))",
                keywords: ["dim", "bright", "lights", "led"],
                icon: .symbol("sun.max.fill", .orange), kind: "Lights", section: .lights,
                actions: brightnessSteps.map { step in
                    PaletteAction(id: "b\(Int(step * 100))", title: percent(step),
                                  symbol: step >= 0.75 ? "sun.max" : "sun.min") {
                        verbs.setBrightness(step)
                        return "Brightness \(percent(step))"
                    }
                },
                opensActions: true))
        }
        items.append(PaletteItem(
            id: "lights.screenBar", title: "Screen Bar",
            subtitle: "The light under the notch",
            keywords: ["band", "notch", "light"],
            icon: .symbol("rectangle.topthird.inset.filled", .blue),
            tags: [PaletteTag(text: screenBarShown ? "On" : "Off",
                              tone: screenBarShown ? .positive : .neutral)],
            kind: "Lights", section: .lights,
            actions: [PaletteAction(id: "toggle", title: screenBarShown ? "Hide Screen Bar" : "Show Screen Bar",
                                    symbol: screenBarShown ? "eye.slash" : "eye") {
                verbs.setScreenBar(!screenBarShown)
                return screenBarShown ? "Screen Bar hidden" : "Screen Bar shown"
            }]))
        return items
    }

    /// "brightness 40", "led 40%" — one row that sets exactly that,
    /// standing in for the Brightness menu while a strip or Dot is
    /// attached (`brightness` nil means none is, and nothing is offered).
    @MainActor
    static func typedItems(query: String, brightness: Double?, verbs: LightsPaletteVerbs) -> [PaletteItem] {
        guard let now = brightness, let asked = PaletteArguments.brightness(query) else { return [] }
        return [PaletteItem(
            id: "lights.brightness", title: "Set LED Brightness to \(percent(asked))",
            subtitle: "Now \(percent(now))",
            icon: .symbol(asked >= 0.75 ? "sun.max.fill" : "sun.min.fill", .orange),
            kind: "Lights", section: .lights,
            actions: [PaletteAction(id: "set", title: "Set Brightness", symbol: "sun.max") {
                verbs.setBrightness(asked)
                return "Brightness \(percent(asked))"
            }])]
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func symbol(forScene scene: String) -> String {
        switch scene {
        case "calm": return "leaf.fill"
        case "focus": return "scope"
        case "night": return "moon.stars.fill"
        case "demo": return "sparkles"
        case "travel": return "airplane"
        case "dnd": return "moon.fill"
        default: return "lightbulb.fill"
        }
    }

    static func tint(forScene scene: String) -> PaletteTint {
        switch scene {
        case "calm": return .teal
        case "focus": return .indigo
        case "night": return .purple
        case "demo": return .pink
        case "travel": return .blue
        default: return .gray
        }
    }
}

// MARK: - Control Center strip

enum ControlCenterPaletteRows {
    /// The strip's toggles as rows: live state as the tag (read back
    /// from the system, never the intent), the flip or the verb on
    /// Return, and the restart it causes said out loud.
    @MainActor
    static func items(isOn: [SystemToggle: Bool], applying: Set<SystemToggle>,
                      apply: @escaping @MainActor (SystemToggle) -> Void) -> [PaletteItem] {
        SystemToggle.allCases.map { toggle in
            let on = isOn[toggle]
            var tags: [PaletteTag] = []
            if applying.contains(toggle) {
                tags.append(PaletteTag(text: "Applying…"))
            } else if !toggle.isMomentary, let on {
                tags.append(PaletteTag(text: on ? "On" : "Off", tone: on ? .positive : .neutral))
            }
            let verb: String
            if toggle.isMomentary {
                verb = toggle == .lock ? "Lock" : "Start"
            } else if let on {
                verb = on ? "Turn Off" : "Turn On"
            } else {
                verb = "Toggle"
            }
            return PaletteItem(
                id: "system.\(toggle.rawValue)", title: title(of: toggle), subtitle: subtitle(of: toggle),
                keywords: keywords(of: toggle),
                icon: .symbol(toggle.symbol, tint(of: toggle)), tags: tags,
                kind: "Control Center", section: .controlCenter,
                actions: [PaletteAction(id: "apply", title: verb, symbol: toggle.symbol) {
                    apply(toggle)
                    return confirmation(for: toggle, wasOn: on)
                }])
        }
    }

    /// The HUD's line. In-process flips (keep awake, mute) are true the
    /// moment they return; a shell-backed one is still settling, so it
    /// says so rather than claiming the result.
    static func confirmation(for toggle: SystemToggle, wasOn: Bool?) -> String? {
        let name = title(of: toggle)
        switch toggle {
        case .lock, .screenSaver:
            return nil
        case .keepAwake, .mute:
            guard let wasOn else { return nil }
            return "\(name) \(wasOn ? "off" : "on")"
        default:
            guard let wasOn else { return "Switching \(name)" }
            return "Turning \(name) \(wasOn ? "off" : "on")"
        }
    }

    static func title(of toggle: SystemToggle) -> String {
        switch toggle {
        case .keepAwake: return "Keep Awake"
        case .darkMode: return "Dark Mode"
        case .desktopIcons: return "Desktop Icons"
        case .hiddenFiles: return "Hidden Files"
        case .mute: return "Mute Sound"
        case .screenSaver: return "Start Screen Saver"
        case .lock: return "Lock Screen"
        case .dockAutoHide: return "Dock Auto-Hide"
        }
    }

    static func subtitle(of toggle: SystemToggle) -> String? {
        if toggle == .lock { return "Sleeps the display — it locks where a password is set" }
        return toggle.restarts.map { "Restarts \($0)" }
    }

    static func keywords(of toggle: SystemToggle) -> [String] {
        switch toggle {
        case .keepAwake: return ["caffeinate", "amphetamine", "no sleep", "awake"]
        case .darkMode: return ["appearance", "theme", "light mode"]
        case .desktopIcons: return ["finder", "clean desktop"]
        case .hiddenFiles: return ["dotfiles", "finder", "show hidden files"]
        case .mute: return ["sound", "volume", "audio", "silence"]
        case .screenSaver: return ["saver"]
        case .lock: return ["sleep", "display", "away"]
        case .dockAutoHide: return ["dock", "autohide", "hide dock"]
        }
    }

    static func tint(of toggle: SystemToggle) -> PaletteTint {
        switch toggle {
        case .keepAwake: return .brown
        case .darkMode: return .indigo
        case .desktopIcons: return .teal
        case .hiddenFiles: return .gray
        case .mute: return .red
        case .screenSaver: return .purple
        case .lock: return .gray
        case .dockAutoHide: return .blue
        }
    }
}

// MARK: - Usage

enum UsagePaletteRows {
    /// One row per metered provider: the headline window's percent as
    /// the tag (amber from 75 %, red from 90 %), the window and reset
    /// as the subtitle, a live vendor incident said out loud. Return
    /// opens the Usage Center on that provider's card.
    @MainActor
    static func items(usage: [CoreProviderUsage], now: Date,
                      open: @escaping @MainActor (String) -> Void) -> [PaletteItem] {
        usage.compactMap { provider in
            guard let window = provider.headlineWindow else { return nil }
            let style = ProviderStyle.style(for: provider.id)
            var subtitle = window.shortName
            if let countdown = PanelStore.countdown(to: window.resetsAt, now: now) {
                subtitle += " · \(countdown)"
            }
            if let account = provider.instance, !account.isEmpty { subtitle += " · \(account)" }
            var tags: [PaletteTag] = []
            if let pct = window.usedPct {
                tags.append(PaletteTag(text: UsageWindowLabel.percent(pct),
                                       tone: pct >= 90 ? .alert : pct >= 75 ? .attention : .neutral))
            }
            if provider.incident?.isEmpty == false {
                tags.append(PaletteTag(text: "Incident", tone: .attention))
            }
            return PaletteItem(
                id: "usage.\(provider.identity)", title: "\(style.name) Usage", subtitle: subtitle,
                keywords: ["quota", "limit", "usage", provider.id],
                icon: .provider(provider.id), tags: tags, kind: "Usage", section: .usage,
                actions: [PaletteAction(id: "open", title: "Open in Usage Center", symbol: "chart.bar") {
                    open(provider.id)
                    return nil
                }])
        }
    }
}

// MARK: - Aquarium

struct AquariumPaletteVerbs {
    /// A pellet round for every fish; the line the HUD shows.
    var feed: @MainActor () -> String?
    var setOpen: @MainActor (Bool) -> Void
}

enum AquariumPaletteRows {
    /// Feed the Tank while there is a fish to feed — the game's own
    /// daily cap still decides what counts — and the tank's switch.
    @MainActor
    static func items(fishCount: Int, isOn: Bool, verbs: AquariumPaletteVerbs) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if fishCount > 0 {
            items.append(PaletteItem(
                id: "aquarium.feed", title: "Feed the Tank",
                subtitle: "A pellet for \(fishCount == 1 ? "the one fish" : "each of \(fishCount) fish")",
                keywords: ["aquarium", "fish", "food", "pellet"],
                icon: .symbol("fish.fill", .teal), kind: "Aquarium", section: .toys,
                actions: [PaletteAction(id: "feed", title: "Feed", symbol: "drop.fill") {
                    verbs.feed()
                }]))
        }
        items.append(PaletteItem(
            id: "aquarium.window", title: "Aquarium",
            subtitle: "Every session is a fish",
            keywords: ["tank", "fish"],
            icon: .symbol("water.waves", .blue),
            tags: [PaletteTag(text: isOn ? "On" : "Off", tone: isOn ? .positive : .neutral)],
            kind: "Toy", section: .toys,
            actions: [PaletteAction(id: "toggle", title: isOn ? "Close the Tank" : "Open the Tank",
                                    symbol: isOn ? "xmark.circle" : "macwindow") {
                verbs.setOpen(!isOn)
                return nil
            }]))
        return items
    }
}

// MARK: - Confetti

struct ConfettiPaletteVerbs {
    /// One burst now — the Toys card's Test burst, an explicit ask, so
    /// it fires whether or not the automatic bursts are on.
    var fire: @MainActor () -> Void
    /// The toy's own switch: bursts on JR-Bar's triggers.
    var setAutomatic: @MainActor (Bool) -> Void
}

enum ConfettiPaletteRows {
    /// Raycast's Confetti command: Return fires a burst on every screen;
    /// ⌘↩ flips the automatic bursts, which the row names rather than
    /// tagging, so an Off never reads as "this row does nothing".
    @MainActor
    static func items(automatic: Bool, verbs: ConfettiPaletteVerbs) -> [PaletteItem] {
        [PaletteItem(
            id: "toys.confetti", title: "Confetti", subtitle: "A burst on every screen",
            keywords: ["celebrate", "party", "tada", "burst", "popper"],
            icon: .symbol("party.popper.fill", .pink), kind: "Toy", section: .toys,
            actions: [
                PaletteAction(id: "fire", title: "Fire Confetti", symbol: "party.popper") {
                    verbs.fire()
                    return nil
                },
                PaletteAction(id: "automatic",
                              title: automatic ? "Turn Off Automatic Bursts" : "Turn On Automatic Bursts",
                              symbol: automatic ? "pause.circle" : "sparkles") {
                    verbs.setAutomatic(!automatic)
                    return automatic ? "Automatic confetti off" : "Automatic confetti on"
                },
            ])]
    }
}

// MARK: - Archive (Data Hoarder)

struct ArchivePaletteVerbs {
    /// Open the archive window on this record, searched for `query`.
    var openRecord: @MainActor (ArchiveRecord, String) -> Void
    /// Open the archive window searched for `query`.
    var search: @MainActor (String) -> Void
    /// The live session a captured record still ends, if any.
    var sessionFor: @MainActor (ArchiveRecord) -> String?
    var openSession: @MainActor (String) -> Void
}

enum ArchivePaletteRows {
    /// The archive answers from three typed characters on — shorter
    /// queries match half the transcripts and cost a full-text pass
    /// per keystroke.
    static let minimumQuery = 3
    static let limit = 6

    /// Full-text hits for `query`, then "Search Archive for …" to take
    /// the query into the archive window.
    @MainActor
    static func items(query: String, hits: [ArchiveSearchResult],
                      verbs: ArchivePaletteVerbs) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumQuery else { return [] }
        var items = hits.prefix(limit).map { hit in
            let record = hit.record
            var actions = [PaletteAction(id: "open", title: "Open in Archive", symbol: "archivebox") {
                verbs.openRecord(record, trimmed)
                return nil
            }]
            if let session = verbs.sessionFor(record) {
                actions.append(PaletteAction(id: "session", title: "Open Session", symbol: "macwindow") {
                    verbs.openSession(session)
                    return nil
                })
            }
            actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", symbol: "folder",
                                         shortcut: .commandShift("f")) {
                NSWorkspace.shared.selectFile(record.sourcePath, inFileViewerRootedAtPath: "")
                return nil
            })
            actions.append(PaletteAction(id: "copyPath", title: "Copy Path", symbol: "doc.on.doc",
                                         shortcut: .commandShift("c")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.sourcePath, forType: .string)
                return "Copied the transcript's path"
            })
            var tags: [PaletteTag] = []
            if let date = record.lastActivityAt ?? record.startedAt {
                tags.append(PaletteTag(text: date.formatted(.relative(presentation: .named))))
            }
            return PaletteItem(
                id: "archive.\(record.id)", title: title(of: record),
                subtitle: hit.snippets.first.map(snippet) ?? record.project,
                icon: record.provider.map { PaletteIcon.provider($0) } ?? .symbol("doc.text", .gray),
                tags: tags, kind: "Archive", section: .archive, actions: actions)
        }
        items.append(PaletteItem(
            id: "archive.search", title: "Search Archive for “\(trimmed)”",
            subtitle: "Every captured transcript, full text",
            icon: .symbol("archivebox.fill", .brown), kind: "Archive", section: .archive,
            actions: [PaletteAction(id: "search", title: "Search Archive", symbol: "magnifyingglass") {
                verbs.search(trimmed)
                return nil
            }]))
        return items
    }

    static func title(of record: ArchiveRecord) -> String {
        if let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return String(title.prefix(80))
        }
        return record.name
    }

    /// A search snippet as one quiet line: the «highlight» marks the
    /// archive view draws are dropped, whitespace folds, and the line
    /// stops at a readable length.
    static func snippet(_ raw: String) -> String {
        let plain = raw.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
        let folded = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.count > 96 ? String(folded.prefix(95)) + "…" : folded
    }
}

// MARK: - Open (windows) and Settings

/// The windows the palette can raise.
struct PaletteWindowVerbs {
    var overview: @MainActor () -> Void
    var usageCenter: @MainActor () -> Void
    var history: @MainActor () -> Void
    var effects: @MainActor () -> Void
    var deck: @MainActor () -> Void
    var replay: @MainActor () -> Void
    var archive: (@MainActor () -> Void)?
    var panel: @MainActor () -> Void
    var checkForUpdates: @MainActor () -> Void
    var settings: @MainActor (SettingsStore.Page) -> Void
}

enum WindowPaletteRows {
    @MainActor
    static func items(verbs: PaletteWindowVerbs) -> [PaletteItem] {
        // A window JR-Bar's own menu already has a chord for shows it,
        // and the chord works from the palette too.
        func window(_ id: String, _ title: String, _ subtitle: String?, _ symbol: String, _ tint: PaletteTint,
                    keywords: [String] = [], chord: PaletteShortcut? = nil,
                    run: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "open.\(id)", title: title, subtitle: subtitle, keywords: keywords,
                        icon: .symbol(symbol, tint),
                        tags: chord.map { [PaletteTag(text: $0.display)] } ?? [],
                        kind: "Window", section: .open,
                        actions: [PaletteAction(id: "open", title: "Open", symbol: "macwindow") {
                            run()
                            return nil
                        }])
        }
        var items = [
            window("panel", "JR-Bar Panel", "Sessions, asks and the lights at a glance",
                   "menubar.dock.rectangle", .blue, keywords: ["dropdown", "menu"], run: verbs.panel),
            window("overview", "Overview", "Every session, scoped and searchable",
                   "square.grid.2x2.fill", .indigo, keywords: ["roster", "sessions"], chord: .command("o"),
                   run: verbs.overview),
            window("usage", "Usage Center", "Quotas, pace and history for every provider",
                   "chart.bar.fill", .green, keywords: ["quota", "limits", "cost"], chord: .command("u"),
                   run: verbs.usageCenter),
            window("history", "History", "What your agents did, newest first",
                   "clock.arrow.circlepath", .orange, keywords: ["log", "events"], chord: .command("y"),
                   run: verbs.history),
            window("effects", "Effect Studio", "Light effects, scenes and assignments",
                   "wand.and.stars", .pink, keywords: ["leds", "animations", "lights"], run: verbs.effects),
            window("deck", "Control Center", "Creator Micro 2 keys and the Rail",
                   "keyboard.fill", .purple, keywords: ["deck", "creator micro", "rail", "keys"], run: verbs.deck),
            window("replay", "Event Replay", "The journaled events, read-only",
                   "play.rectangle.fill", .teal, keywords: ["events", "journal"], run: verbs.replay),
        ]
        if let archive = verbs.archive {
            items.append(window("archive", "Data Hoarder Archive", "Captured transcripts, full text",
                                "archivebox.fill", .brown, keywords: ["transcripts", "search"], run: archive))
        }
        items.append(PaletteItem(
            id: "open.updates", title: "Check for Updates…", icon: .symbol("arrow.down.circle.fill", .blue),
            kind: "Command", section: .open,
            actions: [PaletteAction(id: "check", title: "Check", symbol: "arrow.down.circle") {
                verbs.checkForUpdates()
                return nil
            }]))
        return items
    }

    /// One row per Settings page, with the words people search for.
    @MainActor
    static func settingsItems(open: @escaping @MainActor (SettingsStore.Page) -> Void) -> [PaletteItem] {
        SettingsStore.Page.allCases.map { page in
            PaletteItem(
                id: "settings.\(page.rawValue)", title: "\(page.title) Settings",
                keywords: settingsKeywords(page) + ["preferences"],
                icon: .symbol(page.symbol, settingsTint(page)),
                tags: page == .general ? [PaletteTag(text: PaletteShortcut.command(",").display)] : [],
                kind: "Settings", section: .settings,
                actions: [PaletteAction(id: "open", title: "Open Settings", symbol: "gearshape") {
                    open(page)
                    return nil
                }])
        }
    }

    static func settingsKeywords(_ page: SettingsStore.Page) -> [String] {
        switch page {
        case .general: return ["hotkey", "login", "updates", "icon", "menu bar icon"]
        case .agents: return ["hooks", "providers", "claude", "codex"]
        case .usage: return ["quota", "graphs", "providers", "accounts"]
        case .devices: return ["screen bar", "sidepulse", "leds", "strip", "dot", "calibrate"]
        case .utilities: return ["menu bar", "dock", "data hoarder", "hide icons"]
        case .lighting: return ["colours", "colors", "scenes", "effects"]
        case .toys: return ["notch", "fold", "aquarium", "confetti", "buddy"]
        case .notifications: return ["focus", "banners", "sounds", "escalation", "quiet hours"]
        case .remote: return ["peers", "mirror", "network", "other mac"]
        case .advanced: return ["debug", "reset", "logs", "diagnostics"]
        }
    }

    static func settingsTint(_ page: SettingsStore.Page) -> PaletteTint {
        switch page {
        case .general, .advanced: return .gray
        case .agents: return .blue
        case .usage: return .green
        case .devices: return .orange
        case .utilities: return .indigo
        case .lighting, .toys: return .pink
        case .notifications: return .red
        case .remote: return .teal
        }
    }
}
