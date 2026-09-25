import AppKit
import JRBarCore
import SwiftUI

/// The Effect Studio's three rooms. Effects: library (left), the selected
/// effect with its live preview and parameters (centre), and the
/// assignments (right). Program: the hand-written LEDS.LED editor.
/// Moments: the ambient cues the lights play, by name.
struct EffectStudioView: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        Group {
            switch store.mode {
            case .effects: effectsRoom
            case .program: LEDSStudioView(store: store, model: store.ledsStudio)
            case .moments: LightMomentsView(store: store)
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.ledPreviewsHeld, store.covered)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Room", selection: $store.mode) {
                    ForEach(EffectStudioStore.Mode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Effects to assign, a hand-written program, or the moments the lights play")
            }
        }
        .toolbar {
            if store.mode == .effects { effectsToolbar }
        }
        .overlay(alignment: .bottom) {
            if let text = store.lastError ?? store.status {
                WindowStatusCapsule(text: text, isError: store.lastError != nil)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: (store.lastError ?? store.status) == nil)
        .sheet(isPresented: $store.assigning) {
            AssignSheet(store: store)
        }
        .alert("Preview on hardware?", isPresented: $store.askingConsent) {
            Button("Preview") { store.grantConsent(and: store.selected) }
            Button("Cancel", role: .cancel) {
                store.askingConsent = false
                store.pendingHardwarePlay = nil
            }
        } message: {
            Text("The monitor will play this on the connected SidePulse hardware for a few seconds, then put the current light back. Attention and critical effects blink; they are clamped to 2 Hz. You will not be asked again.")
        }
        .alert("Save as Effect", isPresented: Binding(
            get: { store.savingEffect != nil },
            set: { if !$0 { store.savingEffect = nil } }
        )) {
            TextField("Name", text: $store.saveName)
            Button("Save") {
                if let effect = store.savingEffect { store.saveAsEffect(effect, name: store.saveName) }
                store.savingEffect = nil
            }
            .disabled(store.saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { store.savingEffect = nil }
        } message: {
            Text("Keeps \(store.savingEffect?.label ?? "this effect") with the parameters you set as a new effect in Yours. Assign it like any other; the original stays as it was.")
        }
        .alert("Pack already installed", isPresented: Binding(
            get: { store.packConflict != nil },
            set: { if !$0 { store.packConflict = nil } }
        )) {
            Button("Update pack") { store.updatePack() }
            Button("Keep installed copy", role: .cancel) { store.packConflict = nil }
        } message: {
            Text("A pack with this id is already installed. Update replaces the installed copy with \(store.packConflict?.name ?? "the file").")
        }
    }

    /// The effect library room: library, inspector, assignments.
    @ViewBuilder
    private var effectsRoom: some View {
        Group {
            if !store.isLive {
                WindowEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                 text: "The effect registry, packs and assignments live in the monitor. The studio fills in once the socket is live.",
                                 tint: .orange)
            } else if store.catalog == nil {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Loading effects…").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .delayedReveal()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    EffectLibraryPane(store: store)
                        .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
                    EffectInspectorPane(store: store)
                        .frame(minWidth: 380, idealWidth: 480)
                        .layoutPriority(1)
                    EffectAssignmentsPane(store: store)
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                }
            }
        }
    }

    /// Import, export and refresh belong to the effect library alone.
    @ToolbarContentBuilder
    private var effectsToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button { store.importPack() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                .help("Import a data-only effect pack (JSON v2); the monitor validates it")
                .disabled(!store.isLive)
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                if let effect = store.selected {
                    Button("Export “\(effect.label)”…") { store.exportPack(ids: [effect.id], suggestedName: effect.label) }
                    if let pack = effect.pack, let entry = store.catalog?.pack(pack) {
                        Button("Export pack “\(entry.name)” (\(entry.effectIDs.count))…") { store.exportPack(ids: entry.effectIDs, suggestedName: entry.name) }
                        Divider()
                        Button("Remove pack “\(entry.name)”…") { store.removePack(entry) }
                    }
                    Divider()
                }
                Button("Export every provider animation…") {
                    let ids = store.catalog?.effects.filter { $0.catalog == "provider_animation" }.map(\.id) ?? []
                    store.exportPack(ids: ids, suggestedName: "Provider animations")
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Write a data-only pack with the current parameters as defaults")
            .disabled(!store.isLive)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.reload() } label: {
                if store.loading {
                    DelayedWait { Label("Refresh", systemImage: "arrow.clockwise") }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help("Re-read the registry and assignments (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!store.isLive || store.loading)
        }
    }
}

// MARK: - Library

struct EffectLibraryPane: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        VStack(spacing: 0) {
            WindowSearchField(prompt: "Search effects", text: $store.search) {
                Menu {
                    Picker("Show", selection: $store.filter) {
                        ForEach(EffectStudioStore.LibraryFilter.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolVariant(store.filter == .all ? .none : .fill)
                        .foregroundStyle(store.filter == .all ? .secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter the library")
                .accessibilityLabel("Filter: \(store.filter.label)")
            }
            .padding(10)
            Divider()
            if store.groups.isEmpty {
                emptyState
            } else if snapshot {
                snapshotList
            } else {
                List(selection: $store.selectedID) {
                    ForEach(store.groups, id: \.title) { group in
                        Section {
                            ForEach(group.effects) { effect in
                                EffectLibraryRow(effect: effect, store: store,
                                                 uses: store.usage(of: effect),
                                                 selected: store.selectedID == effect.id)
                                    .tag(effect.id)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.effects.count)")
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @Environment(\.renderSnapshot) private var snapshot

    /// The library's rows laid out flat for a render proof's still, which
    /// draws no `List`.
    private var snapshotList: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.groups, id: \.title) { group in
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                    ForEach(group.effects) { effect in
                        EffectLibraryRow(effect: effect, store: store, uses: store.usage(of: effect),
                                         selected: store.selectedID == effect.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(store.selectedID == effect.id ? Color.accentColor.opacity(0.18) : .clear))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Which "nothing to show" applies: an empty catalog, a filter with
    /// no hits, or a search with no matches.
    @ViewBuilder
    private var emptyState: some View {
        if store.catalog?.effects.isEmpty ?? true {
            WindowEmptyState(symbol: "sparkles", title: "No effects installed",
                             text: "The registry is empty — import a pack from the toolbar to add some.")
        } else {
            VStack(spacing: 6) {
                WindowEmptyState(symbol: "magnifyingglass", title: store.search.isEmpty ? "Nothing in this filter" : "Nothing matches",
                                 text: store.search.isEmpty ? "No effect is in this part of the library." : "No effect's name or meaning fits the search.")
                    .frame(maxHeight: 240)
                if !store.search.isEmpty {
                    Button("Clear search") { store.search = "" }.buttonStyle(.link).font(.caption)
                }
                if store.filter != .all {
                    Button("Show all effects") { store.filter = .all }.buttonStyle(.link).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EffectLibraryRow: View {
    let effect: EffectDefinition
    @Bindable var store: EffectStudioStore
    let uses: [EffectAssignment]
    let selected: Bool

    /// The thumbnail plays at its authored count, capped where dots
    /// would shrink past readability.
    private var thumbnailLeds: Int { min(effect.preview?.ledCount ?? 8, 16) }

    var body: some View {
        let metrics = LEDStripPreview.dotMetrics(ledCount: thumbnailLeds, width: 54, dotSize: 5, spacing: 2, padded: false)
        HStack(spacing: 9) {
            LEDStripPreview(program: effect.preview?.program ?? "off", ledCount: thumbnailLeds,
                            style: .dots, dotSize: metrics.dotSize, spacing: metrics.spacing,
                            paused: !selected, showsBackground: false)
                .frame(width: 54)
                .padding(.vertical, 5)
                .padding(.horizontal, 5)
                .background(LEDStage(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(effect.label).lineLimit(1)
                    if !uses.isEmpty {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                            .help(store.usageSummary(of: effect) ?? "Used by an assignment")
                            .accessibilityLabel("Used by \(uses.count) assignment\(uses.count == 1 ? "" : "s")")
                    }
                }
                HStack(spacing: 4) {
                    if let pack = effect.pack {
                        Badge(text: pack, color: .purple)
                    }
                    if effect.safety.warns {
                        Badge(text: effect.safety.label, color: effect.safety == .critical ? .red : .orange)
                    }
                    Text(effect.role.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("\(effect.label)\(effect.pack.map { ", pack \($0)" } ?? "")\(effect.safety.warns ? ", \(effect.safety.label)" : "")\(uses.isEmpty ? "" : ", in use")")
        .contextMenu {
            Button("Assign…") { store.beginAssigning(effect) }
            // The consent alert replays `store.selected`; select first so
            // it previews this row's effect, not whatever is selected.
            Button("Preview on hardware") {
                store.selectedID = effect.id
                store.previewOnHardware(effect)
            }
            .disabled(!store.hasHardware)
            Divider()
            if EffectStudioYours.canSave(effect), !effect.parameters.isEmpty {
                Button("Save as Effect…") {
                    store.selectedID = effect.id
                    store.beginSaving(effect)
                }
                .disabled(store.yoursBusy)
            }
            if EffectStudioYours.isYours(effect) {
                Button("Delete from Yours") { store.deleteFromYours(effect) }
                    .disabled(store.yoursBusy)
            }
            Button("Export “\(effect.label)”…") { store.exportPack(ids: [effect.id], suggestedName: effect.label) }
            if let pack = effect.pack, let entry = store.catalog?.pack(pack) {
                Button("Export pack “\(entry.name)”…") { store.exportPack(ids: entry.effectIDs, suggestedName: entry.name) }
                Button("Remove pack “\(entry.name)”…") { store.removePack(entry) }
            }
            if !uses.isEmpty {
                Divider()
                ForEach(uses) { assignment in
                    Button("Remove from \(store.targetTitle(for: assignment)) (\(assignment.scope.label.lowercased()))") {
                        store.remove(assignment)
                    }
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Inspector

struct EffectInspectorPane: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        if let effect = store.selected {
            SnapshotScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(effect)
                    preview(effect)
                    facts(effect)
                    if effect.safety.warns || effect.id == "blink" || effect.parameter(named: "cadence") != nil {
                        safety(effect)
                    }
                    parameters(effect)
                    usedBy(effect)
                }
                .padding(WindowMetrics.margin)
            }
            .id(effect.id)
        } else {
            WindowEmptyState(symbol: "sparkles.rectangle.stack", title: "Pick an effect",
                             text: "Choose a look from the library to preview it, tune its parameters and assign it.")
        }
    }

    private func header(_ effect: EffectDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(effect.label).font(.title2.weight(.semibold))
                if let pack = effect.pack {
                    Badge(text: "pack · \(pack)", color: .purple)
                }
                Spacer()
                Text(effect.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Text(effect.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(effect.familyLine).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func preview(_ effect: EffectDefinition) -> some View {
        let program = store.previewProgram(for: effect)
        let leds = store.previewLedCount(for: effect)
        // Fit to the pane's narrowest content width so a wide device
        // never clips its end dots or their glow.
        let metrics = LEDStripPreview.dotMetrics(ledCount: leds, width: 336, dotSize: 20, spacing: 14, padded: true)
        let shape = store.previewSurface.map { "\($0.name)'s \(leds)-LED layout" } ?? "\(leds) LEDs, no strip or Dot connected"
        return VStack(alignment: .leading, spacing: 8) {
            LEDStripPreview(program: program, ledCount: leds, style: .dots, dotSize: metrics.dotSize, spacing: metrics.spacing)
                .frame(maxWidth: .infinity)
                .help("Previewing on \(shape)")
            if store.reduceMotion, let fallback = effect.reduceMotionFallback {
                Label("Reduce Motion is on — “\(store.catalog?.effect(fallback)?.label ?? fallback)” plays instead",
                      systemImage: "figure.walk.motion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                LEDStripPreview(program: program, ledCount: leds, style: .band, dotSize: 8, showsBackground: false)
                    .frame(maxWidth: 220)
                    .help("How the Screen Bar blends it")
                Spacer()
                if store.rendering {
                    DelayedWait(size: 12)
                    Text("Rendering…").font(.caption).foregroundStyle(.tertiary)
                }
                Button {
                    store.previewOnHardware(effect)
                } label: {
                    if store.hardwarePreviewActive {
                        Label("On \(store.playSurface.name) · \(store.hardwarePreviewRemaining) s", systemImage: "light.beacon.max.fill")
                    } else {
                        Label("Preview on \(store.playSurface.name)", systemImage: store.hasHardware ? "light.beacon.max" : "rectangle.topthird.inset.filled")
                    }
                }
                .disabled(store.hardwarePreviewActive || store.hardwarePreviewInFlight || !store.isLive)
                .help(store.previewSurface.map { "Play this effect on \($0.name) (\($0.ledCount) LEDs) for 5 seconds, then revert" }
                      ?? "No strip or Dot is connected — play it on the Screen Bar for 5 seconds, then revert")
                Button {
                    store.beginAssigning(effect)
                } label: {
                    Label("Assign…", systemImage: "plus.circle")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Use this effect for a state, scene, provider, project or device (⌘↩)")
            }
            .controlSize(.small)
        }
    }

    private func facts(_ effect: EffectDefinition) -> some View {
        // The chips are as long as the daemon's words; on a narrower window
        // they wrap onto a second line instead of truncating "menu bar,
        // Screen Bar, Pro" into "menu bar, Screen B…".
        WrapRow(spacing: 6, lineSpacing: 6) {
            FactChip(symbol: "shield", text: effect.safety.label, tint: effect.safety == .safe ? .secondary : (effect.safety == .critical ? .red : .orange))
            FactChip(symbol: "bolt", text: "\(effect.energy.label) energy", tint: .secondary)
            FactChip(symbol: "rectangle.3.group", text: effect.surfaces.map(Self.surfaceName).joined(separator: ", "), tint: .secondary)
            if let fallback = effect.reduceMotionFallback {
                FactChip(symbol: "figure.walk.motion", text: "Reduce Motion → \(store.catalog?.effect(fallback)?.label ?? fallback)", tint: .secondary)
            }
        }
        .font(.caption)
    }

    static func surfaceName(_ surface: String) -> String {
        switch surface {
        case "status_bar": return "menu bar"
        case "screen_bar": return "Screen Bar"
        case "sidepulse_pro": return "Pro"
        case "sidepulse_dot": return "Dot"
        case "glance_light": return "glance"
        case "settings_preview": return "preview"
        default: return surface.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func safety(_ effect: EffectDefinition) -> some View {
        let cadence = store.cadence(for: effect)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: effect.safety == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(effect.safety == .critical ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(effect.safety.warns ? "\(effect.safety.label) effect: it blinks hard-edged to be noticed." : "Hard blink, on a named cadence.")
                    .font(.callout.weight(.medium))
                if let cadence {
                    Text("Cadence “\(cadence.label)”: \(cadence.summary).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Every program is clamped to 2 Hz (1 Hz for saturated red) by the presentation compiler before it reaches a strip or the Screen Bar; Reduce Motion substitutes the static fallback.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .windowWell(padding: 12, tint: effect.safety == .critical ? .red : .orange)
    }

    @ViewBuilder
    private func parameters(_ effect: EffectDefinition) -> some View {
        HStack {
            WindowSectionTitle("Parameters", symbol: "slider.horizontal.3")
            if store.hasEdits(effect) {
                Button("Reset to defaults") { store.resetParameters(effect) }.controlSize(.small)
            }
            if EffectStudioYours.canSave(effect), !effect.parameters.isEmpty {
                Button("Save as Effect…") { store.beginSaving(effect) }
                    .controlSize(.small)
                    .disabled(store.yoursBusy)
                    .help("Keep these parameters as a new effect of your own, in Yours")
            }
        }
        if effect.parameters.isEmpty {
            Text("This effect has no parameters.").font(.callout).foregroundStyle(.tertiary)
        } else {
            let values = store.values(for: effect)
            VStack(spacing: 0) {
                ForEach(effect.parameters) { parameter in
                    EffectParameterRow(parameter: parameter, value: values[parameter.name] ?? parameter.defaultValue) { value in
                        store.setValue(value, for: parameter, of: effect)
                    }
                    if parameter.id != effect.parameters.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .windowWell(padding: 0)
        }
    }

    @ViewBuilder
    private func usedBy(_ effect: EffectDefinition) -> some View {
        let uses = store.usage(of: effect)
        if !uses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                WindowSectionTitle("Used by", symbol: "arrow.triangle.branch")
                ForEach(uses) { assignment in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                        Text("\(assignment.scope.label) · \(store.targetTitle(for: assignment))")
                        if !assignment.parameters.isEmpty, assignment.parameters != effect.defaultParameters {
                            Text("· tuned").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Remove") { store.remove(assignment) }.buttonStyle(.link).font(.caption)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct FactChip: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(tint == .secondary ? 0.08 : 0.14)))
        .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.8) : tint)
    }
}

// MARK: - Parameter controls

struct EffectParameterRow: View {
    let parameter: EffectParameter
    let value: JSONValue
    let onChange: (JSONValue) -> Void

    var body: some View {
        Group {
            if Self.picksOnItsOwnLine(parameter.control) {
                // A picker gets the row's full width under its words, so
                // neither squeezes the other in a narrow inspector.
                VStack(alignment: .leading, spacing: 8) {
                    label
                    control
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    control
                        .frame(minWidth: 180, maxWidth: 260, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(parameter.title)
    }

    /// The plain title and sentence; the raw id the daemon and packs use
    /// is the tooltip, for whoever writes a pack by hand.
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(parameter.title)
            if !parameter.description.isEmpty {
                Text(parameter.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(parameter.name)
    }

    /// Menus and colour pickers sit one per row; sliders, switches and
    /// number fields stay beside their words.
    static func picksOnItsOwnLine(_ control: EffectParameterControl) -> Bool {
        switch control {
        case .menu, .paletteEditor, .colorWell: return true
        case .toggle, .slider, .integerSlider, .stepper, .numberField: return false
        }
    }

    /// "All at once" from `all_at_once`.
    static func choiceTitle(_ choice: String) -> String {
        let words = choice.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private var unitSuffix: String {
        switch parameter.unit {
        case "seconds": return " s"
        case "degrees": return "°"
        case nil: return ""
        case let unit?: return " " + unit
        }
    }

    @ViewBuilder
    private var control: some View {
        switch parameter.control {
        case .toggle:
            Toggle("", isOn: Binding(get: { value.boolValue ?? false }, set: { onChange(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .slider(let range, let step):
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value.doubleValue ?? range.lowerBound }, set: { onChange(.number($0)) }), in: range, step: step)
                Text(Self.format(value.doubleValue ?? 0, step: step) + unitSuffix)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        case .integerSlider(let range):
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value.doubleValue ?? Double(range.lowerBound) }, set: { onChange(.number($0.rounded())) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                Text("\(Int(value.doubleValue ?? 0))" + unitSuffix)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        case .stepper(let range):
            HStack(spacing: 6) {
                TextField("", value: Binding(get: { Int(value.doubleValue ?? 0) }, set: { onChange(.number(Double($0))) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(width: 110)
                Stepper("", value: Binding(get: { Int(value.doubleValue ?? 0) }, set: { onChange(.number(Double($0))) }), in: range)
                    .labelsHidden()
            }
        case .numberField:
            TextField("", value: Binding(get: { value.doubleValue ?? 0 }, set: { onChange(.number($0)) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        case .menu(let choices):
            Picker("", selection: Binding(get: { value.stringValue ?? choices.first ?? "" }, set: { onChange(.string($0)) })) {
                ForEach(choices, id: \.self) { Text(Self.choiceTitle($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(value.stringValue ?? "")
        case .colorWell:
            HStack(spacing: 8) {
                Text(value.stringValue ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary)
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: value.stringValue ?? "#FFFFFF") ?? .white) },
                    set: { if let hex = NSColor($0).hexString { onChange(.string(hex)) } }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        case .paletteEditor(_, let maximum, let allowEmpty):
            PaletteEditor(colors: value.arrayValue?.compactMap(\.stringValue) ?? [], maximum: maximum, allowEmpty: allowEmpty) { colors in
                onChange(.array(colors.map(JSONValue.string)))
            }
        }
    }

    static func format(_ value: Double, step: Double) -> String {
        if step >= 1 { return String(format: "%.0f", value) }
        if step >= 0.1 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

struct PaletteEditor: View {
    let colors: [String]
    let maximum: Int
    let allowEmpty: Bool
    let onChange: ([String]) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if colors.isEmpty {
                Text(allowEmpty ? "None yet — tones come from the session's colour" : "None yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: hex) ?? .white) },
                    set: { color in
                        guard let hex = NSColor(color).hexString else { return }
                        var next = colors
                        next[index] = hex
                        onChange(next)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .contextMenu {
                    Button("Remove colour") {
                        var next = colors
                        next.remove(at: index)
                        onChange(next)
                    }
                }
                .help("\(hex) · right-click to remove")
            }
            if colors.count < maximum {
                Button {
                    // A new stop: a twin of the last colour, or a neutral start.
                    var next = colors
                    next.append(colors.last ?? "#4FC3F7")
                    if next.count == 1 { next.append("#B388FF") }   // palettes need two stops to mean anything
                    onChange(Array(next.prefix(maximum)))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a colour")
            }
            if !colors.isEmpty {
                Button {
                    onChange([])
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear the palette")
            }
        }
    }
}

// MARK: - Assignments

struct EffectAssignmentsPane: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Active scene").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Active scene", selection: Binding(get: { store.activeScene }, set: { store.setActiveScene($0) })) {
                    ForEach(EffectScene.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Scene assignments apply while that scene is active; asks and failures keep their reserved effects in every scene.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            Divider()
            if store.scenePacksSupported {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.scenePacks) { pack in
                        ScenePackRow(pack: pack, store: store)
                    }
                    // A pack that was selected and then removed still
                    // holds `active_scene_pack`; give the id a row so the
                    // state is visible and one tap restores the built-ins.
                    if let activeID = store.activeScenePackID,
                       !store.scenePacks.contains(where: { $0.id == activeID }) {
                        HStack(spacing: 8) {
                            Text("Active pack “\(activeID)” is no longer installed")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Use built-in scenes") { store.setActiveScenePack(nil) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        .padding(.vertical, 1)
                    }
                    Button("Import scene pack…") { store.importScenePack() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Installs a data-only JSON scene pack; the monitor validates the file")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if !store.providerPlayback.isEmpty || !store.devicePlayback.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What plays where").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(store.providerPlayback) { playback in
                        ProviderPlaybackRow(playback: playback, store: store)
                    }
                    ForEach(store.devicePlayback) { assignment in
                        DevicePlaybackRow(assignment: assignment, store: store)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if store.assignments != nil {
                EffectSituationPanel(store: store)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            if let document = store.assignments, !document.assignments.isEmpty {
                List {
                    ForEach(document.byScope, id: \.scope) { group in
                        Section {
                            ForEach(group.assignments) { assignment in
                                AssignmentRow(assignment: assignment, title: store.targetTitle(for: assignment),
                                              effect: store.catalog?.effect(assignment.effectID),
                                              note: store.assignmentNote(assignment),
                                              selected: store.selectedID == assignment.effectID) {
                                    store.remove(assignment)
                                } select: {
                                    store.selectedID = assignment.effectID
                                }
                            }
                        } header: {
                            Text(group.scope == .global ? "Everywhere" : group.scope.label)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                WindowEmptyState(symbol: "list.bullet.rectangle", title: "No assignments",
                                 text: "Everything follows the monitor's defaults. Pick an effect and choose Assign… to give a state, scene, provider or device its own look.")
            }
            Divider()
            HStack {
                Button {
                    if let effect = store.selected { store.beginAssigning(effect) }
                } label: {
                    Label("Assign selected effect…", systemImage: "plus")
                }
                .disabled(store.selected == nil)
                Spacer()
            }
            .controlSize(.small)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

/// An installed scene pack: name, its scenes, and an on-screen preview of
/// the pack's program (the daemon renders it at the connected LED count).
struct ScenePackRow: View {
    let pack: ScenePackSummary
    @Bindable var store: EffectStudioStore

    private var preview: EffectPreview? {
        store.scenePreview?.packID == pack.id ? store.scenePreview?.preview : nil
    }

    private var isActive: Bool { store.activeScenePackID == pack.id }

    var body: some View {
        HStack(spacing: 8) {
            if let preview {
                LEDStripPreview(program: preview.program, ledCount: preview.ledCount,
                                style: .band, dotSize: 6, showsBackground: false)
                    .frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(pack.displayName).lineLimit(1)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                Text(pack.scenes.isEmpty ? "No scenes listed" : pack.scenes.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isActive {
                Button("Built-in scenes") { store.setActiveScenePack(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Stop applying this pack's scene policies")
            } else {
                Button("Use this pack") { store.setActiveScenePack(pack.id) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Apply this pack's policies over the built-in scenes")
            }
            Button(preview == nil ? "Preview" : "Preview again") { store.previewScenePack(pack) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 1)
    }
}

/// A "what plays on X" row: the provider's tile and name, what its
/// working motion resolves to, and — indented underneath — the semantic
/// effects its events fire and any provider-instance rows. Tapping the
/// row jumps to the provider's assignment, or opens the assign sheet
/// pre-filled for it when the provider has no scope of its own.
struct ProviderPlaybackRow: View {
    let playback: EffectStudioStore.ProviderPlayback
    @Bindable var store: EffectStudioStore

    private func effectLabel(_ assignment: EffectAssignment) -> String {
        store.catalog?.effect(assignment.effectID)?.label ?? assignment.effectID
    }

    /// "Comet while working" for a provider animation, the plain effect
    /// name for any other provider-scope row, "default motion" for none.
    private var motionText: String {
        guard let assignment = playback.provider else { return "default motion" }
        let label = effectLabel(assignment)
        return store.catalog?.effect(assignment.effectID)?.catalog == "provider_animation"
            ? "\(label) while working" : label
    }

    /// `claude:work` → "work".
    private func instanceName(of assignment: EffectAssignment) -> String {
        guard let target = assignment.targetID, let colon = target.firstIndex(of: ":") else {
            return assignment.targetLabel
        }
        return String(target[target.index(after: colon)...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { store.focusPlayback(playback) } label: {
                HStack(spacing: 7) {
                    ProviderTile(style: ProviderStyle.style(for: playback.providerID), size: 16)
                    Text(playback.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(motionText)
                        .font(.caption)
                        .foregroundStyle(playback.provider == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playback.provider.map { "Show \(effectLabel($0))" }
                  ?? "No motion of its own — assign one to \(playback.name)")
            ForEach(playback.instances) { assignment in
                subline(assignment, detail: "instance \(instanceName(of: assignment))")
            }
            ForEach(playback.semantics) { assignment in
                subline(assignment, detail: assignment.targetLabel.lowercased())
            }
        }
        .padding(.vertical, 2)
    }

    private func subline(_ assignment: EffectAssignment, detail: String) -> some View {
        Button { store.selectedID = assignment.effectID } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("\(effectLabel(assignment)) on \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(effectLabel(assignment))")
    }
}

/// A device-scope row of the "what plays where" block: the device's
/// name and the effect it plays; a linked Dot's shadowing caveat shows.
struct DevicePlaybackRow: View {
    let assignment: EffectAssignment
    @Bindable var store: EffectStudioStore

    var body: some View {
        Button { store.selectedID = assignment.effectID } label: {
            HStack(spacing: 7) {
                Image(systemName: "lightstrip")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.targetTitle(for: assignment)).font(.callout).lineLimit(1)
                    if let note = store.assignmentNote(assignment) {
                        Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(store.catalog?.effect(assignment.effectID)?.label ?? assignment.effectID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(store.catalog?.effect(assignment.effectID)?.label ?? assignment.effectID)")
        .padding(.vertical, 2)
    }
}

struct AssignmentRow: View {
    let assignment: EffectAssignment
    let title: String
    let effect: EffectDefinition?
    /// A caveat under the effect name (e.g. a Dot device row that never
    /// applies) — shown in place of nothing, not hidden.
    var note: String? = nil
    let selected: Bool
    let remove: () -> Void
    let select: () -> Void
    @ViewState private var hovering = false

    /// A `none` record is an explicit suppress: the scope is hidden, not
    /// "assigned to an effect called none".
    private var suppressed: Bool { assignment.effectID == "none" && effect == nil }

    var body: some View {
        HStack(spacing: 8) {
            LEDStripPreview(program: effect?.preview?.program ?? "off", ledCount: effect?.preview?.ledCount ?? 8,
                            style: .band, dotSize: 6, paused: !selected, showsBackground: false)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(suppressed ? "None — hide this scope" : (effect?.label ?? assignment.effectID))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !assignment.parameters.isEmpty, let effect, assignment.parameters != effect.defaultParameters {
                        Text("· tuned").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help(suppressed ? "Stop suppressing this scope" : "Remove this assignment")
            .accessibilityLabel("Remove")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Show “\(effect?.label ?? assignment.effectID)”", action: select)
            Divider()
            Button(suppressed ? "Stop suppressing this scope" : "Remove assignment", role: .destructive, action: remove)
        }
    }
}

// MARK: - Assign sheet

struct AssignSheet: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        let effect = store.selected
        let draft = store.draft
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let effect {
                    let leds = store.previewLedCount(for: effect)
                    let metrics = LEDStripPreview.dotMetrics(ledCount: leds, width: 130, dotSize: 9, spacing: 5, padded: true)
                    LEDStripPreview(program: store.draftPreviewProgram(for: effect), ledCount: leds,
                                    style: .dots, dotSize: metrics.dotSize, spacing: metrics.spacing, showsBackground: true)
                        .frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assign “\(effect?.label ?? "")”").font(.title3.weight(.semibold))
                    Text("Pick where this look applies. More specific scopes win: device › project › instance › provider › scene › state › everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                Picker("Scope", selection: Binding(get: { store.draftScope }, set: { scope in
                    store.draftScope = scope
                    store.draftTarget = store.defaultTarget(for: scope)
                })) {
                    ForEach(EffectScope.allCases) { Text($0.label).tag($0) }
                }
                target
                if let effect, !effect.parameters.isEmpty {
                    Toggle("Keep the parameters shown for this target", isOn: $store.draftUsesParameters)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let effect, effect.safety.warns {
                Label("\(effect.safety.label) effect: it will blink on that scope. The monitor clamps it to 2 Hz.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(effect.safety == .critical ? .red : .orange)
            }
            if let problem = draft?.problem {
                Label(Self.describe(problem), systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let existing = store.existingAssignmentForDraft,
                      let effect, existing.effectID != effect.id {
                // One assignment per (scope, target): say what this replaces.
                let name = store.catalog?.effect(existing.effectID)?.label ?? existing.effectID
                Label("Replaces \(name) on \(draft?.scope.label.lowercased() ?? "") \(store.targetTitle(for: existing))",
                      systemImage: "arrow.triangle.swap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.assigning = false }.keyboardShortcut(.cancelAction)
                Button("Assign") { store.commitAssignment() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || draft?.problem != nil)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    @ViewBuilder
    private var target: some View {
        switch store.draftScope {
        case .global:
            LabeledContent("Target") { Text("Everywhere").foregroundStyle(.secondary) }
        case .semantic:
            Picker("State", selection: $store.draftTarget) {
                ForEach(EffectSemantic.assignable) { Text($0.label).tag($0.rawValue) }
            }
            Text("Ask and Error keep their reserved alert on purpose — it is the one light you can never miss. Their colour is yours on Settings › Lighting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Working, idle and the rest are looks, not events — set them per provider or under Lighting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .scene:
            Picker("Scene", selection: $store.draftTarget) {
                ForEach(EffectScene.allCases) { Text($0.label).tag($0.rawValue) }
            }
        case .provider:
            Picker("Provider", selection: $store.draftTarget) {
                // Providers seen on this Mac lead; the rest follow a divider.
                let targets = store.providerTargets
                ForEach(targets.filter(\.live), id: \.id) { Text($0.label).tag($0.id) }
                if targets.contains(where: { !$0.live }) {
                    Divider()
                    ForEach(targets.filter { !$0.live }, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        case .device:
            Picker("Device", selection: $store.draftTarget) {
                ForEach(store.deviceTargets, id: \.id) { Text($0.label).tag($0.id) }
            }
        case .providerInstance:
            if store.instanceTargets.isEmpty {
                TextField("Instance id", text: $store.draftTarget, prompt: Text("provider:instance, e.g. claude:work"))
            } else {
                Picker("Instance", selection: $store.draftTarget) {
                    ForEach(store.instanceTargets, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        case .project:
            if store.projectTargets.isEmpty {
                TextField("Project", text: $store.draftTarget,
                          prompt: Text("The session's origin label, e.g. Claude in VS Code"))
            } else {
                Picker("Project", selection: $store.draftTarget) {
                    ForEach(store.projectTargets, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        }
    }

    static func describe(_ problem: EffectAssignment.Problem) -> String {
        switch problem {
        case .globalWithTarget: return "Everywhere takes no target."
        case .missingTarget: return "This scope needs a target."
        case .urgentSemantic: return "Ask and Error keep their reserved effects."
        }
    }
}

/// A row that wraps: the daemon writes the chips' words, so their total
/// width is not something the app can promise. Used for the Effect Studio's
/// fact chips, where truncation would hide which surfaces an effect reaches.
struct WrapRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(subviews: Subviews, width: CGFloat) -> [Line] {
        var rows: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > width {
                rows.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
