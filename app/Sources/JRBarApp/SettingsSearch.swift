import Foundation
import JRBarCore

/// Settings › search: one entry per titled row, so "lid closed" or
/// "alert burst" lands on the right page without knowing where it lives.
/// Raycast's ⌘F over every setting, for JR-Bar's pages.
///
/// Pages build their controls when shown. The catalogue home test renders
/// those destinations. Toy, utility and shortcut rows come from their own
/// catalogues at search time.
struct SettingsSearchEntry: Hashable, Identifiable, Sendable {
    /// The chapter the row sits in (the area Settings once listed as a page).
    let chapter: SettingsStore.Chapter
    let group: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    /// The toy or utility card the row lives in (its toy id): picking
    /// the hit opens that card, scrolls to it and lights it.
    let card: String?
    /// When the row is only drawn under a condition: what makes it appear,
    /// said under the hit, so a search never lands on a page where the row
    /// is simply not there.
    let hint: String?

    /// The page that holds the chapter.
    var page: SettingsStore.Page { chapter.page }

    var id: String { "\(chapter.rawValue)/\(group)/\(title)" }

    init(_ chapter: SettingsStore.Chapter, _ group: String, _ title: String,
         subtitle: String? = nil, keywords: [String] = [], card: String? = nil, hint: String? = nil) {
        self.hint = hint
        self.chapter = chapter
        self.group = group
        self.title = title
        self.subtitle = subtitle
        let mixRow = group == "Mix" || title == "Mix" || title == "Mix mode"
        self.keywords = mixRow && !keywords.contains("blend") ? keywords + ["blend"] : keywords
        self.card = card
    }
}

enum SettingsSearch {
    /// The daemon pages' titled rows, by page and group.
    nonisolated static let rows: [SettingsSearchEntry] = listed.compactMap(currentEntry).map(withHint)

    /// What makes a conditional row appear, by page, group and title.
    /// A row not named here is always drawn.
    nonisolated static let hints: [String: String] = {
        let device = "Shown when the monitor has reported hardware device settings."
        var map: [String: String] = [
            "devices/Screen Bar/Corner radius": "Shown when Notch shape is Custom.",
            "devices/Pro & Dot/The Dot sits": "Shown when Look continues the strip into the Dot.",
            "devices/Creator Micro/Details": "Shown once the Creator Micro is connected.",
            "devices/Creator Micro/Layers": "Shown once the Creator Micro is connected.",
            "devices/Devices/Eject guard": "Shown for a SidePulse Pro once it is connected.",
            "devices/Firmware/Firmware": "Shown once a SidePulse is connected.",
            "devices/Firmware/Review update…": "Shown when a connected SidePulse has an available update.",
            "devices/Firmware/Check firmware": "Shown once a SidePulse is connected.",
            "devices/Devices/Travel": "Shown for a Dot once it is connected.",
            "lighting/Auto-dim/Between": "Shown when Auto-dim is set to Schedule.",
            "lighting/Auto-dim/Dim to": "Shown when Auto-dim is set to Schedule.",
            "lighting/Auto-dim/Never below": "Shown when Auto-dim follows the display or the room.",
            "lighting/Auto-dim/Dark below": "Shown when Auto-dim follows the room.",
            "lighting/Auto-dim/Bright above": "Shown when Auto-dim follows the room.",
            "lighting/Auto-dim/Marks from room": "Shown when Auto-dim follows the room.",
            "lighting/Auto-dim/Right now": "Shown while Auto-dim is on.",
            "notifications/Quiet hours/Dim to": "Used when While quiet is set to Dim.",
            "lighting/Auto-dim/Learned from you": "Shown when Auto-dim follows the room.",
        ]
        for title in ["Display", "Brightness", "Auto-brightness", "Pin to", "Asks only", "Colour calibration",
                      "Strip direction"] {
            map["devices/Devices/\(title)"] = device
        }
        var normalized: [String: String] = [:]
        for (key, hint) in map {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard let original = listed.first(where: { $0.chapter.rawValue == parts[0] && $0.group == parts[1] && $0.title == parts[2] }),
                  let moved = currentEntry(original) else { continue }
            normalized["\(moved.chapter.rawValue)/\(moved.group)/\(moved.title)"] = hint
        }
        return normalized
    }()

