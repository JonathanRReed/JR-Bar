import Foundation

/// One titled row inside a toy or utility card that Settings search can
/// land on: "synced lyrics" opens the Notch card, scrolls to it and
/// lights it. `keywords` are words a person might type that the title
/// does not carry.
struct ToySearchRow: Hashable, Sendable {
    let title: String
    let keywords: [String]

    init(_ title: String, keywords: [String] = []) {
        self.title = title
        self.keywords = keywords
    }
}

/// The rows each card's controls draw, by toy id. A card builds its
/// rows only when it is open, so they are listed here rather than
/// discovered; every title is the exact `SettingLabel` title its
/// control draws, and a source-pinning test fails the moment one is
/// renamed or removed, so a search can never lead to a row that is
/// gone.
enum ToySearchCatalog {
    static let rows: [String: [ToySearchRow]] = [
        "notch": [
            ToySearchRow("Render with", keywords: ["alcove", "boring notch"]),
            ToySearchRow("Show the island", keywords: ["dynamic island"]),
            ToySearchRow("Simulate notch", keywords: ["external display", "no notch"]),
            ToySearchRow("Card on hover", keywords: ["hover", "peek"]),
            ToySearchRow("Haptic tick", keywords: ["trackpad", "haptics"]),
            ToySearchRow("Pull & swipe gestures", keywords: ["gesture", "pinch", "pull down"]),
            ToySearchRow("Usage meters", keywords: ["quota", "limits"]),
            ToySearchRow("Event capsules", keywords: ["notice", "live activity"]),
            ToySearchRow("Hold news while quiet", keywords: ["focus", "digest"]),
            ToySearchRow("Mic & camera indicators", keywords: ["privacy", "microphone", "camera"]),
            ToySearchRow("Now Playing", keywords: ["music", "media", "spotify", "apple music"]),
            ToySearchRow("Audio visualizer (reacts to what's playing)",
                         keywords: ["equalizer", "bars", "spectrum"]),
            ToySearchRow("Synced lyrics", keywords: ["lyrics", "lrclib", "karaoke"]),
            ToySearchRow("Volume & brightness capsules", keywords: ["hud", "osd", "volume", "brightness"]),
            ToySearchRow("Replace the system volume & brightness overlay", keywords: ["hud", "osd"]),
            ToySearchRow("Timers flash the lights", keywords: ["timer", "sidepulse"]),
            ToySearchRow("Shake to summon the shelf", keywords: ["drag", "drop", "files", "shelf"]),
            ToySearchRow("Shelf hotkey", keywords: ["shelf", "keyboard"]),
            ToySearchRow("System alerts", keywords: ["bluetooth", "caps lock", "focus"]),
            ToySearchRow("Capsule tick", keywords: ["sound", "click"]),
            ToySearchRow("Weather", keywords: ["forecast", "rain", "open-meteo"]),
            ToySearchRow("Locate by IP when no city is set", keywords: ["location", "ipapi", "privacy"]),
            ToySearchRow("Calendar", keywords: ["events", "agenda"]),
            ToySearchRow("Meeting heads-up", keywords: ["zoom", "meet", "join"]),
            ToySearchRow("Reminders", keywords: ["todo", "tasks"]),
            ToySearchRow("Mirror", keywords: ["camera", "webcam"]),
        ],
        "notch-buddy": [
            ToySearchRow("Character", keywords: ["pet", "mascot"]),
            ToySearchRow("Mini", keywords: ["dot", "small"]),
            ToySearchRow("Wear the Screen Bar's colour", keywords: ["color", "tint"]),
            ToySearchRow("Name", keywords: ["rename"]),
            ToySearchRow("Size", keywords: ["bigger", "smaller"]),
            ToySearchRow("Caption on hover", keywords: ["name tag", "label", "caption"]),
            ToySearchRow("Take walks", keywords: ["walkabout", "stroll", "wander"]),
            ToySearchRow("Time between walks", keywords: ["walk", "stroll", "frequency", "how often"]),
        ],
        "confetti": [
            ToySearchRow("Weekly reset", keywords: ["trigger"]),
            ToySearchRow("Session completed", keywords: ["trigger", "done"]),
            ToySearchRow("All caught up", keywords: ["trigger", "asks"]),
            ToySearchRow("Codex banked credits", keywords: ["trigger"]),
            ToySearchRow("Milestones", keywords: ["trigger", "achievement"]),
            ToySearchRow("Quiet the toys during Focus, quiet hours and calls",
                         keywords: ["hush", "focus", "do not disturb", "meeting"]),
            ToySearchRow("A held burst", keywords: ["later"]),
            ToySearchRow("Sound", keywords: ["pop", "audio"]),
            ToySearchRow("Landing", keywords: ["pile", "floor"]),
            ToySearchRow("Palette", keywords: ["colors", "colours"]),
            ToySearchRow("Shapes", keywords: ["pieces"]),
            ToySearchRow("Density", keywords: ["amount"]),
            ToySearchRow("Duration", keywords: ["length"]),
        ],
        "aquarium": [
            ToySearchRow("Show labels", keywords: ["names", "fish"]),
            ToySearchRow("Density", keywords: ["plankton", "bubbles"]),
            ToySearchRow("Day & night", keywords: ["dark", "light", "time of day"]),
            ToySearchRow("Fill screen", keywords: ["full screen"]),
            ToySearchRow("Live wallpaper", keywords: ["desktop", "background"]),
            ToySearchRow("Screensaver", keywords: ["idle"]),
            ToySearchRow("Clock on the screensaver", keywords: ["time", "date"]),
            ToySearchRow("In the tank", keywords: ["fish", "sessions"]),
        ],
        "fold": [
            ToySearchRow("Render with", keywords: ["bendy", "lid plane"]),
            ToySearchRow("Fold from", keywords: ["angle"]),
            ToySearchRow("Starts folding at", keywords: ["angle", "lid"]),
            ToySearchRow("Perspective", keywords: ["taper", "tilt"]),
            ToySearchRow("Shade", keywords: ["dark"]),
            ToySearchRow("Blur", keywords: ["focus", "depth"]),
            ToySearchRow("Frost", keywords: ["milky", "cover"]),
            ToySearchRow("Hold picture in place", keywords: ["parallax"]),
            ToySearchRow("Jitter", keywords: ["wobble", "sensor"]),
            ToySearchRow("Release when parked", keywords: ["timeout"]),
            ToySearchRow("Click on return", keywords: ["sound", "tink"]),
            ToySearchRow("Hinge voice", keywords: ["creak", "sound"]),
            ToySearchRow("Simulate a fold", keywords: ["preview", "test"]),
            ToySearchRow("Lid angle", keywords: ["hinge", "sensor"]),
            ToySearchRow("Wallpaper without Screen Recording", keywords: ["permission"]),
        ],
        "menuBar": [
            ToySearchRow("Render with", keywords: ["bartender", "ice", "hidden bar"]),
            ToySearchRow("Hide the way macOS hides", keywords: ["native", "concealer"]),
            ToySearchRow("Hover the blank stretch", keywords: ["reveal", "hover"]),
            ToySearchRow("Click the blank stretch", keywords: ["reveal", "click"]),
            ToySearchRow("Scroll over the bar", keywords: ["reveal", "scroll", "swipe"]),
            ToySearchRow("Tuck away after", keywords: ["hide", "delay"]),
            ToySearchRow("Reveal style", keywords: ["inline", "item bar"]),
            ToySearchRow("Hide shown items while revealing", keywords: ["swap"]),
            ToySearchRow("Hidden items as tiles", keywords: ["item bar", "strip"]),
            ToySearchRow("Keep items out of the notch", keywords: ["notch"]),
            ToySearchRow("Hide items under app menus", keywords: ["crowded"]),
            ToySearchRow("Tint the whole bar", keywords: ["underlay", "colour", "color"]),
            ToySearchRow("Item spacing", keywords: ["gap", "padding"]),
            ToySearchRow("Spacer items", keywords: ["divider", "spacer"]),
            ToySearchRow("Profiles", keywords: ["layout", "preset"]),
            ToySearchRow("Command bar", keywords: ["palette", "cmd shift k"]),
            ToySearchRow("Rules", keywords: ["automation", "trigger"]),
            ToySearchRow("Cover material", keywords: ["blur", "glass"]),
        ],
        "dock": [
            ToySearchRow("Render with", keywords: ["dockdoor", "activedock"]),
            ToySearchRow("Hover previews", keywords: ["window previews", "thumbnails"]),
            ToySearchRow("Open previews on", keywords: ["option", "middle click"]),
            ToySearchRow("Show after", keywords: ["delay"]),
            ToySearchRow("Scroll on an icon", keywords: ["scroll", "hide app"]),
            ToySearchRow("Click the front app's icon to minimize", keywords: ["minimise", "taskbar"]),
            ToySearchRow("Window thumbnails", keywords: ["capture", "screen recording"]),
            ToySearchRow("Live card under the pointer", keywords: ["live", "video"]),
            ToySearchRow("Large cards", keywords: ["bigger"]),
            ToySearchRow("Capture every window", keywords: ["spaces", "minimized"]),
            ToySearchRow("Only windows on this display", keywords: ["multiple displays"]),
            ToySearchRow("Switcher", keywords: ["alt tab", "option tab"]),
            ToySearchRow("⌥⇥ window switcher", keywords: ["alt tab", "option tab", "windows"]),
            ToySearchRow("⌘⇥ app switcher", keywords: ["command tab", "cmd tab", "apps"]),
            ToySearchRow("Never preview", keywords: ["exclude", "ignore"]),
        ],
        "agents": [
            ToySearchRow("Alert rules", keywords: ["loud", "quiet", "per agent"]),
            ToySearchRow("Quiet while you watch", keywords: ["mute", "focused"]),
            ToySearchRow("Sessions", keywords: ["overview", "roster", "open"]),
        ],
    ]
}

extension Toy {
    var searchRows: [ToySearchRow] { ToySearchCatalog.rows[id] ?? [] }
}
