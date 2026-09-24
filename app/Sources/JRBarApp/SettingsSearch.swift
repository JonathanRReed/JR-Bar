import Foundation
import JRBarCore

/// Settings › search: one entry per titled row, so "lid closed" or
/// "alert burst" lands on the right page without knowing where it lives.
/// Raycast's ⌘F over every setting, for JR-Bar's pages.
///
/// The rows are listed here rather than discovered: a page builds its
/// rows only when shown, and the daemon's pages are plain SwiftUI. A test
/// holds the list honest — every title here must still be a row title in
/// the app's sources — and the dynamic rows (each toy and utility and
/// the rows inside their cards, each shortcut action and quick toggle)
/// are added at search time from their own catalogues, so they can
/// never go stale.
struct SettingsSearchEntry: Hashable, Identifiable, Sendable {
    let page: SettingsStore.Page
    let group: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    /// The toy or utility card the row lives in (its toy id): picking
    /// the hit opens that card, scrolls to it and lights it.
    let card: String?

    var id: String { "\(page.rawValue)/\(group)/\(title)" }

    init(_ page: SettingsStore.Page, _ group: String, _ title: String,
         subtitle: String? = nil, keywords: [String] = [], card: String? = nil) {
        self.page = page
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.card = card
    }
}

enum SettingsSearch {
    /// The daemon pages' titled rows, by page and group.
    nonisolated static let rows: [SettingsSearchEntry] = [
        .init(.general, "Startup", "Launch at login"),
        .init(.general, "Startup", "Setup", subtitle: "The first-run walkthrough — agents, permissions, menu bar."),
        .init(.general, "Menu bar", "Panel hotkey"),
        .init(.general, "Menu bar", "Shelf hotkey"),
        .init(.general, "Brightness", "Maximum brightness", subtitle: "Caps every light JR-Bar drives."),
        .init(.general, "Software Update", "Version"),
        .init(.general, "Software Update", "Automatically check for updates"),
        .init(.general, "Software Update", "Advanced"),
        .init(.general, "Software Update", "Update channel", subtitle: "Stable or beta builds."),
        .init(.general, "Menu bar", "Menu bar icon", subtitle: "What the status item shows."),
        .init(.agents, "Transcripts", "Watch transcripts", subtitle: "Agents whose transcripts are read."),
        .init(.agents, "Asks", "Sub-agent asks", subtitle: "Sub-agents cannot be answered, so only main sessions alert by default."),
        .init(.usage, "Menu bar meters", "Show meters for", subtitle: "Providers that get a meter in Meters-style menu-bar icons."),
        .init(.usage, "Display", "Lead with"),
        .init(.usage, "Display", "Graph range"),
        .init(.usage, "Display", "Graphs", subtitle: "Per-provider history, cost and pace, for the range above."),
        .init(.usage, "Claude", "Read plan limits", subtitle: "Reads your subscription's official 5-hour and 7-day windows from Anthropic. Off until you opt in."),
        .init(.usage, "Quota alerts", "Alert at thresholds", subtitle: "A nudge, then a warning, as a usage window fills."),
        .init(.usage, "History", "Keep history", subtitle: "Stores usage samples locally so graphs can look back."),
        .init(.usage, "History", "Keep for"),
        .init(.devices, "Pro & Dot", "Dot follows strip", subtitle: "The Dot takes its light from the Pro instead of rendering its own; the role below says how."),
        .init(.devices, "Pro & Dot", "Dot brightness", subtitle: "Two nearby LEDs read much brighter than eight across a desk. The alert beacon is never dimmed."),
        .init(.devices, "Pro & Dot", "Match the strip's brightness", subtitle: "The Dot follows the strip's brightness, dimmed by Dot brightness above, and ignores its own auto-brightness."),
        .init(.devices, "Pro & Dot", "Look", subtitle: "Light that runs off the end of the strip into the Dot, or the strip's eight LEDs folded into the Dot's two."),
        .init(.devices, "Pro & Dot", "The Dot sits", subtitle: "Which end of the strip the Dot carries on from."),
        .init(.devices, "Pro & Dot", "Timing trim", subtitle: "Nudges the Dot if the two still read apart; plus runs it ahead."),
        .init(.devices, "Pro & Dot", "Keep in step", subtitle: "Times the Dot for its own clock and re-syncs it before it drifts. Off, it only starts on the beat."),
        .init(.devices, "Pro & Dot", "Sync tolerance", subtitle: "How far the Dot may drift before it is re-synced. Wider means fewer Dot rewrites."),
        .init(.devices, "Pro & Dot", "Check sync", subtitle: "Both flash white every 2 seconds for a minute. In step, they read as one flash."),
        .init(.devices, "Devices", "Eject guard", subtitle: "Keeps macOS from ejecting the SidePulse when the Mac wakes locked. Protect this SidePulse sets it up for the one plugged in."),
        .init(.devices, "Devices", "Display"),
        .init(.devices, "Devices", "Brightness"),
        .init(.devices, "Devices", "Auto-brightness", subtitle: "Follows the display's brightness: dim in a dark room, bright in daylight."),
        .init(.devices, "Devices", "Pin to", subtitle: "Shows only that provider's sessions; rests dark otherwise."),
        .init(.devices, "Devices", "Asks only", subtitle: "Mutes courtesy signals; agent status, asks and low battery still show."),
        .init(.devices, "Devices", "Colour calibration"),
        .init(.devices, "Creator Micro 2", "Enable Creator Micro 2", subtitle: "The monitor drives the approved pad's per-key colours and listens to its inputs."),
        .init(.devices, "Creator Micro 2", "Session keys", subtitle: "The thirteen keys follow the session board; only the dial, joystick and analog sectors take explicit mappings."),
        .init(.devices, "Creator Micro 2", "Analog joystick sectors", subtitle: "Sectors 1–4 (AG20–AG23) count as inputs and can carry mappings in the Control Center."),
        .init(.devices, "Creator Micro 2", "Details"),
        .init(.devices, "Creator Micro 2", "Layers", subtitle: "Who each hardware layer belongs to. Layer 1 is always JR-Bar's; a layer handed to Codex, Claude or other apps is left to that writer instead of fought over."),
        .init(.devices, "Creator Micro 2", "Control Center", subtitle: "Pins, banks, the rail, input check and the keymap.",
              keywords: ["creator micro", "keymap", "pad", "window"]),
        .init(.devices, "Screen Bar", "Show Screen Bar", subtitle: "The light band under the notch."),
        .init(.devices, "Screen Bar", "Follow Alcove", subtitle: "Match Alcove's capsule width so a live activity never outgrows the band."),
        .init(.devices, "Screen Bar", "In full screen", subtitle: "Hidden, shown but not over video, or always over full-screen apps."),
        .init(.devices, "Screen Bar", "Notch wings", subtitle: "Status slots beside the notch: sessions on the left, the headline meter on the right."),
        .init(.devices, "Screen Bar", "Notch shape"),
        .init(.devices, "Screen Bar", "Corner radius", subtitle: "The tray's bottom corners, in points. Every notched MacBook measures about 8."),
        .init(.devices, "Screen Bar", "Mirror hardware strip", subtitle: "Play the strip's program on its clock; off, the bar renders its own display."),
        .init(.devices, "Screen Bar", "Advanced", subtitle: "Phase, geometry and the band's dim floor."),
        .init(.devices, "Screen Bar", "Phase nudge", subtitle: "Shift the bar against the strip if the two are visibly out of step. Positive holds the bar back."),
        .init(.devices, "Screen Bar", "Minimum glow", subtitle: "The band's dim floor; zero is pitch black."),
        .init(.lighting, "Blend", "Blend mode"),
        .init(.lighting, "Blend", "Cycle speed", subtitle: "One breath, in seconds."),
        .init(.lighting, "Blend", "Celebrate completions", subtitle: "A flourish when a session settles into Done."),
        .init(.lighting, "Blend", "Celebration preview", subtitle: "The ripple, bloom and hold the strip plays."),
        .init(.lighting, "Pulse range", "Fine-tune pulsing", subtitle: "Floor and ceiling of each pulsing mode's brightness."),
        .init(.lighting, "Dimming", "Dim when idle"),
        .init(.lighting, "Dimming", "After"),
        .init(.lighting, "Dimming", "Idle brightness"),
        .init(.lighting, "Dimming", "Dim on display sleep"),
        .init(.lighting, "Dimming", "Sleep brightness"),
        .init(.lighting, "Dimming", "Turn off when idle", subtitle: "After a long idle the lights switch off entirely."),
        .init(.lighting, "Dimming", "Off after"),
        .init(.lighting, "Scene", "Active scene", subtitle: "Which scene's effect assignments are in force."),
        .init(.lighting, "Scene", "Effect Studio", subtitle: "Tune effects live and assign looks to states, scenes, providers and devices."),
        .init(.lighting, "Ambient cues", "Rainstick idle", subtitle: "A dim pixel drifts along the strip every thirty seconds while nothing else needs it."),
        .init(.lighting, "Ambient cues", "Completion milestones", subtitle: "A short celebration when finished sessions cross a milestone."),
        .init(.lighting, "Auto-dim", "Between", subtitle: "A start after the end wraps midnight."),
        .init(.lighting, "Auto-dim", "Dim to"),
        .init(.lighting, "Auto-dim", "Never below", subtitle: "The floor under the display's brightness."),
        .init(.lighting, "Auto-dim", "Dark below", subtitle: "Full floor at this reading."),
        .init(.lighting, "Auto-dim", "Bright above", subtitle: "Full brightness at this reading; must be above the dark mark."),
        .init(.lighting, "Auto-dim", "Marks from room", subtitle: "Dark below a quarter of the live lux, bright above 1.6 times it."),
        .init(.lighting, "Auto-dim", "Right now"),
        .init(.notifications, "Completion", "Notification banner", subtitle: "A macOS banner when a main session finishes; needs the system notification permission."),
        .init(.notifications, "Completion", "Completion sweep", subtitle: "Sweeps the bar in the finishing agent's colour when a session completes."),
        .init(.notifications, "Escalation", "Loudest stage", subtitle: "How far an ignored ask may escalate."),
        .init(.notifications, "Escalation", "Ramp after"),
        .init(.notifications, "Escalation", "Menu bar after"),
        .init(.notifications, "Escalation", "Final stage after"),
        .init(.notifications, "Escalation", "Alert burst", subtitle: "Repetitions a courtesy signal gets before it settles; critical signals ignore this."),
        .init(.notifications, "Quiet hours", "Schedule", subtitle: "The lights quiet down between the hours below."),
        .init(.notifications, "Quiet hours", "From"),
        .init(.notifications, "Quiet hours", "While quiet"),
        .init(.notifications, "Quiet hours", "Dim to"),
        .init(.notifications, "Focus", "React to Focus modes", subtitle: "Reads the active Focus; needs Full Disk Access for this app."),
        .init(.notifications, "Focus", "In Do Not Disturb"),
        .init(.notifications, "Power", "Keep Mac awake", subtitle: "While agents run, the Mac never idles to sleep."),
        .init(.notifications, "Power", "Keep display awake", subtitle: "While agents run, the screen stays on too — so it never locks mid-run. Off lets the display sleep while the Mac stays up."),
        .init(.notifications, "Power", "Lid closed"),
        .init(.notifications, "Power", "Keep awake on battery", subtitle: "Off releases the hold whenever the Mac is unplugged."),
        .init(.notifications, "Battery", "Low battery alert", subtitle: "Every surface switches to the slow red breathe until power returns."),
        .init(.notifications, "Battery", "Below"),
        .init(.remote, "Peers", "Remote peers", subtitle: "Discover other Macs running JR-Bar and show their agents here."),
        .init(.remote, "Peers", "Publish this Mac", subtitle: "Lets peers read this desk's sessions."),
        .init(.remote, "Peers", "Mute remote asks", subtitle: "A peer's asks take no light here until you unmute that machine."),
        .init(.remote, "Serve", "Serve status", subtitle: "Opens a loopback endpoint so local tools can read this desk's status."),
        .init(.remote, "Serve", "Bearer token"),
        .init(.remote, "Cloud ingest", "Cloud ingest", subtitle: "Opens a loopback port so off-machine agents can post their own lifecycle."),
        .init(.remote, "Cloud ingest", "Token file"),
        .init(.remote, "Webhook", "Webhook URL", subtitle: "POSTs stage-3 escalations whenever set."),
        .init(.remote, "Webhook", "Also send", subtitle: "Extra events to post alongside escalations."),
        .init(.devices, "Stream Deck", "Serve status", subtitle: "The loopback endpoint the deck polls; also on Settings › Remote."),
        .init(.devices, "Stream Deck", "Endpoint"),
        .init(.devices, "Stream Deck", "Status URL", subtitle: "GET it with the token as the Authorization: Bearer header; the reply carries redacted agent counts."),
        .init(.shortcuts, "Command line", "jrbar in Terminal", subtitle: "Links ~/.local/bin/jrbar to this app's own CLI.",
              keywords: ["cli", "terminal", "path", "install", "command line tool"]),
        .init(.advanced, "Diagnostics", "State folder", subtitle: "The monitor's data on this Mac."),
        .init(.advanced, "Diagnostics", "Doctor", subtitle: "Checks the monitor's health."),
        .init(.advanced, "Report", "Copy diagnostics", subtitle: "Builds, Doctor, permissions and the log tail as one redacted block.",
              keywords: ["bug", "report", "support", "clipboard"]),
        .init(.advanced, "Transfer", "Export settings", subtitle: "Every preference as one JSON file.",
              keywords: ["backup", "export", "migrate", "second mac", "sync"]),
        .init(.advanced, "Transfer", "Import settings", subtitle: "Take chosen parts of an export.",
              keywords: ["restore", "import", "migrate", "second mac"]),
        .init(.advanced, "Diagnostics", "Reset to defaults", subtitle: "Rarely needed — puts one page's settings back."),
    ]

