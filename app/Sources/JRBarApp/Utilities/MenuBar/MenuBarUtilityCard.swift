import AppKit
import JRBarCore
import SwiftUI

/// The Menu Bar utility's card on the Utilities page — `ToyCard`'s
/// shell (docs/UTILITIES.md: one visual language, two registries) over
/// a `MenuBarUtility` toy.
struct MenuBarUtilityCard: View {
    let utility: MenuBarUtility
    let tint: Color

    var body: some View {
        ToyCard(toy: utility, tint: tint)
    }
}

/// The Dock utility's card — same shell, a `Toy` conformance on
/// `DockUtility` provides the rows (see `DockUtilityCard`'s controls).
struct DockUtilityCard: View {
    let utility: DockUtility
    let tint: Color

    var body: some View {
        ToyCard(toy: utility, tint: tint)
    }
}

/// The card's disclosure body (the "card controls"): what's hidden,
/// the reveal gestures, the rehide dial, and the per-item section
/// pickers. Every row writes `UtilitiesStore.state.menuBar` through
/// the utility's `bind`/`setSection`, which persists and re-applies.
struct MenuBarUtilityControls: View {
    let utility: MenuBarUtility

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !utility.listedItems.isEmpty {
                SettingLabel(title: "Items",
                             subtitle: "Hidden items are covered in place — a click on the covered stretch or the chevron brings them back. Always-hidden stay covered until you open the Item Bar.")
                if !countsText.isEmpty {
                    Text(countsText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(utility.listedItems.filter { !MenuBarItemLister.isProtected($0) },
                        id: \.id) { item in
                    itemRow(item)
                }

                Divider()
                    .padding(.vertical, 4)
            }

            LabeledContent {
                Button("Show Item Bar") { utility.bar.toggle() }
                    .controlSize(.small)
            } label: {
                SettingLabel(title: "Hidden items",
                             subtitle: "The glass strip under the menu bar lists them as live tiles.")
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Appearance",
                         subtitle: "How the covered stretch reads. The default is the menu bar's own material — invisible until you tint or round it.")

            LabeledContent {
                Picker(selection: utility.bind(\.coverMaterial)) {
                    Text("Menu Bar").tag(MenuBarSettings.CoverMaterial.menu)
                    Text("HUD").tag(MenuBarSettings.CoverMaterial.hud)
                    Text("Popover").tag(MenuBarSettings.CoverMaterial.popover)
                    Text("Sheet").tag(MenuBarSettings.CoverMaterial.sheet)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } label: {
                SettingLabel(title: "Cover material",
                             subtitle: "The blur style the cover draws with.")
            }

            Toggle(isOn: utility.bindCoverTintEnabled()) {
                SettingLabel(title: "Tint the cover",
                             subtitle: "A color wash over the material so the covered stretch reads as yours.")
            }
            if !utility.settings().coverTint.isEmpty {
                LabeledContent {
                    ColorPicker(selection: utility.bindCoverTintColor(), supportsOpacity: false) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .controlSize(.small)
                } label: {
                    SettingLabel(title: "Tint color")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: utility.bind(\.coverTintOpacity), in: 0...1)
                            .frame(width: 160)
                        ValueText(text: "\(Int((utility.settings().coverTintOpacity * 100).rounded()))%")
                    }
                } label: {
                    SettingLabel(title: "Tint strength")
                }
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: utility.bind(\.coverRoundness),
                           in: MenuBarSettings.coverRoundnessRange)
                        .frame(width: 160)
                    ValueText(text: "\(Int(utility.settings().coverRoundness))pt")
                }
            } label: {
                SettingLabel(title: "Rounded ends",
                             subtitle: "Corner radius on each covered run.")
            }

            Toggle(isOn: utility.bind(\.showCoverSeparator)) {
                SettingLabel(title: "Edge separators",
                             subtitle: "A hairline where a covered run meets visible menu bar.")
            }

            Toggle(isOn: utility.bind(\.combinedStatusItem)) {
                SettingLabel(title: "Single combined item",
                             subtitle: "One status item instead of two — click opens the Item Bar, right-click lists the covered items.")
            }

            Divider()
                .padding(.vertical, 4)

            MenuBarProfilesControls(utility: utility)

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Bring them back",
                         subtitle: "What counts as a reveal gesture. The run folds away again on its own.")

            Toggle(isOn: utility.bind(\.revealOnHover)) {
                SettingLabel(title: "Pointer reaches the bar",
                             subtitle: "Hover over the menu bar's empty space.")
            }
            Toggle(isOn: utility.bind(\.revealOnClick)) {
                SettingLabel(title: "Click on empty space",
                             subtitle: "A click that lands on no item's frame.")
            }
            Toggle(isOn: utility.bind(\.revealOnScroll)) {
                SettingLabel(title: "Scroll over the bar",
                             subtitle: "A swipe or scroll wheel on the menu bar.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: utility.bind(\.rehideSeconds), in: MenuBarSettings.rehideRange)
                        .frame(width: 160)
                    ValueText(text: SettingsStore.seconds(utility.settings().rehideSeconds))
                }
            } label: {
                SettingLabel(title: "Hide again after",
                             subtitle: "How long a reveal lasts while the pointer is off the bar.")
            }

            Divider()
                .padding(.vertical, 4)
            MenuBarAutomationControls(utility: utility)

            if !utility.accessibilityGranted {
                Divider()
                    .padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Accessibility lets Menu Bar list every app's items and click Item Bar tiles through. Without it the covers still hide what you assign, but listing and tiles need the window list.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { utility.refreshListing() }
    }

    private var countsText: String {
        var parts: [String] = []
        if !utility.lastPlan.hidden.isEmpty {
            parts.append("\(utility.lastPlan.hidden.count) hidden")
        }
        if !utility.lastPlan.alwaysHidden.isEmpty {
            parts.append("\(utility.lastPlan.alwaysHidden.count) always-hidden")
        }
        return parts.joined(separator: " · ")
    }

    /// One item: the owner's icon and name, then the section picker.
    private func itemRow(_ item: MenuBarItem) -> some View {
        LabeledContent {
            Picker(selection: Binding(
                get: { utility.section(for: item.id) },
                set: { utility.setSection($0, for: item.id) }
            )) {
                Text("Shown").tag(MenuBarItemSection.shown)
                Text("Hidden").tag(MenuBarItemSection.hidden)
                Text("Always").tag(MenuBarItemSection.alwaysHidden)
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: item.owner?.icon ?? NSImage())
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// The Profiles rows: a picker that applies a saved arrangement (or the
/// built-in "None"), and a name field that saves the current one. A
/// profile is sections plus appearance — applying it is a settings
/// write like any other, so the reconcile path does the rest.
private struct MenuBarProfilesControls: View {
    let utility: MenuBarUtility
    /// The picker selection — a profile id, or "none".
    @ViewState private var selection = MenuBarProfiles.noneID
    /// The save/rename field.
    @ViewState private var nameDraft = ""

    var body: some View {
        SettingLabel(title: "Profiles",
                     subtitle: "Saved arrangements — the section map plus the cover look — applied in one move.")

        LabeledContent {
            Picker(selection: $selection) {
                Text(MenuBarProfiles.noneName).tag(MenuBarProfiles.noneID)
                ForEach(utility.settings().profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: selection) { _, id in
                utility.applyProfile(id: id)
            }
        } label: {
            SettingLabel(title: "Apply",
                         subtitle: "Switching writes the whole arrangement at once.")
        }

        LabeledContent {
            HStack(spacing: 6) {
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Save") {
                    if let id = utility.saveProfileAs(nameDraft) {
                        selection = id
                        nameDraft = ""
                    }
                }
                .controlSize(.small)
                .disabled(MenuBarProfiles.validName(nameDraft) == nil)
            }
        } label: {
            SettingLabel(title: "Save current as",
                         subtitle: "Sections, cover look and control layout, captured together.")
        }

        if selection != MenuBarProfiles.noneID,
           utility.settings().profiles.contains(where: { $0.id == selection }) {
            HStack(spacing: 8) {
                Button("Rename to field") {
                    utility.renameProfile(id: selection, to: nameDraft)
                }
                .controlSize(.small)
                .disabled(MenuBarProfiles.validName(nameDraft) == nil)
                Button("Delete") {
                    utility.deleteProfile(id: selection)
                    selection = MenuBarProfiles.noneID
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The Automate rows: the ⌘⇧K command bar, the global hotkeys, the
/// trigger rules, and the physical arrange — the actions half of the
/// utility, each row landing on `MenuBarActions` through the utility.
private struct MenuBarAutomationControls: View {
    let utility: MenuBarUtility

    /// The add-rule draft: trigger kind + its parameter, action kind +
    /// its parameter. `ViewState` is `SwiftUICore.State` — the CLT
    /// toolchain ships no SwiftUIMacros plugin, so plain `@State`
    /// cannot appear here.
    @ViewState private var triggerKind = "unlock"
    @ViewState private var triggerBundleID = ""
    @ViewState private var triggerHour = 9
    @ViewState private var triggerMinute = 0
    @ViewState private var actionKind = "hideAll"
    @ViewState private var actionProfile = ""
    @ViewState private var actionSeconds = 4.0

    var body: some View {
        SettingLabel(title: "Automate",
                     subtitle: "The command bar, global hotkeys, and rules that fire on their own.")

        LabeledContent {
            Button("Open (⌘⇧K)") { utility.openCommandBar() }
                .controlSize(.small)
        } label: {
            SettingLabel(title: "Command bar",
                         subtitle: "A floating palette of every item and action — type to filter, Enter to run.")
        }

        ForEach(utility.resolvedHotkeyBindings(), id: \.action) { binding in
            Toggle(isOn: Binding(
                get: { binding.enabled },
                set: { utility.setHotkeyEnabled($0, for: binding.action) }
            )) {
                HStack {
                    Text(hotkeyTitle(binding.action))
                        .font(.callout)
                    Spacer(minLength: 8)
                    Text(binding.displayString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }

        rulesSection
        arrangeSection
    }

    private func hotkeyTitle(_ action: MenuBarHotkeyAction) -> String {
        switch action {
        case .toggleReveal: return "Toggle hidden items"
        case .hideAll: return "Hide all"
        case .showAll: return "Show all"
        case .commandBar: return "Command bar"
        case .nextProfile: return "Next profile"
        case .previousProfile: return "Previous profile"
        }
    }

    // MARK: Rules

    @ViewBuilder
    private var rulesSection: some View {
        let rules = utility.settings().triggerRules
        SettingLabel(title: "Rules",
                     subtitle: "When something happens, the bar reacts — lock, unlock, an app activating, a time, the charger.")
        ForEach(rules) { rule in
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { rule.enabled },
                    set: { utility.setTriggerRule(id: rule.id, enabled: $0) }
                )) {
                    Text(rule.summary)
                        .font(.callout)
                        .lineLimit(2)
                }
                Button { utility.deleteTriggerRule(id: rule.id) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }

        HStack(spacing: 6) {
            Picker(selection: $triggerKind) {
                Text("Screen locks").tag("lock")
                Text("Screen unlocks").tag("unlock")
                Text("App activates").tag("app")
                Text("Time of day").tag("time")
                Text("Charger in").tag("acOn")
                Text("Charger out").tag("acOff")
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if triggerKind == "app" {
                TextField("bundle id", text: $triggerBundleID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            if triggerKind == "time" {
                TextField("HH", value: $triggerHour, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 34)
                TextField("MM", value: $triggerMinute, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 34)
            }
        }

        HStack(spacing: 6) {
            Picker(selection: $actionKind) {
                Text("Apply profile").tag("profile")
                Text("Hide all").tag("hideAll")
                Text("Show all").tag("showAll")
                Text("Reveal for…").tag("reveal")
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if actionKind == "profile" {
                Picker(selection: $actionProfile) {
                    Text(MenuBarProfiles.noneName).tag(MenuBarProfiles.noneName)
                    ForEach(utility.settings().profiles) { p in
                        Text(p.name).tag(p.name)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if actionKind == "reveal" {
                TextField("s", value: $actionSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
            }
            Button("Add rule") { addRule() }
                .controlSize(.small)
                .disabled(!ruleDraftValid)
        }
    }

    private var ruleDraftValid: Bool {
        if triggerKind == "app" && triggerBundleID.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if actionKind == "reveal" && actionSeconds < 1 { return false }
        return true
    }

    private func addRule() {
        let trigger: MenuBarTrigger
        switch triggerKind {
        case "lock": trigger = .screenLocked
        case "app": trigger = .appActivated(
            bundleID: triggerBundleID.trimmingCharacters(in: .whitespaces))
        case "time": trigger = .timeOfDay(
            hour: min(23, max(0, triggerHour)),
            minute: min(59, max(0, triggerMinute)))
        case "acOn": trigger = .chargerConnected
        case "acOff": trigger = .chargerDisconnected
        default: trigger = .screenUnlocked
        }
        let action: MenuBarTriggerAction
        switch actionKind {
        case "profile": action = .applyProfile(name: actionProfile)
        case "showAll": action = .showAll
        case "reveal": action = .reveal(seconds: actionSeconds)
        default: action = .hideAll
        }
        utility.addTriggerRule(trigger: trigger, action: action)
    }

    // MARK: Arrange

    @ViewBuilder
    private var arrangeSection: some View {
        SettingLabel(title: "Arrange",
                     subtitle: "Physically reorder the bar — ⌘-drags move the real cursor. Keep hands off while it runs; Esc or any input cancels.")
        ForEach(utility.arrangeItems, id: \.id) { item in
            HStack(spacing: 8) {
                Image(nsImage: item.owner?.icon ?? NSImage())
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button { utility.moveArrangeItem(id: item.id, by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Button { utility.moveArrangeItem(id: item.id, by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        HStack(spacing: 8) {
            Button(utility.arranging ? "Arranging…" : "Arrange now") {
                utility.arrangeNow()
            }
            .controlSize(.small)
            .disabled(utility.arranging || utility.arrangeItems.isEmpty)
            if let note = utility.arrangeNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