    private nonisolated static func currentEntry(_ entry: SettingsSearchEntry) -> SettingsSearchEntry? {
        // Lighting and animation controls moved into Studio.
        let studioDeviceRows: Set<String> = ["Display", "Pin to", "Asks only", "Mix", "Role", "Also glow for finished runs", "Look", "Mirror hardware strip", "Phase nudge", "Minimum glow", "Hold still on camera"]
        if entry.group == "Calibration profiles" || (entry.chapter == .lighting && entry.title != "Maximum brightness") || (entry.chapter == .devices && studioDeviceRows.contains(entry.title)) {
            return SettingsSearchEntry(.lighting, entry.group, entry.title, subtitle: entry.subtitle,
                                       keywords: entry.keywords, card: entry.card, hint: entry.hint)
        }
        if entry.title == "Maximum brightness" {
            return SettingsSearchEntry(.devices, "Brightness", entry.title, keywords: entry.keywords)
        }
        if ["Providers in the icon", "Show meters for", "Remove Hooks"].contains(entry.title) { return nil }
        var chapter = entry.chapter
        var group = entry.group
        if ["Watch transcripts", "Mic and camera presence", "Keep history", "Keep for", "Provider status pages", "Check for agent updates"].contains(entry.title) { chapter = .privacy }
        if entry.chapter == .general && ["Setup", "Release channel"].contains(entry.group) { chapter = .advanced }
        if entry.group == "Power" { chapter = .utilities; group = "Keep Awake" }
        if entry.title == "T3 Code" { chapter = .integrations; group = "Connections" }
        if ["Provider status pages", "Check for agent updates"].contains(entry.title) { group = "Network requests" }
        if entry.title == "Usage Center" { group = "Usage" }
        if entry.title == "Lead with" || entry.title == "Graph range" { group = "Usage" }
        return SettingsSearchEntry(chapter, group, entry.title, subtitle: entry.subtitle,
                                   keywords: entry.keywords, card: entry.card ?? (group == "Keep Awake" ? "keepAwake" : nil), hint: entry.hint)
    }

    private nonisolated static func withHint(_ entry: SettingsSearchEntry) -> SettingsSearchEntry {
        guard entry.hint == nil, let hint = hints["\(entry.chapter.rawValue)/\(entry.group)/\(entry.title)"] else { return entry }
        return SettingsSearchEntry(entry.chapter, entry.group, entry.title, subtitle: entry.subtitle,
                                   keywords: entry.keywords, card: entry.card, hint: hint)
    }

    /// The line under a hit on its page: where the row is, and when it
    /// shows if it only does sometimes.
    nonisolated static func banner(for entry: SettingsSearchEntry) -> String {
        let place = entry.group.isEmpty || entry.group == entry.title
            ? "“\(entry.title)” is on this page."
            : "“\(entry.title)” is under \(entry.group)."
        return entry.hint.map { place + " " + $0 } ?? place
    }

