import JRBarCore
import SwiftUI

/// Settings › Lighting › Blend, under the celebration: which finish plays
/// when a session is done, and the opt-in tool tint on the working light.
/// Effect Studio › Moments shows the finishes side by side.
struct LightingMotionRows: View {
    @Bindable var store: SettingsStore

    static let finishes: [(value: String, label: String)] = [
        ("bloom", "Bloom"), ("land", "Land"), ("ripple", "Ripple"),
    ]

    var body: some View {
        SettingPicker(store, "Finish", subtitle: finishSubtitle, path: "colors.done_celebration_style",
                      options: Self.finishes, default: "bloom")
            .disabled(!(store.values.bool("colors.done_celebration_enabled") ?? true))
        SettingToggle(store, "Tint by tool",
                      subtitle: "While an agent works, the head of a Chase, Comet or Glint takes the colour of what it is doing: running a command, editing, reading, the web, a sub-task, planning. The tail keeps the agent's colour.",
                      path: "colors.tint_by_tool")
    }

    private var finishSubtitle: String {
        switch store.values.string("colors.done_celebration_style") ?? "bloom" {
        case "land": return "A light falls to the far end, faster and faster, lands with a splash and glows there a moment."
        case "ripple": return "One wide ring runs out from the middle, dimming as it goes."
        default: return "A spark crosses the strip, then it blooms in the done colour and fades."
        }
    }
}