    /// Words a person might search that no row title carries, per page —
    /// "sound" finds Notifications, "LED" finds Lighting.
    nonisolated static let pageKeywords: [SettingsStore.Page: [String]] = [
        .general: ["login", "startup", "hotkey", "update", "sparkle", "version", "build", "icon", "setup", "permissions"],
        .agents: ["hooks", "claude", "codex", "gemini", "providers", "transcripts", "install"],
        .usage: ["quota", "limits", "meters", "graphs", "cost", "tokens", "pace"],
        .devices: ["sidepulse", "strip", "dot", "screen bar", "notch", "calibration", "creator micro", "stream deck", "usb"],
        .utilities: ["menu bar", "dock", "hide icons", "bartender", "ice", "switcher", "data hoarder", "archive"],
        .lighting: ["colors", "colours", "led", "brightness", "dim", "scene", "effects", "animation"],
        .toys: ["fold", "aquarium", "confetti", "buddy", "fun"],
        .notifications: ["banner", "focus", "do not disturb", "dnd", "quiet", "sleep", "keep awake",
                         "caffeinate", "lid", "battery", "escalation"],
        .sounds: ["sound", "chime", "alert", "volume", "airpods", "speaker", "audio", "call", "meeting", "microphone"],
        .shortcuts: ["hotkey", "keyboard", "key", "chord", "links", "url", "jrbar://", "toggles", "raycast", "alfred"],
        .remote: ["peers", "tailscale", "webhook", "serve", "ingest", "token", "fleet"],
        .advanced: ["doctor", "logs", "reset", "diagnostics", "socket", "debug"],
    ]