    private nonisolated static let listed: [SettingsSearchEntry] = [
        .init(.integrations, "Connections", "SidePulse Pro", keywords: ["connected", "firmware"]),
        .init(.integrations, "Connections", "PulseDot", keywords: ["connected", "firmware"]),
        .init(.integrations, "Connections", "Stream Deck", keywords: ["serving", "endpoint"]),
        .init(.integrations, "Connections", "Creator Micro 2", keywords: ["connected"]),
        .init(.integrations, "Connections", "Provider hooks"),
        .init(.integrations, "Compatible apps", "Alcove", keywords: ["installed", "notch"]),
        .init(.integrations, "Compatible apps", "Boring Notch", keywords: ["installed", "notch"]),
        .init(.integrations, "Compatible apps", "Bartender", keywords: ["installed", "menu bar"]),
        .init(.integrations, "Compatible apps", "Ice", keywords: ["installed", "menu bar"]),
        .init(.integrations, "Compatible apps", "Hidden Bar", keywords: ["installed", "menu bar"]),
        .init(.integrations, "System access", "Focus Status", keywords: ["permission"]),
        .init(.integrations, "System access", "Calendar", keywords: ["permission"]),
        .init(.integrations, "System access", "Reminders", keywords: ["permission"]),
        .init(.general, "Startup", "Launch at login"),
        .init(.agents, "Providers", "Track"),
        .init(.agents, "Providers", "Menu bar", keywords: ["menu bar meters", "meter", "icon"]),
        .init(.agents, "Providers", "Panel"),
        .init(.agents, "Providers", "Remove integration", keywords: ["remove hooks", "uninstall", "delete", "hook"], hint: "Open a provider's settings."),
        .init(.usage, "Usage", "Token history"),
        .init(.devices, "", "Open Studio", keywords: ["lighting", "colors", "animations", "blend", "colour calibration", "color calibration", "calibration", "dot role", "maximum brightness"]),
        .init(.general, "Setup", "Setup", subtitle: "The first-run walkthrough: agents, permissions, menu bar."),
        .init(.general, "Software Update", "Version"),
        .init(.general, "Software Update", "Automatically check for updates"),
        .init(.general, "Release channel", "Update channel", subtitle: "Stable or beta builds. Kept on this Mac."),
        .init(.general, "Menu bar", "Menu bar icon", subtitle: "What the status item shows."),
        .init(.general, "Menu bar", "Providers in the icon",
              keywords: ["provider order", "reorder", "hide provider", "show provider"]),
        .init(.agents, "Transcripts", "Watch transcripts", subtitle: "Agents whose transcripts are read."),
        .init(.usage, ProviderUsageSwitchesGroup.title, ProviderUsageSwitchesGroup.title,
              subtitle: "Choose which providers show usage. Connect a Factory browser session in its provider row.",
              keywords: ["factory", "droid", "browser", "sign in", "api key", "credentials", "subscription", "billing"],
              hint: "Provider controls load when the monitor is connected."),
        .init(.agents, "Asks", "Sub-agent asks", subtitle: SubagentAsksCopy.subtitle),
        .init(.agents, "Ask lifetime", "May be stale after", subtitle: AskLifetimeCopy.staleSubtitle,
              keywords: ["ask", "old", "stale", "hours"]),
        .init(.agents, "Ask lifetime", "Expire unanswered after", subtitle: AskLifetimeCopy.expireSubtitle,
              keywords: ["ask", "archive", "history", "days"]),
        .init(.agents, "Asks", "Try an ask", subtitle: "A demo ask with Approve and Deny that answer nothing, so you can see where asks appear.",
              keywords: ["demo", "try it", "sample", "example", "fake", "test ask"]),
        .init(.agents, "Providers", "Install Hooks", subtitle: "Each agent's … menu: install, reinstall or remove the hooks that let it report its sessions.",
              keywords: ["repair", "reinstall", "hook", "claude", "codex", "gemini", "setup"]),
        .init(.agents, "Providers", "Remove Hooks", subtitle: "Takes JR-Bar's hooks out of that agent's config and leaves yours alone.",
              keywords: ["uninstall", "delete", "hook"]),
        .init(.agents, "Providers", "Clicks Open", subtitle: "What a click on that agent's session opens: its app, Terminal or VS Code.",
              keywords: ["open session", "terminal", "vscode", "app", "click"]),
        .init(.agents, "Providers", "T3 Code", subtitle: "Found automatically. JR-Bar reads its sessions only while T3 Code runs.",
              keywords: ["t3", "t3 code", "integration", "database"]),
        .init(.usage, "Menu bar meters", "Show meters for", subtitle: "Providers that get a meter in Meters-style menu-bar icons.",
              keywords: ["menu bar meters", "menu bar", "meter", "icon"]),
        .init(.usage, "Display", "Lead with"),
        .init(.usage, "Display", "Graph range"),
        .init(.usage, "Usage", "Run-out time", keywords: ["forecast", "time left", "clock"]),
        .init(.usage, "Usage", "Graph providers"),
        .init(.usage, "Usage Center", "Usage Center", subtitle: "See provider history, token counts, cost and pace.",
              keywords: ["graphs", "dashboard", "history", "tokens", "cost", "pace"]),
        .init(.usage, "Claude", "Read plan limits", subtitle: "Reads your subscription's official 5-hour and 7-day windows from Anthropic. Off until you opt in."),
        .init(.usage, "Quota alerts", "Alert at thresholds", subtitle: "A nudge, then a warning, as a usage window fills."),
        .init(.usage, "Quota alerts", "Thresholds", subtitle: "The two percentages where the nudge and the warning fire.",
              keywords: ["nudge", "warn", "percent"]),
        .init(.usage, "Incidents", "Provider status pages", subtitle: ProviderStatusPagesCopy.subtitle,
              keywords: ["incident", "outage", "status page", "statuspage", "anthropic", "openai", "cursor", "network"]),
        .init(.agents, "Updates", "Check for agent updates", subtitle: ProviderUpdateChecksCopy.subtitle,
              keywords: ["update", "upgrade", "version", "available", "npm", "registry", "network"]),
        .init(.usage, "Claude Code status line", "Show JR-Bar's line", subtitle: "Puts JR-Bar's own line in Claude Code's status line.",
              keywords: ["statusline", "status line", "claude code", "text"]),
        .init(.usage, "Claude Code status line", "Read Claude Code's status line",
              subtitle: "Claude Code reports your 5-hour and weekly limits after each reply.",
              keywords: ["statusline", "status line", "claude code", "rate limits", "ccusage"]),
        .init(.usage, "Hooks", "Run usage hooks", subtitle: "Runs your own program when a quota runs low, runs out, resets or a provider stops answering.",
              keywords: ["hook", "script", "webhook", "automation", "codexbar", "notify"]),
        .init(.usage, "History", "Keep history", subtitle: "Stores usage samples locally so graphs can look back."),
        .init(.usage, "History", "Keep for"),
        .init(.devices, "Pro & Dot", "Role", subtitle: "What the linked Dot is for: extend the strip, or be a beacon.",
              keywords: ["dot role", "beacon", "extend", "mirror"]),
        .init(.devices, "Pro & Dot", "Also glow for finished runs", subtitle: "The beacon adds a slow green breath for a completion nobody has looked at yet.",
              keywords: ["dot", "beacon", "completion", "finished"]),
        .init(.devices, "Pro & Dot", "Dot follows strip", subtitle: "The Dot takes its light from the Pro instead of rendering its own; the Dot's role says how."),
        .init(.devices, "Pro & Dot", "Dot brightness", subtitle: "Two nearby LEDs read much brighter than eight across a desk. The alert beacon is never dimmed."),
        .init(.devices, "Pro & Dot", "Match the strip's brightness", subtitle: "The Dot follows the strip's brightness, dimmed by Dot brightness above, and ignores its own auto-brightness."),
        .init(.devices, "Pro & Dot", "Look", subtitle: "Light that runs off the end of the strip into the Dot, or the strip's eight LEDs folded into the Dot's two."),
        .init(.devices, "Pro & Dot", "The Dot sits", subtitle: "Which side of the strip, as you face them. The light runs on from that end."),
        .init(.devices, "Pro & Dot", "Timing trim", subtitle: "Nudges the Dot if the two still read apart; plus runs it ahead."),
        .init(.devices, "Pro & Dot", "Keep in step", subtitle: "Times the Dot for its own clock and re-syncs it before it drifts. Off, it only starts on the beat."),
        .init(.devices, "Pro & Dot", "Sync tolerance", subtitle: "How far the Dot may drift before it is re-synced. Wider means fewer Dot rewrites."),
        .init(.devices, "Pro & Dot", "Check sync", subtitle: "Both flash white every 2 seconds for a minute. In step, they read as one flash."),
        .init(.devices, "Devices", "Eject guard", subtitle: "Keeps macOS from ejecting the SidePulse when the Mac wakes locked. Protect this SidePulse sets it up for the one plugged in; Stop protecting undoes it."),
        .init(.devices, "Devices", "Use this device"),
        .init(.devices, "Devices", "Display"),
        .init(.devices, "Devices", "Brightness"),
        .init(.devices, "Devices", "Auto-brightness", subtitle: "Follows the display's brightness: dim in a dark room, bright in daylight."),
        .init(.devices, "Devices", "Pin to", subtitle: "Shows only that provider's sessions; rests dark otherwise."),
        .init(.devices, "Devices", "Asks only", subtitle: "Mutes courtesy signals; agent status, asks and low battery still show."),
        .init(.devices, "Devices", "Colour calibration"),
        .init(.devices, "Devices", "Strip direction", subtitle: "Which way round the strip is mounted; reversed mirrors every light.",
              keywords: ["reverse", "flip", "mirror", "led 0", "upside down"]),
        .init(.devices, "Devices", "Travel", subtitle: "How a moving light plays on the Dot's two LEDs: a wipe or a crossfade.",
              keywords: ["dot", "wipe", "crossfade"]),
        .init(.devices, "Firmware", "Firmware", subtitle: "Which firmware each SidePulse runs, and whether a newer one is on offer.",
              keywords: ["update firmware", "version", "ota", "upgrade", "sidepulse", "pro", "dot", "release notes"]),
        .init(.devices, "Firmware", "Review update…", subtitle: "Opens a confirmation first. Nothing is downloaded until you confirm.",
              keywords: ["update firmware", "upgrade", "install", "flash", "download", "ota"]),
        .init(.devices, "Firmware", "Check firmware", subtitle: "Reads the device's firmware version again. Makes no network request.",
              keywords: ["firmware", "refresh", "recheck"]),
        .init(.devices, "Creator Micro", "Enable Creator Micro", subtitle: "The monitor drives the approved pad's per-key colours and listens to its inputs."),
        .init(.devices, "Creator Micro", "Session keys", subtitle: "The thirteen keys follow the session board; only the dial, joystick and analog sectors take explicit mappings."),
        .init(.devices, "Creator Micro", "Analog joystick sectors", subtitle: "Sectors 1–4 (AG20–AG23) count as inputs and can carry mappings in Creator Micro."),
        .init(.devices, "Creator Micro", "Details"),
        .init(.devices, "Creator Micro", "Layers", subtitle: "Who each hardware layer belongs to. Layer 1 is always JR-Bar's; a layer handed to Codex, Claude or other apps is left to that writer instead of fought over."),
        .init(.devices, "Creator Micro", "Creator Micro", subtitle: "Pins, banks, the rail, input check and the keymap.",
              keywords: ["creator micro", "keymap", "pad", "window"]),
        .init(.devices, "Screen Bar", "Display", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Brightness", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Auto-brightness", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Pin to", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Asks only", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Mix", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Colour calibration", keywords: ["screen bar"],
              hint: "Shown when the monitor has reported Screen Bar device settings."),
        .init(.devices, "Screen Bar", "Show Screen Bar", subtitle: "The light band under the notch."),
        .init(.devices, "Screen Bar", "Follow Alcove", subtitle: "Match Alcove's capsule width so a live activity never outgrows the band."),
        .init(.devices, "Screen Bar", "In full screen", subtitle: "Hidden, shown but not over video, or always over full-screen apps."),
        .init(.devices, "Screen Bar", "Hide over these apps", subtitle: "The band steps aside while a listed app is in front.",
              keywords: ["exclude", "presentation", "keynote", "per app"]),
        .init(.devices, "Screen Bar", "Notch wings", subtitle: "Status slots beside the notch: sessions on the left, the headline meter on the right."),
        .init(.devices, "Screen Bar", "Notch shape"),
        .init(.devices, "Screen Bar", "Corner radius", subtitle: "The tray's bottom corners, in points. Every notched MacBook measures about 8."),
        .init(.devices, "Screen Bar", "Mirror hardware strip", subtitle: "Play the strip's program on its clock; off, the bar renders its own display."),
        .init(.devices, "Screen Bar", "Advanced", subtitle: "Phase, geometry and the band's dim floor."),
        .init(.devices, "Screen Bar", "Hold still on camera", subtitle: "Keeps the band still while the camera is in use.",
              keywords: ["camera", "video", "call", "motion"]),
        .init(.devices, "Screen Bar", "Gap width", subtitle: "How wide the band's gap at the notch is.",
              keywords: ["geometry", "notch"]),
        .init(.devices, "Screen Bar", "Wing length", subtitle: "How far the band's wings run beside the notch.",
              keywords: ["geometry", "notch"]),
        .init(.devices, "Screen Bar", "Phase nudge", subtitle: "Shift the bar against the strip if the two are visibly out of step. Positive holds the bar back."),
        .init(.devices, "Screen Bar", "Minimum glow", subtitle: "The band's dim floor; zero is pitch black."),
        .init(.lighting, "Provider colours", "Provider colours", subtitle: "Each provider's colour, beside its working light.",
              keywords: ["accent", "color", "swatch", "hue"]),
        .init(.lighting, "State colours", "State colours", subtitle: "The colour of idle, working, done, ask and error.",
              keywords: ["idle", "working", "done", "ask", "error", "mode colours", "swatch"]),
        .init(.lighting, "Mix", "Mix mode"),
        .init(.lighting, "Mix", "Cycle speed", subtitle: "One cycle, in seconds. An agent given its own motion in Studio keeps its own tempo."),
        .init(.lighting, "Mix", "Celebrate completions", subtitle: "A flourish when a session settles into Done."),
        .init(.lighting, "Mix", "Celebration preview", subtitle: "The finish the strip plays, once, when a session is done."),
        .init(.lighting, "Mix", "Finish", subtitle: "Bloom, Land or Ripple: how a finished session is celebrated.",
              keywords: ["celebration", "done", "land", "ripple", "bloom"]),
        .init(.lighting, "Mix", "Tint by tool", subtitle: "The working light's head takes the colour of the tool the agent is using.",
              keywords: ["tool", "tint", "shell", "edit"]),
        .init(.lighting, "Pulse range", "Fine-tune pulsing", subtitle: "Floor and ceiling of each pulsing mode's brightness."),
        .init(.lighting, "Dimming", "Maximum brightness", subtitle: "Caps every light JR-Bar drives.",
              keywords: ["brightness", "cap", "global", "dim", "limit"]),
        .init(.lighting, "Dimming", "Dim when idle"),
        .init(.lighting, "Dimming", "After"),
        .init(.lighting, "Dimming", "Idle brightness"),
        .init(.lighting, "Dimming", "Dim on display sleep"),
        .init(.lighting, "Dimming", "Sleep brightness"),
        .init(.lighting, "Dimming", "Turn off when idle", subtitle: "After a long idle the lights switch off entirely."),
        .init(.lighting, "Dimming", "Off after"),
        .init(.lighting, "Scene", "Active scene", subtitle: "Which scene's effect assignments are in force."),
        .init(.lighting, "Provider colours and animations", "Studio"),
        .init(.lighting, "Ambient cues", "Scene pack", subtitle: "An installed Scene pack whose policy rows override the built-in scene's.",
              keywords: ["pack", "scene", "policy"]),
        .init(.lighting, "Ambient cues", "Also at night", subtitle: "Keeps the Rainstick drifting at night too.",
              keywords: ["rainstick", "night"]),
        .init(.lighting, "Ambient cues", "Milestones", subtitle: "The completion counts that trigger the milestone cue.",
              keywords: ["odometer", "steps", "count"]),
        .init(.lighting, "Ambient cues", "Rainstick idle", subtitle: "A dim pixel drifts along the strip every thirty seconds while nothing else needs it."),
        .init(.lighting, "Ambient cues", "Completion milestones", subtitle: "A short celebration when finished sessions cross a milestone."),
        .init(.lighting, "Auto-dim", "Between", subtitle: "A start after the end wraps midnight."),
        .init(.lighting, "Auto-dim", "Dim to"),
        .init(.lighting, "Auto-dim", "Never below", subtitle: "The floor under the display's brightness."),
        .init(.lighting, "Auto-dim", "Dark below", subtitle: "Full floor at this reading."),
        .init(.lighting, "Auto-dim", "Bright above", subtitle: "Full brightness at this reading; must be above the dark mark."),
        .init(.lighting, "Auto-dim", "Marks from room", subtitle: "Dark below a quarter of the live lux, bright above 1.6 times it."),
        .init(.lighting, "Auto-dim", "Right now"),
        .init(.lighting, "Auto-dim", "Learned from you", subtitle: "What Auto-dim has learned from the brightness you set by hand.",
              keywords: ["learning", "manual", "adjust"]),
        .init(.notifications, "Alerts", "Alerts profile", subtitle: "Quiet, Balanced or Loud: the finish banner, the quota alerts and how far an ignored ask escalates, set together."),
        .init(.notifications, "Completion", "Notification banner", subtitle: "A macOS banner when a main session finishes; needs the system notification permission."),
        .init(.notifications, "Completion", "Completion sweep", subtitle: "Sweeps the bar in the finishing agent's colour when a session completes."),
        .init(.notifications, "Silent sessions", "Banner when a session goes quiet", subtitle: "One banner for each quiet stretch, a local notification only. Off unless you turn it on; the Loud profile does."),
        .init(.notifications, "Escalation", "Loudest stage", subtitle: "How far an ignored ask may escalate."),
        .init(.notifications, "Escalation", "Ramp after"),
        .init(.notifications, "Escalation", "Menu bar after"),
        .init(.notifications, "Escalation", "Final stage after"),
        .init(.notifications, "Escalation", "Per provider", subtitle: "Hold one agent's asks lower than the stage above.",
              keywords: ["claude", "codex", "tier", "escalation"]),
        .init(.notifications, "Escalation", "Alert burst", subtitle: "Repetitions a courtesy signal gets before it settles; critical signals ignore this."),
        .init(.notifications, "Quiet hours", "Schedule", subtitle: "The lights quiet down between the hours below."),
        .init(.notifications, "Quiet hours", "From"),
        .init(.notifications, "Quiet hours", "While quiet"),
        .init(.notifications, "Quiet hours", "Dim to"),
        .init(.notifications, "Calendar & reminders", "Glow before events", subtitle: "The lights glow shortly before a calendar event starts.",
              keywords: ["calendar", "meeting", "event"]),
        .init(.notifications, "Calendar & reminders", "Lead time", subtitle: "How long before an event the glow starts.",
              keywords: ["calendar", "minutes"], hint: "Shown when Glow before events is on."),
        .init(.notifications, "Calendar & reminders", "Glow for due reminders", subtitle: "The lights glow when a reminder falls due.",
              keywords: ["reminders", "due"]),
        .init(.notifications, "Presence", "Mic and camera presence"),
        .init(.notifications, "Focus", "React to Focus modes", subtitle: "Focus Status reads whether Focus is on. Full Disk Access adds named-mode rules."),
        .init(.notifications, "Focus", "In Do Not Disturb"),
        .init(.general, "Power", "Keep Mac awake", subtitle: "While agents run, the Mac never idles to sleep."),
        .init(.general, "Power", "Keep display awake", subtitle: "While agents run, the screen stays on too — so it never locks mid-run. Off lets the display sleep while the Mac stays up."),
        .init(.general, "Power", "Lid closed"),
        .init(.utilities, "Keep Awake", "Closed-lid grace", card: "keepAwake"),
        .init(.general, "Power", "Keep awake on battery", subtitle: "Off releases the hold whenever the Mac is unplugged."),
        .init(.notifications, "Battery", "Low battery alert", subtitle: "Every surface switches to the slow red breathe until power returns."),
        .init(.notifications, "Battery", "Below"),
        .init(.notifications, "Battery", "Or with less left than", subtitle: "Also alerts when the battery has less time than this left.",
              keywords: ["minutes", "time remaining"]),
        .init(.notifications, "Battery", "Charging fill when idle", subtitle: "While charging and idle, the lights fill to show the charge.",
              keywords: ["charging", "power"]),
        .init(.notifications, "Battery", "Show power changes", subtitle: "A short preview when the Mac is plugged in or unplugged.",
              keywords: ["charger", "plug", "unplug"]),
        .init(.remote, "Peers", "Remote peers", subtitle: "Discover other Macs running JR-Bar and show their agents here."),
        .init(.remote, "Peers", "Publish this Mac", subtitle: "Lets peers read this desk's sessions."),
        .init(.remote, "Peers", "Muted machines"),
        .init(.remote, "Peers", "Unmuted machines", subtitle: "Machines whose asks still take a light here while remote asks are muted.",
              keywords: ["peers", "machine", "mute"]),
        .init(.remote, "Peers", "Mute remote asks", subtitle: "A peer's asks take no light here until you unmute that machine."),
        .init(.remote, "Local tools", "Share status with local tools", subtitle: "Lets local tools read this Mac's status."),
        .init(.remote, "Local tools", "Access key", subtitle: "Bearer token for local tools."),
        .init(.remote, "Other machines", "Accept events from other machines", subtitle: "Receives agent events from other machines."),
        .init(.remote, "Other machines", "Access key file"),
        .init(.notifications, "Webhook", "Webhook URL", subtitle: "POSTs stage-3 escalations whenever set."),
        .init(.notifications, "Webhook", "Also send", subtitle: "Extra events to post alongside escalations."),
        .init(.notifications, "Phone alert", "ntfy topic", subtitle: "A topic name for ntfy.sh, or the https address of your own ntfy server.",
              keywords: ["phone", "push", "notify", "ntfy"]),
        .init(.notifications, "Phone alert", "Send phone alerts", subtitle: "Off until you turn it on.",
              keywords: ["phone", "push", "notify", "ntfy"]),
        .init(.notifications, "Phone alert", "Only when I'm away", subtitle: "Idle for five minutes, or the screen is locked. If JR-Bar cannot tell, nothing is sent.",
              keywords: ["phone", "idle", "locked", "ntfy"]),
        .init(.notifications, "Phone alert", "Test", subtitle: "Sends one message now, whatever the switches say.",
              keywords: ["phone", "ntfy", "send test message"]),
        .init(.devices, "Stream Deck", "Share status with local tools", subtitle: "The loopback endpoint the deck polls; also on Settings › Remote."),
        .init(.devices, "Stream Deck", "Endpoint"),
        .init(.devices, "Stream Deck", "Status link", subtitle: "Stream Deck reads redacted agent counts here, using the key.", keywords: ["status url"]),
        .init(.sounds, "Volume", "JR-Bar sounds", subtitle: "One volume for every JR-Bar sound.",
              keywords: ["volume", "loudness"]),
        .init(.sounds, "Output", "Play through the alert device", subtitle: "Sounds follow macOS's alert device instead of the current output.",
              keywords: ["airpods", "speakers", "output"]),
        .init(.sounds, "Output", "Quiet while the microphone is live", subtitle: "Holds sounds while another app is using the microphone, such as a call.",
              keywords: ["call", "meeting", "microphone"]),
        .init(.sounds, "Your own sounds", "Sounds folder", subtitle: "Drop a sound file here and it joins the list.",
              keywords: ["custom", "aiff", "wav", "folder"]),
        .init(.shortcuts, "JR-Bar", "Show the panel", subtitle: "The global key that summons the panel.",
              keywords: ["hotkey", "panel hotkey", "chord", "summon"]),
        .init(.shortcuts, "JR-Bar", "Open the shelf", subtitle: "The global key that opens the shelf; a second press folds it.",
              keywords: ["hotkey", "shelf hotkey", "chord", "shelf"]),
        .init(.shortcuts, "Command line", "jrbar in Terminal", subtitle: "Links ~/.local/bin/jrbar to this app's own CLI.",
              keywords: ["cli", "terminal", "path", "install", "command line tool"]),
        .init(.shortcuts, "Links", "Links you stopped asking about",
              subtitle: "You chose \"Don't ask again\" for some links. Ask again makes them check with you every time.",
              keywords: ["jrbar://", "url", "trusted", "ask again", "raycast", "alfred"],
              hint: "Shown once you have chosen Don't ask again for a link."),
        .init(.advanced, "Diagnostics", "State folder", subtitle: "The monitor's data on this Mac."),
        .init(.advanced, "Diagnostics", "Doctor", subtitle: "Checks the monitor's health."),
        .init(.advanced, "Report", "Copy diagnostics", subtitle: "Builds, Doctor, permissions and the log tail as one redacted block.",
              keywords: ["bug", "report", "support", "clipboard"]),
        .init(.advanced, "Transfer", "Export settings", subtitle: "The monitor's settings, devices, Utilities, Toys, shortcuts and sounds, as one JSON file.",
              keywords: ["backup", "export", "migrate", "second mac", "sync"]),
        .init(.advanced, "Transfer", "Import settings", subtitle: "Open an export and choose which parts to take. It never turns on a request that leaves this Mac.",
              keywords: ["restore", "import", "migrate", "second mac"]),
        .init(.devices, "Calibration profiles", "Calibration profiles", subtitle: "Saved brightness and colour calibrations, one per slot, that a Focus can apply.",
              keywords: ["calibration", "day", "night", "travel", "focus", "profile"]),
        .init(.advanced, "Reset to defaults", "Reset to defaults", subtitle: "Puts one page's settings back."),
        .init(.utilities, "Menu Bar", "Search name",
              subtitle: "A local search name for a menu bar item.",
              keywords: ["alias", "rename", "item bar", "find icon"], card: "menuBar"),
        // The Keep Awake card on the Utilities page (lane utilities).
        .init(.utilities, "Keep Awake", "Keep Awake", subtitle: "Keeps this Mac awake for a set time or until agents finish.",
              keywords: ["amphetamine", "caffeine", "caffeinate", "sleep", "awake", "keepingyouawake"], card: "keepAwake"),
        .init(.utilities, "Keep Awake", "Keep the display on", subtitle: "Keeps the display awake during a Keep Awake session.",
              keywords: ["screen saver", "lock"], card: "keepAwake"),
        .init(.utilities, "Keep Awake", "Durations", subtitle: "One-time sessions and saved duration presets.",
              keywords: ["presets", "minutes", "hours", "custom", "one-time"], card: "keepAwake"),
        .init(.utilities, "Keep Awake", "Other apps holding this Mac awake",
              keywords: ["assertions", "amphetamine", "who keeps awake"], card: "keepAwake"),
    ]

