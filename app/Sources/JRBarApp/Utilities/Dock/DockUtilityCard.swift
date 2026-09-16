import AppKit
import JRBarCore
import SwiftUI

/// `DockUtility` as a card on the Utilities page — the same `Toy`
/// shape `MenuBarUtility` already wears (docs/UTILITIES.md).
extension DockUtility: Toy {
    var id: String { "dock" }
    var name: String { "Dock" }
    var blurb: String {
        "Rest on a Dock icon to see that app's windows — click one to raise it, close or minimize from the card."
    }
    var symbol: String { "dock.rectangle" }

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        if !enhance.accessibilityTrusted {
            return .needsPermission("Needs Accessibility")
        }
        return enhance.running ? .on : .paused("Parked")
    }

    var controls: AnyView { AnyView(DockUtilityControls(utility: self)) }
}

/// The Dock card's disclosure body: the hover delay, what the cards
/// carry, and the two permission gates the feature lives behind. The
/// knobs persist through `DockSettings.enhance` — the facade's `write`
/// lands in `app-state.json` via `DockUtility.update`.
struct DockUtilityControls: View {
    let utility: DockUtility

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(title: "Hover previews",
                         subtitle: "Apple's Dock stays. Rest the pointer on an icon and that app's windows appear beside the Dock: click a card to raise the window, hover it for × (close) and – (minimize); Quit and Hide sit in the header. Apps with no windows open nothing.")
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: previewDelay, in: DockEnhancePreferences.delayRange)
                        .frame(width: 140)
                    ValueText(text: SettingsStore.seconds(utility.enhance.preferences.previewDelay))
                }
            } label: {
                SettingLabel(title: "Show after",
                             subtitle: "How long the pointer rests before the preview opens.")
            }
            Toggle(isOn: thumbnails) {
                SettingLabel(title: "Window thumbnails",
                             subtitle: "A capture of each window, kept for half a minute (needs Screen Recording — each fresh capture flashes macOS's recording dot); off shows icon + title cards.")
            }
            Toggle(isOn: largePreviews) {
                SettingLabel(title: "Large cards",
                             subtitle: "Bigger thumbnails for reading the window, not just the title.")
            }
            Toggle(isOn: offscreen) {
                SettingLabel(title: "Capture every window",
                             subtitle: "Thumbnails for windows on other Spaces and minimized ones too; the cards list them either way.")
            }
            if utility.isOn && !utility.enhance.accessibilityTrusted {
                HStack(spacing: 8) {
                    Text("Hover previews need Accessibility so JR-Bar can see which Dock icon the pointer rests on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            } else if utility.isOn && utility.enhance.preferences.showThumbnails
                        && !utility.enhance.screenCaptureGranted {
                HStack(spacing: 8) {
                    Text("Thumbnails need Screen Recording — window titles, raising, closing and minimizing work without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openScreenCaptureSettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { utility.enhance.refreshPermissions(force: true) }
    }

    // Nested settings structs get their own bindings — `bind` only
    // reaches top-level key paths cleanly through the write path.
    private var previewDelay: Binding<Double> {
        Binding(get: { utility.enhance.preferences.previewDelay },
                set: { utility.enhance.preferences.previewDelay = $0 })
    }
    private var thumbnails: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.showThumbnails },
                set: { utility.enhance.preferences.showThumbnails = $0 })
    }
    private var largePreviews: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.largePreviews },
                set: { utility.enhance.preferences.largePreviews = $0 })
    }
    private var offscreen: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.includeOffscreenWindows },
                set: { utility.enhance.preferences.includeOffscreenWindows = $0 })
    }
}
