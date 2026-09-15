import AppKit
import JRBarCore
import SwiftUI

/// `DockUtility` as a card on the Utilities page — the same `Toy`
/// shape `MenuBarUtility` already wears (docs/UTILITIES.md).
extension DockUtility: Toy {
    var id: String { "dock" }
    var name: String { "Dock" }
    var blurb: String {
        "Your own dock — running apps, pins, magnification — in place of Apple's, or previews on top of it."
    }
    var symbol: String { "dock.rectangle" }

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        if settings().mode == .enhance {
            if !enhance.accessibilityTrusted {
                return .needsPermission("Needs Accessibility")
            }
            return enhance.running ? .on : .paused("Parked")
        }
        return running ? .on : .paused("Parked")
    }

    var controls: AnyView { AnyView(DockUtilityControls(utility: self)) }
}

/// The Dock card's disclosure body (docs/UTILITIES.md): mode, shape,
/// motion, hiding, and the Apple Dock save/restore control.
struct DockUtilityControls: View {
    let utility: DockUtility
    /// The "hide Apple's Dock" confirmation — an explicit step so the
    /// write to `com.apple.dock` is always deliberate.
    @ViewState private var confirmHideAppleDock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Picker(selection: utility.bind(\.mode)) {
                    Text("Replace the Dock").tag(DockMode.replace)
                    Text("Enhance").tag(DockMode.enhance)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Mode",
                             subtitle: "Replace draws our bar and can hide Apple's. Enhance floats window previews over Apple's Dock.")
            }

            if utility.settings().mode == .enhance {
                enhanceControls
            }

            if utility.settings().mode == .replace {
            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "The bar",
                         subtitle: "Where it sits and how it looks.")
            LabeledContent {
                Picker(selection: utility.bind(\.edge)) {
                    Text("Bottom").tag(DockEdge.bottom)
                    Text("Left").tag(DockEdge.left)
                    Text("Right").tag(DockEdge.right)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Edge", subtitle: "Top stays the menu bar's.")
            }
            LabeledContent {
                Picker(selection: utility.bind(\.displayPolicy)) {
                    Text("Main display").tag(DockDisplayPolicy.main)
                    Text("Every display").tag(DockDisplayPolicy.perDisplay)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Displays", subtitle: "A bar per screen, or the main one only.")
            }
            LabeledContent {
                Picker(selection: utility.bind(\.material)) {
                    Text("Glass").tag(DockMaterial.glass)
                    Text("Frosted").tag(DockMaterial.frosted)
                    Text("Solid").tag(DockMaterial.solid)
                    Text("Clear").tag(DockMaterial.clear)
                } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: "Material", subtitle: "The bar floats, so glass is allowed.")
            }
            LabeledContent {
                Picker(selection: utility.bind(\.style)) {
                    Text("Floating").tag(DockBarStyle.floating)
                    Text("Full width").tag(DockBarStyle.fullWidth)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Shape", subtitle: "A pill off the edge, or the edge itself.")
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: utility.bind(\.iconSize), in: DockSettings.iconSizeRange)
                        .frame(width: 140)
                    ValueText(text: "\(Int(utility.settings().iconSize)) pt")
                }
            } label: {
                SettingLabel(title: "Icon size", subtitle: "")
            }
            LabeledContent {
                Picker(selection: utility.bind(\.runningIndicator)) {
                    Text("Dot").tag(DockRunningIndicator.dot)
                    Text("Card").tag(DockRunningIndicator.card)
                    Text("None").tag(DockRunningIndicator.none)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Running mark", subtitle: "How a running app's icon is marked.")
            }
            Toggle(isOn: utility.bind(\.showFinder)) {
                SettingLabel(title: "Show Finder", subtitle: "Finder can never really quit — keep it pinned anyway.")
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Folders & tray",
                         subtitle: "Folders open a grid of their contents above the bar. Drag any file onto the bar to park it in the tray; right-click a parked tile to remove it.")
            ForEach(utility.settings().folders, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        utility.update { $0.folders.removeAll { $0 == path } }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Dock")
                }
            }
            Button("Add Folder…") { chooseFolders() }
                .controlSize(.small)
            if !utility.settings().tray.isEmpty {
                ForEach(utility.settings().tray, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            utility.update { $0.tray.removeAll { $0 == path } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from Tray")
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Widgets", subtitle: "Small live tiles at the bar's file end.")
            Toggle(isOn: widgetClock) {
                SettingLabel(title: "Clock", subtitle: "")
            }
            Toggle(isOn: widgetBattery) {
                SettingLabel(title: "Battery", subtitle: "The internal battery's charge — a desktop shows the no-battery mark.")
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Motion", subtitle: "")
            Toggle(isOn: magnificationEnabled) {
                SettingLabel(title: "Magnification",
                             subtitle: "Icons swell under the pointer, like Apple's.")
            }
            if utility.settings().magnification.enabled {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: magnificationScale, in: DockMagnification.scaleRange)
                            .frame(width: 140)
                        ValueText(text: String(format: "%.2f×", utility.settings().magnification.scale))
                    }
                } label: {
                    SettingLabel(title: "Strength", subtitle: "")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: magnificationReach, in: DockMagnification.reachRange)
                            .frame(width: 140)
                        ValueText(text: "\(Int(utility.settings().magnification.reach)) pt")
                    }
                } label: {
                    SettingLabel(title: "Reach", subtitle: "How far from the pointer the wave still lifts.")
                }
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: autoHideEnabled) {
                SettingLabel(title: "Auto-hide",
                             subtitle: "The bar slides away and comes back at the screen's edge.")
            }
            if utility.settings().autoHide.enabled {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: autoHideDelay, in: DockAutoHide.delayRange)
                            .frame(width: 140)
                        ValueText(text: SettingsStore.seconds(utility.settings().autoHide.delay))
                    }
                } label: {
                    SettingLabel(title: "Hide after", subtitle: "")
                }
            }
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Apple's Dock",
                         subtitle: "Replace mode auto-hides it (with a long reveal delay) while the bar runs — we write `autohide` and `autohide-delay` to com.apple.dock and restart the Dock. Your old values are saved and restored.")
            HStack(spacing: 8) {
                Button(utility.appleDock.isAppleDockHidden
                       ? "Restore Apple's Dock" : "Hide Apple's Dock") {
                    if utility.appleDock.isAppleDockHidden {
                        utility.appleDock.restore()
                    } else {
                        confirmHideAppleDock = true
                    }
                }
                .controlSize(.small)
                Text(utility.appleDock.isAppleDockHidden
                     ? "Hidden — auto-hide is on."
                     : "Visible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { utility.enhance.refreshPermissions() }
        .confirmationDialog("Hide Apple's Dock?",
                            isPresented: $confirmHideAppleDock,
                            titleVisibility: .visible) {
            Button("Hide Apple's Dock") {
                utility.appleDock.setAppleDockHidden(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("JR-Bar sets auto-hide and restarts the Dock. Your previous setting is saved and restored when you turn this off — and Mission Control can still show Apple's Dock, same as every replacement.")
        }
    }

    /// Enhance mode's rows: the preview delay, the thumbnail toggle,
    /// and the two permission gates the feature lives behind. The
    /// knobs persist through `DockSettings.enhance` — the facade's
    /// `write` lands in `app-state.json` via `DockUtility.update`.
    @ViewBuilder
    private var enhanceControls: some View {
        SettingLabel(title: "Hover previews",
                     subtitle: "Rest the pointer on a Dock icon to float that app's windows above Apple's Dock — click one to raise it.")
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: previewDelay, in: DockEnhancePreferences.delayRange)
                    .frame(width: 140)
                ValueText(text: SettingsStore.seconds(utility.enhance.preferences.previewDelay))
            }
        } label: {
            SettingLabel(title: "Show after", subtitle: "")
        }
        Toggle(isOn: thumbnails) {
            SettingLabel(title: "Window thumbnails",
                         subtitle: "Live captures via Screen Recording; off shows icon + title rows.")
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
                Text("Thumbnails need Screen Recording — window titles and raising work without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open Settings") { utility.openScreenCaptureSettings() }
                    .controlSize(.small)
            }
        }
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
    private var magnificationEnabled: Binding<Bool> {
        Binding(get: { utility.settings().magnification.enabled },
                set: { value in utility.update { $0.magnification.enabled = value } })
    }
    private var magnificationScale: Binding<Double> {
        Binding(get: { utility.settings().magnification.scale },
                set: { value in utility.update { $0.magnification.scale = value } })
    }
    private var magnificationReach: Binding<Double> {
        Binding(get: { utility.settings().magnification.reach },
                set: { value in utility.update { $0.magnification.reach = value } })
    }
    private var autoHideEnabled: Binding<Bool> {
        Binding(get: { utility.settings().autoHide.enabled },
                set: { value in utility.update { $0.autoHide.enabled = value } })
    }
    private var autoHideDelay: Binding<Double> {
        Binding(get: { utility.settings().autoHide.delay },
                set: { value in utility.update { $0.autoHide.delay = value } })
    }
    private var widgetClock: Binding<Bool> {
        Binding(get: { utility.settings().widgets.clock },
                set: { value in utility.update { $0.widgets.clock = value } })
    }
    private var widgetBattery: Binding<Bool> {
        Binding(get: { utility.settings().widgets.battery },
                set: { value in utility.update { $0.widgets.battery = value } })
    }

    /// "Add Folder…" — an open panel pinned to directories; the
    /// picked paths append deduped into `DockSettings.folders`.
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Dock"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        utility.update { $0.folders = DockSettings.deduped($0.folders + paths) }
    }
}