    /// Words a person might search that no row title carries, per page —
    /// "sound" finds Notifications, "LED" finds Lighting.
    nonisolated static let pageKeywords: [SettingsStore.Chapter: [String]] = [
        .general: ["login", "startup", "hotkey", "update", "sparkle", "version", "build", "icon", "setup", "permissions",
                   "power", "keep awake", "caffeinate", "lid", "sleep"],
        .agents: ["hooks", "claude", "codex", "gemini", "providers", "transcripts", "install"],
        .usage: ["quota", "limits", "meters", "graphs", "cost", "tokens", "pace"],
        .devices: ["sidepulse", "strip", "dot", "screen bar", "notch", "calibration", "creator micro", "stream deck", "usb"],
        .utilities: ["menu bar", "dock", "hide icons", "bartender", "ice", "switcher",
                     "keep awake", "amphetamine"],
        .lighting: ["colors", "colours", "led", "brightness", "dim", "scene", "effects", "animation"],
        .toys: ["fold", "aquarium", "confetti", "buddy", "fun"],
        .notifications: ["banner", "focus", "do not disturb", "dnd", "quiet", "battery", "escalation",
                         "phone", "ntfy", "webhook", "push"],
        .sounds: ["sound", "chime", "alert", "volume", "airpods", "speaker", "audio", "call", "meeting", "microphone"],
        .shortcuts: ["hotkey", "keyboard", "key", "chord", "links", "url", "jrbar://", "toggles", "raycast", "alfred"],
        .remote: ["peers", "tailscale", "serve", "ingest", "token", "fleet", "other mac", "endpoint"],
        .advanced: ["doctor", "logs", "reset", "diagnostics", "socket", "debug"],
        .notch: ["notch", "shelf", "island", "media", "files"],
        .privacy: ["privacy", "permissions", "transcripts", "history", "consent"],
        .integrations: ["t3", "integration", "compatibility"],
    ]

