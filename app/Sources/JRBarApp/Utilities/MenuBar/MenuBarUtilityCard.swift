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

/// The card's disclosure body: who renders, what is hidden right now
/// and how to change it, the reveal gestures, then Extras, Overrides
/// and Advanced behind disclosures. Every row writes
/// `UtilitiesStore.state.menuBar` through the utility's
/// `bind`/`setSection`, which persists and re-applies.
struct MenuBarUtilityControls: View {
    let utility: MenuBarUtility
    @ViewState private var showAdvanced = false
    @ViewState private var showOverrides = false
    @ViewState private var showExtras = false

    /// The card body, Advanced folded; a render proof opens it.
    init(utility: MenuBarUtility, showAdvanced: Bool = false) {
        self.utility = utility
        _showAdvanced = ViewState(initialValue: showAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHidingBanner(status: utility.hidingStatus) { utility.perform($0) }
                .padding(.bottom, SettingsMetrics.xs)

            yourBar

            CardSectionHeader("Bring them back")
            Toggle(isOn: utility.bind(\.revealOnHover)) {
                SettingLabel(title: "Hover the blank stretch",
                             subtitle: "Rest the pointer on the empty bar left of the icon to draw the hidden items.")
            }
            if utility.settings().revealOnHover {
                MenuBarHoverTimingControls(utility: utility)
            }
            Toggle(isOn: utility.bind(\.revealOnClick)) {
                SettingLabel(title: "Click the blank stretch",
                             subtitle: "A click on the empty bar left of the icon, or on the icon's edge.")
            }
            Toggle(isOn: utility.bind(\.revealOnScroll)) {
                SettingLabel(title: "Scroll over the bar",
                             subtitle: "A swipe or a scroll wheel anywhere on the menu bar.")
            }
            Picker(selection: utility.bind(\.rehideMode)) {
                Text("After a delay").tag(MenuBarSettings.RehideMode.timed)
                Text("When you click elsewhere").tag(MenuBarSettings.RehideMode.untilClick)
                Text("When you switch apps").tag(MenuBarSettings.RehideMode.focusChange)
            } label: {
                SettingLabel(title: "Tuck away",
                             subtitle: "On a clock once the pointer leaves the bar, when a click lands outside it, or when another app comes to the front.")
            }
            .pickerStyle(.menu)
            .padding(.vertical, SettingsMetrics.rowPadding)
            if utility.settings().rehideMode == .timed {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: utility.bind(\.rehideSeconds), in: MenuBarSettings.rehideRange)
                            .frame(width: 160)
                        ValueText(text: SettingsStore.seconds(utility.settings().rehideSeconds))
                    }
                } label: {
                    SettingLabel(title: "Click and scroll delay",
                                 subtitle: "Deliberate reveals use this timer. Hover has its own delay.")
                }
            }
            Picker(selection: utility.bind(\.revealStyle)) {
                Text("On the bar — Ice, Hidden Bar").tag(MenuBarSettings.RevealStyle.inline)
                Text("Item Bar — Bartender").tag(MenuBarSettings.RevealStyle.bar)
            } label: {
                SettingLabel(title: "Reveal style",
                             subtitle: "On the bar draws the hidden items where they sit, so you can ⌘-drag one right of the icon to bring it back; whatever does not fit waits in the Item Bar. The Item Bar leaves the row untouched.")
            }
            .pickerStyle(.menu)
            .padding(.vertical, SettingsMetrics.rowPadding)
            Toggle(isOn: utility.bind(\.hideShownWhileRevealing)) {
                SettingLabel(title: "Hide shown items while revealing",
                             subtitle: "Bartender's swap: while a reveal is out, the bar shows only the hidden run.")
            }
            Toggle(isOn: utility.bind(\.showForUpdates)) {
                SettingLabel(title: "Show for updates",
                             subtitle: showForUpdatesNote)
            }
            LabeledContent {
                Button("Show Item Bar") { utility.bar.toggle() }
                    .controlSize(.small)
                    .help("For keyboard search, choose Item Bar under Reveal style and use the Toggle hidden items shortcut. Escape clears the filter.")
            } label: {
                SettingLabel(title: "Hidden items as tiles",
                             subtitle: "A glass strip under the menu bar with a live tile per hidden item — also on the JR-Bar icon's right-click menu.")
            }
            MenuBarItemBarAnchorRow(utility: utility)
            if utility.glyphsNeedScreenRecording {
                CardNote("Tiles show app icons because Screen Recording is off. With it, each tile is the item's own glyph, photographed while it was still drawn.",
                         symbol: "photo")
            }

            if utility.hidingStatus.fix != .openAccessibility {
                if !utility.accessibilityGranted {
                    HStack(spacing: SettingsMetrics.s) {
                        CardNote("Accessibility lets Menu Bar see where every item sits and click tiles through. Without it the boundary still works, but the list and the tiles go blind.",
                                 symbol: "exclamationmark.triangle.fill", tint: .orange)
                        Spacer(minLength: SettingsMetrics.s)
                        Button("Open Settings") { utility.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                    .padding(.top, SettingsMetrics.s)
                }
            }

            CardSectionHeader("More")
            DisclosureGroup(isExpanded: $showExtras) {
                Toggle(isOn: utility.bind(\.hideUnderNotch)) {
                    SettingLabel(title: "Keep items out of the notch",
                                 subtitle: "An item that lands in the notch band is invisible anyway — it moves to the hidden run, where the Item Bar still reaches it.")
                }
                Toggle(isOn: utility.bind(\.hideOnMenuOverlap)) {
                    SettingLabel(title: "Hide items under app menus",
                                 subtitle: "On a crowded bar the front app's menus draw over items — those hide instead of sitting unreachable.")
                }
                Toggle(isOn: utility.bind(\.barUnderlay)) {
                    SettingLabel(title: "Tint the whole bar",
                                 subtitle: "The cover's material and tint drawn under the full menu bar row, on every display.")
                }
                deskProfileEditor
                displayProfileEditor
            } label: {
                SettingLabel(title: "Extras",
                             subtitle: "The bar underlay, profiles per desk and per display, and what the notch and menus cover.")
            }

            DisclosureGroup(isExpanded: $showOverrides) {
                SettingLabel(title: "Cover in place",
                             subtitle: "Cover and Always mask an item where it sits. Auto follows its position in the menu bar.")
                    .padding(.vertical, SettingsMetrics.xs)
                ForEach(hideable, id: \.id) { item in
                    overrideRow(item)
                }
                appearanceControls
                    .cardHeading()
            } label: {
                SettingLabel(title: "Overrides",
                             subtitle: "Hide an item without moving it, and the look of its cover.")
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                managerControls
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
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: utility.itemSpacingBinding,
                               in: MenuBarSettings.itemSpacingRange, step: 1)
                            .frame(width: 160)
                        ValueText(text: utility.settings().itemSpacing > 0
                                  ? "\(utility.settings().itemSpacing) pt" : "System")
                    }
                } label: {
                    SettingLabel(title: "Custom spacing",
                                 subtitle: "An exact gap in points — the presets above all live on this dial.")
                }
                if let error = utility.spacingError {
                    MenuBarSpacingFailureRow(message: error, retry: utility.retrySpacing)
                }
                MenuBarSpacingRelaunchRow(utility: utility)
                fitEdgeControls
                MenuBarProfilesControls(utility: utility)
                MenuBarAutomationControls(utility: utility)
            } label: {
                SettingLabel(title: "Advanced",
                             subtitle: "Item spacing, profiles, the ⌘⇧K command bar, hotkeys and rules.")
            }
        }
        .onAppear { utility.refreshListing() }
    }

    /// The model in one place: position is the setting. The JR-Bar icon is
    /// the divider; what is left of it is hidden and what is right of it
    /// stays. The card shows the bar as it sits, says which engine is
    /// hiding and why, offers the old saved list as suggestions, and
    /// lists what JR-Bar believes about the bar right now.
    @ViewBuilder
    private var yourBar: some View {
        CardSectionHeader("Your bar")
        Text(MenuBarPositionCopy.model)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, SettingsMetrics.xs)
        if utility.dividerHintShown {
            MenuBarDividerHint { utility.dismissDividerHint() }
                .padding(.bottom, SettingsMetrics.xs)
        }
        if let suggestions = utility.suggestionsContent {
            MenuBarSuggestionsPanel(content: suggestions) { utility.forgetSuggestion($0) }
                .padding(.bottom, SettingsMetrics.xs)
        }
        let content = utility.positionContent
        MenuBarInventoryNotice(state: utility.inventoryState)
            .padding(.bottom, SettingsMetrics.xs)
        if content.isEmpty {
            CardNote(utility.inventoryState == .complete
                     ? "No menu bar items were found in the completed scan."
                     : "Nothing listed yet. Apps with a menu bar item appear here once Accessibility can read the bar.",
                     symbol: "menubar.rectangle")
        } else {
            MenuBarPositionDiagram(content: content) { entry, section in
                utility.setSection(section, for: entry.item.id)
            }
            if content.parked > 0 {
                CardNote(MenuBarPositionCopy.remainder(count: content.parked), symbol: "tray.full")
                    .padding(.top, SettingsMetrics.xs)
            }
            HStack(spacing: SettingsMetrics.s) {
                Button("Show hidden items") { utility.toggleHiddenSection() }
                    .controlSize(.small)
                    .help("Draw the hidden items on the bar so you can hold ⌘ and drag one right of the icon")
                Text(MenuBarPositionCopy.cannotMove)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, SettingsMetrics.xs)
        }
        CardNote(MenuBarPositionCopy.engineExplanation, symbol: "gearshape.2")
            .padding(.top, SettingsMetrics.xs)
        if utility.running {
            CardSectionHeader("What JR-Bar sees")
            MenuBarDividerReadoutView(readout: utility.dividerReadout)
                .padding(.bottom, SettingsMetrics.xs)
        }
    }

    /// Who hides, how the picks get made, and the bar-wide overlays —
    /// everything that is not the model itself, folded away in Advanced.
    @ViewBuilder
    private var managerControls: some View {
        LabeledContent {
            Text(utility.engineLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            SettingLabel(title: "Engine", subtitle: "What is doing the hiding right now.")
        }
        Picker(selection: utility.providerBinding) {
            Text("JR-Bar").tag(MenuBarProvider.jrbar)
            ExternalProviderOption(name: "Bartender", value: MenuBarProvider.bartender, installed: ExternalProviders.bartender.installed)
            ExternalProviderOption(name: "Ice", value: MenuBarProvider.ice, installed: ExternalProviders.ice.installed)
            ExternalProviderOption(name: "Hidden Bar", value: MenuBarProvider.hiddenBar, installed: ExternalProviders.hiddenBar.installed)
        } label: {
            SettingLabel(title: "Render with",
                         subtitle: "Choosing another app opens it and parks JR-Bar's hiding.")
        }
        .pickerStyle(.menu)
        .padding(.vertical, SettingsMetrics.rowPadding)
        if let note = utility.providerNote {
            HStack(spacing: SettingsMetrics.s) {
                CardNote(note, symbol: "arrow.triangle.2.circlepath")
                if utility.externalURL != nil {
                    Spacer(minLength: SettingsMetrics.s)
                    Button("Open") { utility.openExternal() }
                        .controlSize(.small)
                }
            }
        }
        CardNote("Everything left of the JR-Bar icon is tucked away. ⌘-drag an item across the icon, or drag its tile below, to hide or show it.")
            .padding(.vertical, SettingsMetrics.xs)
        if !utility.runningRivals.isEmpty {
            rivalsGuard
        }
        HStack(spacing: SettingsMetrics.s) {
            Menu("Hide all") {
                Button("For 5 minutes") { utility.hideAllListed(for: 5 * 60) }
                Button("For an hour") { utility.hideAllListed(for: 60 * 60) }
            } primaryAction: {
                utility.hideAllListed()
            }
            .controlSize(.small)
            .fixedSize()
            .help("Tuck every item away for now — your picks stay as they are, and Restore brings them back")
            .accessibilityLabel("Hide all menu bar items")
            Menu("Show everything") {
                Button("For 5 minutes") { utility.showEverythingNow(for: 5 * 60) }
                Button("For an hour") { utility.showEverythingNow(for: 60 * 60) }
            } primaryAction: {
                utility.showEverythingNow()
            }
            .controlSize(.small)
            .fixedSize()
            .help("Bring every hidden item back for now — nothing forgets what you hid")
            .accessibilityLabel("Show everything on the menu bar")
            if utility.activeOverlay != nil {
                Button("Restore") { utility.restoreCuratedBar() }
                    .controlSize(.small)
                    .help("Back to your own picks")
                Button("Keep") { utility.keepOverlay() }
                    .controlSize(.small)
                    .help(utility.activeOverlay == .hideEverything
                          ? "Make it stick: every listed app becomes Hidden"
                          : "Make it stick: every app becomes Shown and your hidden picks are cleared")
            }
        }
        .padding(.vertical, SettingsMetrics.xs)
    }

    /// Another manager running beside ours: say what it costs and offer
    /// the two ways out — never automatic.
    @ViewBuilder
    private var rivalsGuard: some View {
        ForEach(utility.runningRivals, id: \.name) { rival in
            HStack(spacing: SettingsMetrics.s) {
                CardNote("\(rival.name) is also managing the menu bar. Two managers fight — its hiding can undo what JR-Bar hides.",
                         symbol: "exclamationmark.triangle.fill", tint: .orange)
                Spacer(minLength: SettingsMetrics.s)
                if rival.handoff != nil {
                    Button("Hand over") { utility.handOver(to: rival) }
                        .controlSize(.small)
                        .help("Let \(rival.name) render the bar; JR-Bar's engine parks")
                }
                Button("Quit \(rival.name)") { utility.quitRival(rival) }
                    .controlSize(.small)
            }
        }
    }

    /// What "show for updates" can honestly promise on this engine, and
    /// which items it listens to.
    private var showForUpdatesNote: String {
        let watched = utility.settings().curation.updateWatch.count
        let scope = watched == 0
            ? "Every hidden item counts until you mark some with Show When It Changes in a tile's menu."
            : "Only the \(watched == 1 ? "item" : "\(watched) items") marked Show When It Changes interrupt."
        return "A hidden item that updates itself — a clock's minute, a VPN's \"Connected\" — reveals the run for a moment. " + scope
    }

    /// Every listed item the utility could hide, in bar order.
    private var hideable: [MenuBarItem] {
        utility.listedItems.filter { !MenuBarItemLister.isProtected($0) }
    }

    /// The override picker for one item.
    private func overrideRow(_ item: MenuBarItem) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.xs) {
            LabeledContent {
                Picker(selection: Binding(
                    get: { utility.effectiveSection(for: item) },
                    set: { utility.setCoverOverride($0, for: item.id) }
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
                    Text(item.title.map { "\(item.displayName) · \($0)" } ?? item.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            LabeledContent("Search name") {
                TextField("Optional", text: Binding(
                    get: { utility.listedItems.first { $0.id == item.id }?.searchName ?? "" },
                    set: { utility.setSearchName($0, for: item) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search name for " +
                        (item.title.map { "\(item.displayName) · \($0)" } ?? item.displayName))
                    .disabled(utility.searchNameKey(for: item) == nil)
            }
            if utility.searchNameKey(for: item) == nil {
                Text("This item does not expose a unique stable identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The learned fit edge with a nudge and a reset, while the divider runs.
    @ViewBuilder
    private var fitEdgeControls: some View {
        if utility.running, let edge = utility.hider.fitEdge {
            LabeledContent {
                HStack(spacing: 6) {
                    ValueText(text: "\(Int(edge.rounded())) pt")
                    Button { utility.nudgeFitEdge(by: -4) } label: { Image(systemName: "minus") }
                        .controlSize(.small)
                        .help("Four points left")
                    Button { utility.nudgeFitEdge(by: 4) } label: { Image(systemName: "plus") }
                        .controlSize(.small)
                        .help("Four points right")
                    Button("Reset") { utility.resetFitEdge() }
                        .controlSize(.small)
                        .disabled(!utility.hider.fitEdgeLearned)
                }
            } label: {
                SettingLabel(title: "Fit edge on this screen",
                             subtitle: utility.hider.fitEdgeLearned
                                ? "Learned from macOS's overflow — nudge it if an icon keeps slipping behind the «."
                                : "Guessed from the notch — it learns from the overflow as items move.")
            }
        }
    }

    /// The desk the Mac sits at — its set of displays — and the profile
    /// the bar takes each time that set arrives, plus the other desks it
    /// remembers.
    @ViewBuilder
    private var deskProfileEditor: some View {
        let profiles = utility.settings().profiles
        let desks = utility.settings().curation.deskProfiles
        if let desk = utility.currentDesk, !profiles.isEmpty || !desks.isEmpty {
            LabeledContent {
                Picker(selection: Binding(
                    get: { desks.first { $0.key == desk.key }?.profileID ?? "" },
                    set: { utility.setProfileForCurrentDesk($0) })) {
                    Text("No change").tag("")
                    Text(MenuBarProfiles.noneName).tag(MenuBarProfiles.noneID)
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingLabel(title: "Profile at this desk",
                             subtitle: "\(desk.name). Taken once each time these displays arrive — docking, undocking, the lid shutting — so a profile you pick by hand holds until the desk changes.")
            }
            ForEach(desks.filter { $0.key != desk.key }, id: \.key) { other in
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(profileName(other.profileID))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button { utility.forgetDesk(key: other.key) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Forget this desk")
                    }
                } label: {
                    SettingLabel(title: other.name)
                }
            }
        }
    }

    private func profileName(_ id: String) -> String {
        if id == MenuBarProfiles.noneID { return MenuBarProfiles.noneName }
        return utility.settings().profiles.first { $0.id == id }?.name ?? "—"
    }

    /// One row per attached display: which profile the bar takes while
    /// the pointer is on it.
    @ViewBuilder
    private var displayProfileEditor: some View {
        let screens = NSScreen.screens
        if screens.count > 1 {
            SettingLabel(title: "Profile per display",
                         subtitle: "The bar takes this profile while the pointer rests on that display — it follows the pointer; a desk's profile follows the displays.")
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

    /// The cover's look — only overrides draw one.
    @ViewBuilder
    private var appearanceControls: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.coverMaterial)) {
                Text("Blend in").tag(MenuBarSettings.CoverMaterial.blend)
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

/// The Profiles rows: which profile is laid over your bar, a name field
/// that saves the current look, and — for the active profile — the
/// editor for what it changes. A profile is a delta over your bar plus
/// a look: switching swaps the layer, so nothing you picked for your
/// bar is ever rewritten.
private struct MenuBarProfilesControls: View {
    let utility: MenuBarUtility
    /// The save/rename field.
    @ViewState private var nameDraft = ""
    /// The active profile's editor.
    @ViewState private var showEditor = false

    var body: some View {
        SettingLabel(title: "Profiles",
                     subtitle: "A look plus what it changes about your bar. Apps you hide on your bar stay hidden in every profile that doesn't say otherwise.")
            .cardHeading()

        LabeledContent {
            Picker(selection: Binding(
                get: { utility.activeProfileID },
                set: { utility.applyProfile(id: $0) })) {
                Text(MenuBarProfiles.noneName).tag(MenuBarProfiles.noneID)
                ForEach(utility.settings().profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            SettingLabel(title: "Active",
                         subtitle: "Switching swaps the layer and the look — also from the icon's right-click menu.")
        }

        LabeledContent {
            HStack(spacing: 6) {
                TextField("Name", text: $nameDraft, prompt: Text("Name"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Save") {
                    if let id = utility.saveProfileAs(nameDraft) {
                        utility.applyProfile(id: id)
                        nameDraft = ""
                        showEditor = true
                    }
                }
                .controlSize(.small)
                .disabled(MenuBarProfiles.validName(nameDraft) == nil)
            }
        } label: {
            SettingLabel(title: "Save current look as",
                         subtitle: "The cover look, the reveal and the spacing — then pick below what the profile changes.")
        }

        if let profile = MenuBarProfiles.activeProfile(in: utility.settings()) {
            let canRename = MenuBarProfiles.canRename(id: profile.id, to: nameDraft,
                                                      in: utility.settings())
            HStack(spacing: 8) {
                Button("Rename to field") {
                    utility.renameProfile(id: profile.id, to: nameDraft)
                }
                .controlSize(.small)
                .disabled(!canRename)
                Button("Delete") {
                    utility.deleteProfile(id: profile.id)
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            if MenuBarProfiles.validName(nameDraft) != nil && !canRename {
                Text("Another profile already uses this name. Choose a different name to rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showEditor) {
                VStack(alignment: .leading, spacing: 2) {
                    if utility.profileSubjects.isEmpty {
                        Text("Nothing listed yet — the menu bar's items appear here once Accessibility can read them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(utility.profileSubjects) { subject in
                        profileRow(subject, profile: profile)
                    }
                }
                .padding(.top, 4)
            } label: {
                SettingLabel(title: "What “\(profile.name)” changes",
                             subtitle: "“Your bar” follows your own picks; anything else holds only while this profile is active.")
            }
        }
    }

    private func profileRow(_ subject: MenuBarProfileSubject,
                            profile: MenuBarSettings.Profile) -> some View {
        LabeledContent {
            Picker(selection: Binding<MenuBarItemSection?>(
                get: { profile.sections[subject.key] },
                set: { section in
                    utility.setProfileDelta(section, forItem: subject.key, profileID: profile.id)
                })) {
                Text("Your bar").tag(MenuBarItemSection?.none)
                Text("Auto").tag(MenuBarItemSection?.some(.shown))
                Text("Cover").tag(MenuBarItemSection?.some(.hidden))
                Text("Always").tag(MenuBarItemSection?.some(.alwaysHidden))
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: subject.item.owner?.icon ?? NSImage())
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(subject.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct MenuBarRuleProfilePicker: View {
    @Binding var selection: MenuBarRuleProfileSelection
    let settings: MenuBarSettings
    let allowsNoProfile: Bool

    var body: some View {
        let resolution = selection.resolve(in: settings)
        let available = resolution.isAvailable && (allowsNoProfile || resolution.name != nil)
        VStack(alignment: .leading, spacing: 4) {
            Picker("Profile", selection: $selection) {
                if allowsNoProfile {
                    Text("No profile").tag(MenuBarRuleProfileSelection.noProfile)
                } else if selection == .noProfile {
                    Text("Choose a profile").tag(MenuBarRuleProfileSelection.noProfile).disabled(true)
                }
                Text(MenuBarProfiles.noneName).tag(MenuBarRuleProfileSelection.none)
                if case .saved(let id) = selection,
                   !settings.profiles.contains(where: { $0.id == id }) {
                    Text("Unavailable").tag(selection).disabled(true)
                }
                ForEach(settings.profiles) { profile in
                    let choice = MenuBarRuleProfileSelection.saved(id: profile.id)
                    Text(profile.name).tag(choice).disabled(!choice.resolve(in: settings).isAvailable)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if !available {
                Text("Choose another profile to add this rule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 200, alignment: .leading)
    }
}

/// The "while" rules: a level that holds a layer, a scene or the agents'
/// quiet for exactly as long as it lasts — one rule instead of a fragile
/// pair, and nothing it did outlives it.
private struct MenuBarWhileRulesControls: View {
    let utility: MenuBarUtility

    @ViewState private var conditionKind = "mic"
    @ViewState private var negated = false
    @ViewState private var bundleID = ""
    @ViewState private var ssid = ""
    @ViewState private var percent = 20
    @ViewState private var startHour = 9
    @ViewState private var endHour = 17
    @ViewState private var barEffect = "quiet"
    @ViewState private var profileSelection = MenuBarRuleProfileSelection.noProfile
    @ViewState private var scene = ""
    @ViewState private var quietAgents = false

    var body: some View {
        let rules = utility.settings().curation.stateRules
        SettingLabel(title: "While…",
                     subtitle: "A level that holds a layout, a light scene or quiet agents for as long as it lasts — and puts everything back when it ends. Your own picks are never rewritten.")
            .cardHeading()
        ForEach(rules) { rule in
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { rule.enabled },
                    set: { utility.setStateRule(id: rule.id, enabled: $0) }
                )) {
                    Text(rule.summary)
                        .font(.callout)
                        .lineLimit(2)
                }
                Button { utility.deleteStateRule(id: rule.id) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        let holding = utility.holdingStateRules
        if !holding.isEmpty {
            Text("Holding now: " + holding.map(\.condition.label).joined(separator: "; "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            HStack(spacing: 6) {
                RuleWord("While")
                Toggle("Not", isOn: $negated)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Hold while the level is not true — e.g. while not on the office Wi-Fi")
                Picker(selection: $conditionKind) {
                    Text("Microphone is live").tag("mic")
                    Text("A Focus is on").tag("focus")
                    Text("Screen is locked").tag("locked")
                    Text("On battery").tag("battery")
                    Text("Battery at or below…").tag("battLow")
                    Text("On Wi-Fi…").tag("wifi")
                    Text("App is in front…").tag("front")
                    Text("App is running…").tag("running")
                    Text("Between hours…").tag("time")
                    Text("Lid is closed").tag("lid")
                    Text("External display attached").tag("display")
                    Divider()
                    Text("Agents are working").tag("working")
                    Text("An agent needs you").tag("asking")
                    Text("Agents are idle").tag("idle")
                    Text("Usage headroom at or below…").tag("quota")
                    Text("SidePulse is connected").tag("sidePulse")
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if conditionKind == "front" || conditionKind == "running" {
                    Picker(selection: $bundleID) {
                        Text("Choose an app").tag("")
                        ForEach(Self.runningApps(), id: \.id) { app in
                            Text(app.name).tag(app.id)
                        }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if conditionKind == "wifi" {
                    TextField("network name", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    if let current = MenuBarSystemTriggerSource.currentSSID() {
                        Button("Use “\(current)”") { ssid = current }
                            .controlSize(.small)
                    }
                }
                if conditionKind == "battLow" || conditionKind == "quota" {
                    TextField("%", value: $percent, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                }
                if conditionKind == "time" {
                    TextField("from", value: $startHour, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 34)
                    Text("to").font(.callout)
                    TextField("to", value: $endHour, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 34)
                }
            }

            HStack(spacing: 6) {
                RuleWord("Hold")
                Picker(selection: $barEffect) {
                    Text("Tuck everything away").tag("quiet")
                    Text("Show everything").tag("show")
                    Text("Leave the bar").tag("none")
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                MenuBarRuleProfilePicker(selection: $profileSelection,
                                         settings: utility.settings(), allowsNoProfile: true)
                .help("A profile laid over your bar while the rule holds")
            }
            HStack(spacing: 6) {
                Picker(selection: $scene) {
                    Text("Lights as they are").tag("")
                    ForEach(EffectScene.allCases) { scene in
                        Text("\(scene.label) scene").tag(scene.rawValue)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("The LED scene while the rule holds — yours comes back after")
                Toggle("Quiet agents", isOn: $quietAgents)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("The daemon's quiet hours while the rule holds, ended after")
                Button("Add") { addRule() }
                    .controlSize(.small)
                    .disabled(!draftValid)
            }
        }
        .padding(SettingsMetrics.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InsetPanel())
        .padding(.top, SettingsMetrics.xs)
    }

    /// Running regular apps, by name — the picker instead of a bundle id.
    /// Read from the `RunningApps` index, not asked of each app per render.
    private static func runningApps() -> [(id: String, name: String)] {
        RunningApps.shared.apps
            .filter { $0.policy != .prohibited }
            .compactMap { app in
                app.bundleID.map { ($0, app.name ?? $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var effects: [MenuBarRuleEffect] {
        var out: [MenuBarRuleEffect] = []
        switch barEffect {
        case "quiet": out.append(.quietBar)
        case "show": out.append(.showEverything)
        default: break
        }
        if let name = profileSelection.resolve(in: utility.settings()).name {
            out.append(.useProfile(name: name))
        }
        if !scene.isEmpty { out.append(.ledScene(scene: scene)) }
        if quietAgents { out.append(.quietAgents) }
        return out
    }

    private var draftValid: Bool {
        guard profileSelection.resolve(in: utility.settings()).isAvailable else { return false }
        if (conditionKind == "front" || conditionKind == "running") && bundleID.isEmpty { return false }
        if conditionKind == "wifi" && ssid.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return !effects.isEmpty
    }

    private func addRule() {
        guard draftValid else { return }
        let condition: MenuBarCondition
        switch conditionKind {
        case "focus": condition = .focusOn
        case "locked": condition = .screenLocked
        case "battery": condition = .onBattery
        case "battLow": condition = .batteryAtOrBelow(percent: min(100, max(1, percent)))
        case "wifi": condition = .wifiIs(ssid: ssid.trimmingCharacters(in: .whitespaces))
        case "front": condition = .appFrontmost(bundleID: bundleID)
        case "running": condition = .appRunning(bundleID: bundleID)
        case "time": condition = .timeBetween(startMinute: min(23, max(0, startHour)) * 60,
                                              endMinute: min(24, max(0, endHour)) * 60 % 1440)
        case "lid": condition = .lidClosed
        case "display": condition = .externalDisplay
        case "working": condition = .agentsWorking
        case "asking": condition = .agentNeedsYou
        case "idle": condition = .agentsIdle
        case "quota": condition = .quotaAtOrBelow(percent: min(100, max(1, percent)))
        case "sidePulse": condition = .sidePulseConnected
        default: condition = .microphoneLive
        }
        utility.addStateRule(MenuBarStateRule(condition: condition, negated: negated,
                                              effects: effects))
        // Focus reads through INFocusStatusCenter — the add is the
        // explicit user action the consent prompt is allowed to ride.
        if condition == .focusOn {
            MenuBarSystemTriggerSource.requestFocusAuthorization { _ in }
        }
    }
}

/// The Automate rows: the ⌘⇧K command bar, the global hotkeys, the
/// trigger rules, and a word on ordering the bar — the actions half of the
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
    @ViewState private var actionProfileSelection = MenuBarRuleProfileSelection.none
    @ViewState private var actionSeconds = 4.0
    @ViewState private var actionScript = ""
    @ViewState private var actionMinutes = 60

    /// The button names the key that opens the palette — whatever the
    /// Shortcuts page bound it to, or nothing once it is switched off.
    private var commandBarTitle: String {
        guard let bound = utility.resolvedHotkeyBindings().first(where: { $0.action == .commandBar }),
              bound.enabled else { return "Open" }
        return "Open (" + bound.displayString + ")"
    }

    var body: some View {
        SettingLabel(title: "Automate",
                     subtitle: "The command bar, global hotkeys, and rules that fire on their own.")
            .cardHeading()

        LabeledContent {
            Button(commandBarTitle) { utility.openCommandBar() }
                .controlSize(.small)
        } label: {
            SettingLabel(title: "Command bar",
                         subtitle: "JR-Bar's palette: asks and sessions, menu bar items, the front app's menus, quiet, lights and windows — type to find, ↩ to run, ⌘K for every verb.")
        }

        // The keys themselves are set on Shortcuts, their one home: each
        // has a recorder there, and this card only says where.
        LabeledContent {
            Button("Open Shortcuts") { utility.onOpenShortcuts?() }
                .buttonStyle(.link)
        } label: {
            SettingLabel(title: "Hotkeys",
                         subtitle: "\(utility.resolvedHotkeyBindings().filter(\.enabled).count) of \(utility.resolvedHotkeyBindings().count) on. Record or switch them off on Shortcuts.")
        }

        if !utility.failedHotkeyActions.isEmpty {
            Text("macOS refused to register: \(utility.failedHotkeyActions.map { hotkeyTitle($0) }.sorted().joined(separator: ", ")). The keys likely belong to another app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        rulesSection
        MenuBarWhileRulesControls(utility: utility)
        orderNote
    }

    private func hotkeyTitle(_ action: MenuBarHotkeyAction) -> String {
        switch action {
        case .toggleReveal: return "Toggle hidden items"
        case .revealAlwaysHidden: return "Reveal always-hidden items"
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
                     subtitle: "When something happens, the bar reacts — lock, unlock, an app, a time, the charger, a display, the lid, and what your agents are doing.")
            .cardHeading()
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

        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            HStack(spacing: 6) {
                RuleWord("When")
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
                    Divider()
                    Text("App launches").tag("appLaunch")
                    Text("App quits").tag("appQuit")
                    Text("Display connects").tag("displayOn")
                    Text("Display disconnects").tag("displayOff")
                    Text("Lid closes").tag("lidClosed")
                    Text("Lid opens").tag("lidOpened")
                    Divider()
                    Text("Agents start working").tag("agentsWork")
                    Text("An agent needs you").tag("agentAsk")
                    Text("Agents finish").tag("agentsDone")
                    Text("Usage headroom falls to…").tag("quotaLow")
                    Text("SidePulse connects").tag("sidePulseOn")
                    Text("SidePulse disconnects").tag("sidePulseOff")
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if Self.appTriggerKinds.contains(triggerKind) {
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
                if triggerKind == "battLow" || triggerKind == "battHigh" || triggerKind == "quotaLow" {
                    TextField("%", value: $triggerPercent, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                }
            }

            HStack(spacing: 6) {
                RuleWord("Then")
                Picker(selection: $actionKind) {
                    Text("Apply profile").tag("profile")
                    Text("Hide all").tag("hideAll")
                    Text("Show all").tag("showAll")
                    Text("Reveal for…").tag("reveal")
                    Text("Run script").tag("script")
                    Divider()
                    Text("Keep awake for…").tag("awake")
                    Text("Keep awake until released").tag("awakeHold")
                    Text("Let the Mac sleep").tag("awakeOff")
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if actionKind == "profile" {
                    MenuBarRuleProfilePicker(selection: $actionProfileSelection,
                                             settings: utility.settings(), allowsNoProfile: false)
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
                if actionKind == "awake" {
                    TextField("min", value: $actionMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                }
                Button("Add rule") { addRule() }
                    .controlSize(.small)
                    .disabled(!ruleDraftValid)
            }
        }
        .padding(SettingsMetrics.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InsetPanel())
        .padding(.top, SettingsMetrics.xs)
    }

    /// The trigger kinds that name an app by bundle id.
    private static let appTriggerKinds: Set<String> = ["app", "appLaunch", "appQuit"]

    private var ruleDraftValid: Bool {
        if actionKind == "profile" && actionProfileSelection.resolve(in: utility.settings()).name == nil {
            return false
        }
        if Self.appTriggerKinds.contains(triggerKind)
            && triggerBundleID.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if triggerKind == "wifiJoin" && triggerSSID.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if actionKind == "reveal" && actionSeconds < 1 { return false }
        if actionKind == "awake"
            && !(1...MenuBarTriggerAction.holdAwakeMaxMinutes).contains(actionMinutes) { return false }
        if actionKind == "script" && actionScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    private func addRule() {
        guard ruleDraftValid else { return }
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
        case "appLaunch": trigger = .appLaunched(
            bundleID: triggerBundleID.trimmingCharacters(in: .whitespaces))
        case "appQuit": trigger = .appQuit(
            bundleID: triggerBundleID.trimmingCharacters(in: .whitespaces))
        case "displayOn": trigger = .displayConnected
        case "displayOff": trigger = .displayDisconnected
        case "lidClosed": trigger = .lidClosed
        case "lidOpened": trigger = .lidOpened
        case "agentsWork": trigger = .agentsStartedWorking
        case "agentAsk": trigger = .agentNeedsYou
        case "agentsDone": trigger = .agentsFinished
        case "quotaLow": trigger = .quotaBelow(percent: min(100, max(1, triggerPercent)))
        case "sidePulseOn": trigger = .sidePulseConnected
        case "sidePulseOff": trigger = .sidePulseDisconnected
        default: trigger = .screenUnlocked
        }
        let action: MenuBarTriggerAction
        switch actionKind {
        case "profile":
            guard let name = actionProfileSelection.resolve(in: utility.settings()).name else { return }
            action = .applyProfile(name: name)
        case "showAll": action = .showAll
        case "reveal": action = .reveal(seconds: actionSeconds)
        case "script": action = .runScript(
            command: actionScript.trimmingCharacters(in: .whitespacesAndNewlines))
        case "awake": action = .holdAwake(seconds: MenuBarTriggerAction.awakeSeconds(minutes: actionMinutes))
        case "awakeHold": action = .holdAwake(seconds: nil)
        case "awakeOff": action = .releaseAwake
        default: action = .hideAll
        }
        utility.addTriggerRule(trigger: trigger, action: action)
        // Focus rules read through INFocusStatusCenter — the add is the
        // explicit user action the consent prompt is allowed to ride.
        if trigger == .focusEnabled || trigger == .focusDisabled {
            MenuBarSystemTriggerSource.requestFocusAuthorization { _ in }
        }
    }

    // MARK: Order

    /// The order is the hand's: a ⌘-drag, as macOS has always allowed.
    @ViewBuilder
    private var orderNote: some View {
        SettingLabel(title: "Order", subtitle: "⌘-drag items to order them.")
    }
}

/// The lead word of a rule-builder line — "When", "Then", "While",
/// "Hold" — so the pickers after it read as a sentence.
private struct RuleWord: View {
    let word: String

    init(_ word: String) { self.word = word }

    var body: some View {
        Text(word)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 40, alignment: .leading)
    }
}

struct MenuBarHoverTimingControls: View {
    let utility: MenuBarUtility

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowPadding) {
            HStack(spacing: 16) {
                SettingLabel(title: "Show after hovering",
                             subtitle: "How long the pointer rests before hidden items appear.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Slider(value: utility.bind(\.hoverRevealSeconds), in: MenuBarSettings.hoverRevealRange)
                        .frame(width: 160)
                        .accessibilityLabel("Show after hovering")
                    ValueText(text: "\(Int((utility.settings().hoverRevealSeconds * 1000).rounded())) ms")
                        .frame(width: 60, alignment: .trailing)
                }
            }
            if utility.settings().rehideMode == .timed {
                HStack(spacing: 16) {
                    SettingLabel(title: "Hide after leaving",
                                 subtitle: "How quickly hover reveals hide after you leave the bar.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Slider(value: utility.bind(\.hoverHideSeconds), in: MenuBarSettings.hoverHideRange)
                            .frame(width: 160)
                            .accessibilityLabel("Hide after leaving")
                        ValueText(text: "\(Int((utility.settings().hoverHideSeconds * 1000).rounded())) ms")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
    }
}