    /// Every page itself, so a page name or one of its keywords lands
    /// on the page.
    nonisolated static var pages: [SettingsSearchEntry] {
        SettingsStore.Page.allCases.map {
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

    /// How well `entry` answers `query`: every query word must appear
    /// somewhere in it (a word start, or anywhere for three letters or
    /// more); the title counts most, then the group and page, then the
    /// subtitle and keywords. nil when some word matches nothing.
    nonisolated static func score(_ entry: SettingsSearchEntry, query: [String]) -> Int? {
        guard !query.isEmpty else { return nil }
        let title = words(entry.title)
        let place = words(entry.group) + words(entry.page.title)
        let rest = words(entry.subtitle ?? "") + entry.keywords.flatMap(words)
        let joinedTitle = title.joined(separator: " ")
        var total = 0
        for word in query {
            func hit(_ candidates: [String]) -> Bool {
                candidates.contains { $0.hasPrefix(word) || (word.count >= 3 && $0.contains(word)) }
            }
            if hit(title) {
                total += title.first?.hasPrefix(word) == true ? 30 : 20
            } else if hit(place) {
                total += 8
            } else if hit(rest) {
                total += 4
            } else {
                return nil
            }
        }
        // A title that is the whole query outranks one that merely holds it.
        if joinedTitle == query.joined(separator: " ") { total += 40 }
        return total
    }

    /// The best matches for `text`, best first; ties keep page order.
    nonisolated static func search(_ text: String, in entries: [SettingsSearchEntry], limit: Int = 30)
        -> [SettingsSearchEntry] {
        let query = words(text)
        guard !query.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: SettingsStore.Page.allCases.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        return entries
            .compactMap { entry in score(entry, query: query).map { (entry, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return (order[lhs.0.page] ?? 0) < (order[rhs.0.page] ?? 0)
            }
            .map(\.0)
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