    /// Every page itself, so a page name or one of its keywords lands
    /// on the page.
    nonisolated static var pages: [SettingsSearchEntry] {
        SettingsStore.Chapter.allCases.map {
            SettingsSearchEntry($0, "", $0.title, keywords: pageKeywords[$0] ?? [])
        }
    }

    /// The shortcut page's catalogue rows: every app action and quick
    /// toggle, with the chip's own search words — and the Sounds page's
    /// moments, built from the same roles the page draws.
    nonisolated static var shortcutRows: [SettingsSearchEntry] {
        AppShortcutCatalog.actions.map { SettingsSearchEntry(.shortcuts, "Actions", $0.title) }
            + SystemToggle.allCases.map {
                SettingsSearchEntry(.shortcuts, "Quick toggles", $0.longTitle, keywords: $0.keywords)
            }
            + SoundRole.allCases.map {
                SettingsSearchEntry(.sounds, "Event sounds", $0.title, subtitle: $0.subtitle,
                                    keywords: [$0.defaultSound])
            }
    }

    /// Case-, accent- and punctuation-blind words.
    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber && $0 != ":" && $0 != "/" }
            .map(String.init)
    }

    /// An entry with its words folded once. A keystroke scores against
    /// these instead of folding every title, group and keyword again.
    struct Indexed: Sendable {
        let entry: SettingsSearchEntry
        let title: [String]
        let place: [String]
        let rest: [String]
        let joinedTitle: String

        init(_ entry: SettingsSearchEntry) {
            self.entry = entry
            title = SettingsSearch.words(entry.title)
            place = SettingsSearch.words(entry.group) + SettingsSearch.words(entry.chapter.title)
                + SettingsSearch.words(entry.page.title)
            rest = SettingsSearch.words(entry.subtitle ?? "") + entry.keywords.flatMap(SettingsSearch.words)
            joinedTitle = title.joined(separator: " ")
        }
    }

    /// How well `entry` answers `query`: every query word must appear
    /// somewhere in it (a word start, or anywhere for three letters or
    /// more); the title counts most, then the group and page, then the
    /// subtitle and keywords. nil when some word matches nothing.
    nonisolated static func score(_ entry: Indexed, query: [String]) -> Int? {
        guard !query.isEmpty else { return nil }
        var total = 0
        for word in query {
            func hit(_ candidates: [String]) -> Bool {
                candidates.contains { $0.hasPrefix(word) || (word.count >= 3 && $0.contains(word)) }
            }
            if hit(entry.title) {
                total += entry.title.first?.hasPrefix(word) == true ? 30 : 20
            } else if hit(entry.place) {
                total += 8
            } else if hit(entry.rest) {
                total += 4
            } else {
                return nil
            }
        }
        // A title that is the whole query outranks one that merely holds it.
        if entry.joinedTitle == query.joined(separator: " ") { total += 40 }
        return total
    }

    /// The best matches for `text`, best first; ties keep page order.
    nonisolated static func search(_ text: String, in entries: [SettingsSearchEntry], limit: Int = 30)
        -> [SettingsSearchEntry] {
        search(text, in: entries.map(Indexed.init), limit: limit)
    }

    nonisolated static func search(_ text: String, in index: [Indexed], limit: Int = 30)
        -> [SettingsSearchEntry] {
        let query = words(text)
        guard !query.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: SettingsStore.Chapter.allCases.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        return index
            .compactMap { indexed in score(indexed, query: query).map { (indexed.entry, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return (order[lhs.0.chapter] ?? 0) < (order[rhs.0.chapter] ?? 0)
            }
            .map(\.0)
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
