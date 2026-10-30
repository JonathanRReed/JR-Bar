import JRBarUI
import SwiftUI

struct ScreenBarSettingsPreview: View {
    let store: SettingsStore
    @ViewState private var replay = 0

    var body: some View {
        let surface = store.screenBarSurface
        SettingGroup("Preview") {
            SettingRow(
                "Light band",
                subtitle: surface == nil
                    ? "Sample color. The monitor has not reported a light program."
                    : "The current color program. Replaying it changes only this preview."
            ) {
                Button("Replay") { replay += 1 }.disabled(surface == nil)
            }
            LEDStripPreview(
                program: surface?.program ?? "#0088FF", ledCount: surface?.ledCount ?? 30,
                style: .band, dotSize: 12, loops: false
            )
            .id(replay)
        }
    }
}
