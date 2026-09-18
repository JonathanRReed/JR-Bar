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

/// The card's disclosure body: what is hidden right now and how to
/// change it, the reveal gestures, then everything else behind an
/// Advanced disclosure. Every row writes `UtilitiesStore.state.menuBar`
/// through the utility's `bind`/`setSection`, which persists and
/// re-applies.
struct MenuBarUtilityControls: View {
    let utility: MenuBarUtility
    @ViewState private var showAdvanced = false
    @ViewState private var showOverrides = false
    @ViewState private var showExtras = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: utility.providerBinding) {
                Text("JR-Bar").tag(MenuBarProvider.jrbar)
                Text("Bartender").tag(MenuBarProvider.bartender)
                Text("Ice").tag(MenuBarProvider.ice)
                Text("Hidden Bar").tag(MenuBarProvider.hiddenBar)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Hand the hiding to an installed counterpart — Bartender (paid), Ice or Hidden Bar (free). Ours parks while the pick stands.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            if let note = utility.providerNote {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if utility.externalURL != nil {
                        Spacer()
                        Button("Open") { utility.openExternal() }
                            .controlSize(.small)
                    }
                }
            }

            SettingLabel(title: "How it works",
                         subtitle: utility.concealing
                            ? "Nothing is hidden until you choose it. Pick Hidden or Always under Overrides, or ⌘-drag an item left of the ‹ separator (or the macOS « caret while items are parked) — it joins the hidden run where it stays active and reachable. Drag it back right to show it again. Hover, click the empty bar, or scroll to peek at the hidden run."
                            : "Everything to the left of the JR-Bar icon in the menu bar is tucked away. ⌘-drag any item across the icon to hide or show it.")
            if utility.concealerAvailable, !utility.concealing {
                Toggle(isOn: utility.bind(\.concealUnnotarized)) {
                    SettingLabel(title: "Hide the way macOS hides",
                                 subtitle: "This build of JR-Bar isn't notarized, and macOS keeps only notarized apps on the bar while it hides the rest — JR-Bar's own icon would go too. Notarize the build (make package with the jrbar-notary profile) to get this without losing the icon, or turn it on anyway.")
                }
            }

            LabeledContent {
                Text(countsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Right now")
            }

            HStack(spacing: 8) {
                Button("Hide all") { utility.hideAllListed() }
                    .controlSize(.small)
                    .help("Hide every listed menu bar item at once — same as ⌘-dragging each one left of the separator")
                    .accessibilityLabel("Hide all menu bar items")
                Button("Show all") { utility.showAllListed() }
                    .controlSize(.small)
                    .help("Bring every hidden item back")
                    .accessibilityLabel("Show all menu bar items")
            }
            .padding(.top, 2)

            if !hideable.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hideable, id: \.id) { item in
                        itemRow(item)
                    }
                }
                .padding(.top, 2)
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Bring them back",
                         subtitle: "What counts as a reveal. The run tucks itself away again on its own.")
            Toggle(isOn: utility.bind(\.revealOnHover)) {
                SettingLabel(title: "Hover the blank stretch",
                             subtitle: "Rest the pointer on the empty bar left of the icon.")
            }
            Toggle(isOn: utility.bind(\.revealOnClick)) {
                SettingLabel(title: "Click the blank stretch",
                             subtitle: "A click on the empty bar left of the icon, or on the icon's edge.")
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
                SettingLabel(title: "Tuck away after",
                             subtitle: "How long a reveal lasts once the pointer leaves the bar.")
            }
            Picker(selection: utility.bind(\.revealStyle)) {
                Text("Item Bar — Bartender").tag(MenuBarSettings.RevealStyle.bar)
                Text("On the bar — Ice, Hidden Bar").tag(MenuBarSettings.RevealStyle.inline)
            } label: {
                SettingLabel(title: "Reveal style",
                             subtitle: "The Item Bar panel leaves the row untouched; inline reflows the hidden items onto the menu bar itself.")
            }
            .pickerStyle(.menu)
            Toggle(isOn: utility.bind(\.hideShownWhileRevealing)) {
                SettingLabel(title: "Hide shown items while revealing",
                             subtitle: "Bartender's swap: while a reveal is out, the normally-visible items are covered too — the bar shows only the hidden run.")
            }
            Toggle(isOn: utility.bind(\.showForUpdates)) {
                SettingLabel(title: "Show for updates",
                             subtitle: "A hidden item that updates itself — a clock's minute, a VPN's \"Connected\" — reveals the run for a moment so the change is seen.")
            }
            LabeledContent {
                Button("Show Item Bar") { utility.bar.toggle() }
                    .controlSize(.small)
            } label: {
                SettingLabel(title: "Hidden items as tiles",
                             subtitle: "A glass strip under the menu bar with a live tile per hidden item — also on the JR-Bar icon's right-click menu.")
            }

            if !utility.accessibilityGranted {
                Divider()
                    .padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Accessibility lets Menu Bar see where every item sits and click tiles through. Without it the boundary still works, but the list and the tiles go blind.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }

            Divider()
                .padding(.vertical, 4)

            DisclosureGroup(isExpanded: $showExtras) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: utility.bind(\.hideUnderNotch)) {
                        SettingLabel(title: "Keep items out of the notch",
                                     subtitle: "An item that lands in the notch band is invisible anyway — it moves to the hidden run where the Item Bar can still reach it.")
                    }
                    Toggle(isOn: utility.bind(\.hideOnMenuOverlap)) {
                        SettingLabel(title: "Hide items under app menus",
                                     subtitle: "On a crowded bar the front app's menus draw over items — those hide instead of sitting unreachable.")
                    }
                    Toggle(isOn: utility.bind(\.barUnderlay)) {
                        SettingLabel(title: "Tint the whole bar",
                                     subtitle: "The cover's material and tint drawn under the full menu bar row, on every display.")
                    }
                    Toggle(isOn: utility.bind(\.agentStatusItem)) {
                        SettingLabel(title: "Agent status item",
                                     subtitle: "A dot in the bar showing what your agents are doing; click opens the Overview.")
                    }
                    Toggle(isOn: utility.bind(\.combinedSystemItem)) {
                        SettingLabel(title: "One system item",
                                     subtitle: "Battery, Wi-Fi, sound and Focus in a single item with a popover — the matching Control Center items hide while it runs.")
                    }
                    Divider()
                        .padding(.vertical, 4)
                    spacerEditor
                    Divider()
                        .padding(.vertical, 4)
                    displayProfileEditor
                }
                .padding(.top, 4)
            } label: {
                SettingLabel(title: "Extras",
                             subtitle: "Spacer items, the bar underlay, the agent item, per-display profiles, and what the notch and menus cover.")
            }

            DisclosureGroup(isExpanded: $showOverrides) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingLabel(title: "Cover in place",
                                 subtitle: "An item marked Cover or Always is hidden under a patch of menu bar where it sits, even right of the icon — a hole, honestly. Auto follows the drag position.")
                    ForEach(hideable, id: \.id) { item in
                        overrideRow(item)
                    }
                    appearanceControls
                }
                .padding(.top, 4)
            } label: {
                SettingLabel(title: "Overrides",
                             subtitle: "Hide an item without moving it.")
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Picker(selection: utility.bind(\.itemSpacing)) {
                            Text("System").tag(0)
                            Text("Roomy").tag(14)
                            Text("Compact").tag(8)
                            Text("Tight").tag(4)
                        } label: { EmptyView() }
                            .labelsHidden()
                            .fixedSize()
                    } label: {
                        SettingLabel(title: "Item spacing",
                                     subtitle: "A tighter gap between every app's items, system-wide. Items pick it up as they relaunch.")
                    }
                    Divider()
                        .padding(.vertical, 4)
                    MenuBarProfilesControls(utility: utility)
                    Divider()
                        .padding(.vertical, 4)
                    MenuBarAutomationControls(utility: utility)
                }
                .padding(.top, 4)
            } label: {
                SettingLabel(title: "Advanced",
                             subtitle: "Item spacing, profiles, the ⌘⇧K command bar, hotkeys, rules, and the arrange run.")
            }
        }
        .onAppear { utility.refreshListing() }
    }

    /// Every listed item the utility could hide, in bar order.
    private var hideable: [MenuBarItem] {
        utility.listedItems.filter { !MenuBarItemLister.isProtected($0) }
    }

    private var countsText: String {
        let hidden = utility.lastPlan.hidden.count
        let always = utility.lastPlan.alwaysHidden.count
        let shown = hideable.count - hidden - always
        var parts: [String] = []
        if hidden > 0 { parts.append("\(hidden) hidden") }
        if always > 0 { parts.append("\(always) always hidden") }
        parts.append("\(max(0, shown)) shown")
        if utility.listedItems.isEmpty { return "Nothing listed yet" }
        return parts.joined(separator: " · ")
    }

    /// One item: the owner's icon and name, then where it is.
    private func itemRow(_ item: MenuBarItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: item.owner?.icon ?? NSImage())
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(placement(of: item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The override picker for one item.
    private func overrideRow(_ item: MenuBarItem) -> some View {
        LabeledContent {
            Picker(selection: Binding(
                get: { utility.effectiveSection(for: item) },
                set: { utility.setSection($0, for: item.id) }
            )) {
                Text("Auto").tag(MenuBarItemSection.shown)
                Text("Cover").tag(MenuBarItemSection.hidden)
                Text("Always").tag(MenuBarItemSection.alwaysHidden)
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: item.owner?.icon ?? NSImage())
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The spacer/label item rows plus the add button.
    @ViewBuilder
    private var spacerEditor: some View {
        SettingLabel(title: "Spacer items",
                     subtitle: "Fixed-width or labelled items of ours that sit anywhere in the bar — ⌘-drag them like any other. Clicking one reveals the hidden run.")
        ForEach(Array(utility.settings().spacers.enumerated()), id: \.element.id) { index, spacer in
            HStack(spacing: 8) {
                TextField("Label", text: Binding(
                    get: { spacer.label },
                    set: { label in utility.updateSpacer(id: spacer.id) { $0.label = label } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Stepper(value: Binding(
                    get: { spacer.width },
                    set: { width in utility.updateSpacer(id: spacer.id) { $0.width = width } }),
                    in: 0...200, step: 4) {
                    Text(spacer.width > 0 ? "\(Int(spacer.width)) pt" : "Hug")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .controlSize(.small)
                Button(role: .destructive) {
                    utility.removeSpacer(id: spacer.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        HStack {
            Button("Add spacer") { utility.addSpacer() }
                .controlSize(.small)
            Button("Add label") { utility.addSpacer(label: "•") }
                .controlSize(.small)
        }
    }

    /// One row per attached display: which profile the bar takes while
    /// the pointer is on it.
    @ViewBuilder
    private var displayProfileEditor: some View {
        let screens = NSScreen.screens
        if screens.count > 1 {
            SettingLabel(title: "Profile per display",
                         subtitle: "The bar takes this profile while the pointer rests on that display — the mapping survives a logout, unlike a hotkey cycle.")
            ForEach(screens, id: \.self) { screen in
                if let key = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue {
                    LabeledContent {
                        Picker(selection: Binding(
                            get: { utility.settings().displayProfiles[key] ?? "" },
                            set: { utility.setDisplayProfile($0, displayKey: key) })) {
                            Text("No change").tag("")
                            ForEach(utility.settings().profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        } label: { EmptyView() }
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        SettingLabel(title: screen.localizedName)
                    }
                }
            }
        }
    }

    /// Where the plan put the item — the position-derived section, or
    /// the override that covers it.
    private func placement(of item: MenuBarItem) -> String {
        let override = utility.effectiveSection(for: item)
        if utility.lastPlan.alwaysHidden.contains(item) {
            return "covered · always"
        }
        if utility.lastPlan.hidden.contains(item) {
            if override == .hidden { return "covered" }
            return item.bounds.intersects(MenuBarItemLister.menuBarRow()) ? "hidden" : "in overflow"
        }
        return "shown"
    }

    /// The cover's look — only overrides draw one.
    @ViewBuilder
    private var appearanceControls: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.coverMaterial)) {
                Text("Blend In").tag(MenuBarSettings.CoverMaterial.blend)
                Text("Menu").tag(MenuBarSettings.CoverMaterial.menu)
                Text("HUD").tag(MenuBarSettings.CoverMaterial.hud)
                Text("Popover").tag(MenuBarSettings.CoverMaterial.popover)
                Text("Sheet").tag(MenuBarSettings.CoverMaterial.sheet)
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            SettingLabel(title: "Cover material",
                         subtitle: "The blur style a cover draws with.")
        }
        Toggle(isOn: utility.bindCoverTintEnabled()) {
            SettingLabel(title: "Tint the cover")
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
            SettingLabel(title: "Rounded ends")
        }
        Toggle(isOn: utility.bind(\.showCoverSeparator)) {
            SettingLabel(title: "Edge separators")
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
    @ViewState private var triggerSSID = ""
    @ViewState private var triggerHour = 9
    @ViewState private var triggerMinute = 0
    @ViewState private var triggerPercent = 20
    @ViewState private var actionKind = "hideAll"
    @ViewState private var actionProfile = ""
    @ViewState private var actionSeconds = 4.0
    @ViewState private var actionScript = ""

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
                Text("Battery falls to…").tag("battLow")
                Text("Battery rises past…").tag("battHigh")
                Text("Wi-Fi joins").tag("wifiJoin")
                Text("Wi-Fi changes").tag("wifiAny")
                Text("Wi-Fi drops").tag("wifiLeft")
                Text("Mic goes live").tag("micOn")
                Text("Mic goes quiet").tag("micOff")
                Text("Focus turns on").tag("focusOn")
                Text("Focus turns off").tag("focusOff")
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if triggerKind == "app" {
                TextField("bundle id", text: $triggerBundleID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            if triggerKind == "wifiJoin" {
                TextField("network name", text: $triggerSSID)
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
            if triggerKind == "battLow" || triggerKind == "battHigh" {
                TextField("%", value: $triggerPercent, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
            }
        }

        HStack(spacing: 6) {
            Picker(selection: $actionKind) {
                Text("Apply profile").tag("profile")
                Text("Hide all").tag("hideAll")
                Text("Show all").tag("showAll")
                Text("Reveal for…").tag("reveal")
                Text("Run script").tag("script")
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
            if actionKind == "script" {
                TextField("command", text: $actionScript)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
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
        if triggerKind == "wifiJoin" && triggerSSID.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if actionKind == "reveal" && actionSeconds < 1 { return false }
        if actionKind == "script" && actionScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
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
        case "battLow": trigger = .batteryBelow(percent: min(100, max(1, triggerPercent)))
        case "battHigh": trigger = .batteryAbove(percent: min(100, max(1, triggerPercent)))
        case "wifiJoin": trigger = .wifiJoined(
            ssid: triggerSSID.trimmingCharacters(in: .whitespaces))
        case "wifiAny": trigger = .wifiJoined(ssid: "")
        case "wifiLeft": trigger = .wifiLeft
        case "micOn": trigger = .microphoneInUse
        case "micOff": trigger = .microphoneIdle
        case "focusOn": trigger = .focusEnabled
        case "focusOff": trigger = .focusDisabled
        default: trigger = .screenUnlocked
        }
        let action: MenuBarTriggerAction
        switch actionKind {
        case "profile": action = .applyProfile(name: actionProfile)
        case "showAll": action = .showAll
        case "reveal": action = .reveal(seconds: actionSeconds)
        case "script": action = .runScript(
            command: actionScript.trimmingCharacters(in: .whitespacesAndNewlines))
        default: action = .hideAll
        }
        utility.addTriggerRule(trigger: trigger, action: action)
        // Focus rules read through INFocusStatusCenter — the add is the
        // explicit user action the consent prompt is allowed to ride.
        if trigger == .focusEnabled || trigger == .focusDisabled {
            MenuBarSystemTriggerSource.requestFocusAuthorization { _ in }
        }
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
