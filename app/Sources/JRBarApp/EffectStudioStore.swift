import AppKit
import JRBarCore
import JRBarLEDS
import Observation
import UniformTypeIdentifiers

/// The Effect Studio's state: the daemon's catalog and assignments, the
/// selected effect and its edited parameters, the re-rendered previews,
/// the hardware-preview consent, and the import/export flows.
@MainActor
@Observable
final class EffectStudioStore {
    static let hardwarePreviewSeconds: Double = 5
    static let consentKey = "effectHardwarePreviewConsent"

    let core: CoreModel
    private(set) var catalog: EffectCatalog?
    private(set) var assignments: EffectAssignmentDocument?
    private(set) var loading = false
    var lastError: String?
    var status: String?
    var search = ""
    var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "effectStudioSelection") }
    }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Edited parameter values per effect id (only the ones the user touched).
    private(set) var edits: [String: [String: JSONValue]] = [:]
    /// `render_effect` results keyed by effect id and the parameter JSON.
    private(set) var renders: [String: EffectPreview] = [:]
    private(set) var rendering = false

    /// Hardware preview: consent remembered across launches, and the moment
    /// the current 5 s preview ends.
    var hardwareConsent: Bool = UserDefaults.standard.bool(forKey: EffectStudioStore.consentKey) {
        didSet { UserDefaults.standard.set(hardwareConsent, forKey: Self.consentKey) }
    }
    var askingConsent = false
    var hardwarePreviewUntil: Date?
    var now = Date()

    /// The "Assign…" sheet. Defaults to Provider scope — the flagship
    /// flow — with the first live provider as the target. Changing scope
    /// or target re-hydrates `draftParameters` for the new pair.
    var assigning = false
    var draftScope: EffectScope = .provider {
        didSet { hydrateDraftParameters() }
    }
    var draftTarget: String = "claude" {
        didSet { hydrateDraftParameters() }
    }
    var draftUsesParameters = true
    /// The values the sheet's "keep the parameters" writes: the
    /// parameters stored on the assignment at (draftScope, draftTarget)
    /// when one exists, else the catalog defaults — never values tuned
    /// for a different target.
    private(set) var draftParameters: [String: JSONValue] = [:]

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Insertion order for `renders`, so the cache can drop its oldest.
    @ObservationIgnored private var renderOrder: [String] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusClear: DispatchWorkItem?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var seenCatalogGeneration: Int?

    init(core: CoreModel) {
        self.core = core
        selectedID = UserDefaults.standard.string(forKey: "effectStudioSelection")
    }

    // MARK: Lifecycle

    func windowDidOpen() {
        isOpen = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if let until = self.hardwarePreviewUntil, until <= self.now { self.hardwarePreviewUntil = nil }
            }
        }
        observeCore()
        reload()
    }

    func windowDidClose() {
        isOpen = false
        ticker?.invalidate()
        ticker = nil
        hardwarePreviewUntil = nil
        renderTask?.cancel()
        renderTask = nil
        // Everything modal or transient belongs to the window session: a
        // half-finished assign sheet, a consent prompt, a pack-conflict
        // alert or a stale toast must not greet the next open.
        assigning = false
        askingConsent = false
        pendingHardwarePlay = nil
        packConflict = nil
        scenePreview = nil
        status = nil
        lastError = nil
        statusClear?.cancel()
        statusClear = nil
    }

    private func observeCore() {
        guard !observing else { return }
        observing = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = core.isLive
            // `catalog_generation` moves when the registry, packs or
            // assignments change anywhere (this window, the CLI, another
            // client); `settings_generation` carries `active_scene`.
            _ = core.state?.catalogGeneration
            _ = core.state?.settingsGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = self.core.state?.catalogGeneration
                // Closed windows don't fetch: `windowDidOpen` reloads on
                // the next show, so a bumped generation while closed only
                // updates the seen marker.
                if self.core.isLive, !self.wasLive, self.isOpen { self.reload() }
                if generation != self.seenCatalogGeneration {
                    self.seenCatalogGeneration = generation
                    if self.core.isLive, self.isOpen { self.reload() }
                }
                self.wasLive = self.core.isLive
                self.track()
            }
        }
    }

    var isLive: Bool { core.isLive }

    func reload() {
        guard core.isLive, !loading else { return }
        loading = true
        // The generation the fetch starts from: a bump landing mid-fetch
        // is consumed by `track()` while `loading` drops its reload, so
        // compare after the fetch and go around again if state moved.
        let generationAtStart = core.state?.catalogGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                async let catalog = self.core.listEffects()
                async let assignments = self.core.listAssignments()
                self.catalog = try await catalog
                self.assignments = try await assignments
                // The reload cue is `state.catalog_generation`; the
                // catalog's own `generation` is only a fallback for cores
                // that don't carry it in state.
                self.seenCatalogGeneration = self.core.state?.catalogGeneration ?? self.catalog?.generation
                self.catalogDidChange()
                await self.loadScenePacks()
            } catch {
                self.fail("Could not load effects: \(Self.describe(error))")
            }
            self.loading = false
            if self.isOpen, self.core.isLive,
               self.core.state?.catalogGeneration != generationAtStart {
                self.reload()
            }
        }
    }

    /// Selection and caches follow the catalog: after any write that
    /// replaces it — a reload, an import, an update, a pack removal —
    /// re-anchor the selection and drop edits and renders for effects
    /// that no longer exist.
    private func catalogDidChange() {
        if selectedID == nil || catalog?.effect(selectedID ?? "") == nil {
            selectedID = catalog?.effects.first?.id
        }
        pruneForRemovedEffects()
    }

    /// Drops edits and renders for effects a pack removal (or an older
    /// registry) took away, so stale tuning can't linger invisible.
    private func pruneForRemovedEffects() {
        guard let catalog else { return }
        let live = Set(catalog.effects.map(\.id))
        edits = edits.filter { live.contains($0.key) }
        let deadKeys = renders.keys.filter { key in
            guard let id = key.split(separator: "|", maxSplits: 1).first else { return true }
            return !live.contains(String(id))
        }
        for key in deadKeys { renders[key] = nil }
        renderOrder.removeAll { deadKeys.contains($0) }
    }

    // MARK: Selection and parameters

    var selected: EffectDefinition? { selectedID.flatMap { catalog?.effect($0) } }

    /// The library's filter: everything, only effects an assignment
    /// uses, or only pack-installed ones.
    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, inUse, packs

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All effects"
            case .inUse: return "In use"
            case .packs: return "From packs"
            }
        }

        func includes(_ effect: EffectDefinition, used: Bool) -> Bool {
            switch self {
            case .all: return true
            case .inUse: return used
            case .packs: return effect.isFromPack
            }
        }
    }

    var filter: LibraryFilter = .all

    var groups: [(title: String, effects: [EffectDefinition])] {
        Self.libraryGroups(from: catalog, matching: search, filter: filter) { !usage(of: $0).isEmpty }
    }

    /// The catalog's meaning-groups with the filter applied and each
    /// group's effects sorted by label — the daemon's order is
    /// first-seen, which scatters nineteen provider animations into an
    /// unscannable list. Groups keep their first-seen order and empty
    /// ones drop out.
    static func libraryGroups(from catalog: EffectCatalog?, matching search: String, filter: LibraryFilter,
                              used: (EffectDefinition) -> Bool) -> [(title: String, effects: [EffectDefinition])] {
        (catalog?.groups(matching: search) ?? []).compactMap { group in
            let effects = group.effects
                .filter { filter.includes($0, used: used($0)) }
                .sorted(by: Self.libraryOrder)
            return effects.isEmpty ? nil : (group.title, effects)
        }
    }

    /// Alphabetical by display label; the id breaks ties so the order is
    /// stable across reloads.
    static func libraryOrder(_ a: EffectDefinition, _ b: EffectDefinition) -> Bool {
        switch a.label.localizedCaseInsensitiveCompare(b.label) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }

    func values(for effect: EffectDefinition) -> [String: JSONValue] {
        effect.normalizedParameters(edits[effect.id] ?? [:])
    }

    func hasEdits(_ effect: EffectDefinition) -> Bool {
        guard let edited = edits[effect.id], !edited.isEmpty else { return false }
        return values(for: effect) != effect.defaultParameters
    }

    func setValue(_ value: JSONValue, for parameter: EffectParameter, of effect: EffectDefinition) {
        var current = edits[effect.id] ?? [:]
        current[parameter.name] = parameter.normalize(value)
        edits[effect.id] = current
        scheduleRender(effect)
    }

    func resetParameters(_ effect: EffectDefinition) {
        edits[effect.id] = nil
    }

    private static func renderKey(_ effect: EffectDefinition, _ values: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return effect.id + "|" + String(decoding: data, as: UTF8.self)
    }

    /// The effect the preview actually plays. Under Reduce Motion the
    /// daemon substitutes the named fallback, so the studio shows that
    /// program instead of a motion the hardware would never run.
    static func displayedEffect(for effect: EffectDefinition, catalog: EffectCatalog?, reduceMotion: Bool) -> EffectDefinition {
        guard reduceMotion, let fallback = effect.reduceMotionFallback,
              let target = catalog?.effect(fallback), target.id != effect.id else { return effect }
        return target
    }

    /// The program the preview strip plays: the daemon's render for the
    /// edited parameters when it has arrived, else the catalog's default.
    func previewProgram(for effect: EffectDefinition) -> String {
        previewProgram(for: effect, values: values(for: effect))
    }

    func previewProgram(for effect: EffectDefinition, values: [String: JSONValue]) -> String {
        let shown = Self.displayedEffect(for: effect, catalog: catalog, reduceMotion: reduceMotion)
        if shown.id != effect.id { return shown.preview?.program ?? "off" }
        if let render = renders[Self.renderKey(effect, values)] { return render.program }
        return effect.preview?.program ?? "off"
    }

    /// The assign sheet previews what the (scope, target) pair plays —
    /// the hydrated draft values, not the inspector's tuning.
    func draftPreviewProgram(for effect: EffectDefinition) -> String {
        previewProgram(for: effect, values: draftParameters)
    }

    /// The LED count the on-screen strip renders at: the connected
    /// device's real count so the preview matches the hardware. The
    /// sampler only models the firmware's counts (2 and 8), so a device
    /// reporting anything else snaps to the nearest real shape rather
    /// than drawing a program it cannot play.
    func previewLedCount(for effect: EffectDefinition) -> Int {
        previewSurface.map { LEDSProgram.normalizedLedCount($0.ledCount) } ?? effect.preview?.ledCount ?? 8
    }

    /// The cadence the daemon reports for the current parameters, else the
    /// catalog's.
    func cadence(for effect: EffectDefinition) -> BlinkCadence? {
        let values = values(for: effect)
        if let render = renders[Self.renderKey(effect, values)], let cadence = render.cadence { return cadence }
        if effect.id == "blink" || effect.parameter(named: "cadence") != nil,
           let id = values["cadence"]?.stringValue, let cadence = catalog?.cadences.first(where: { $0.id == id }) {
            return cadence
        }
        return effect.cadence
    }

    /// Re-renders 150 ms after the last change; the last request wins.
    private func scheduleRender(_ effect: EffectDefinition) {
        scheduleRender(effect, values: values(for: effect))
    }

    /// Every slider position is a distinct cache key; without a bound a
    /// tuning session grows the cache for the window's whole lifetime.
    private static let renderCacheLimit = 48

    private func scheduleRender(_ effect: EffectDefinition, values: [String: JSONValue]) {
        renderTask?.cancel()
        let key = Self.renderKey(effect, values)
        guard renders[key] == nil, values != effect.defaultParameters else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.rendering = true
            defer { self.rendering = false }
            do {
                let preview = try await self.core.renderEffect(effect.id, parameters: values, ledCount: previewLedCount)
                self.renders[key] = preview
                self.renderOrder.removeAll { $0 == key }
                self.renderOrder.append(key)
                while self.renderOrder.count > Self.renderCacheLimit, let oldest = self.renderOrder.first {
                    self.renderOrder.removeFirst()
                    self.renders[oldest] = nil
                }
            } catch {
                // Every keystroke cancels the previous render and the
                // window close cancels the last one — neither is a
                // failure worth a toast.
                if Task.isCancelled || error is CancellationError { return }
                self.fail("Preview render failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: Hardware preview

    var hardwarePreviewActive: Bool { hardwarePreviewUntil.map { $0 > now } ?? false }

    var hardwarePreviewRemaining: Int {
        guard let until = hardwarePreviewUntil else { return 0 }
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// The surface a hardware preview plays on: the Pro strip when one is
    /// connected, the Dot when it is the only hardware. Nil with neither.
    var previewSurface: (surface: String, ledCount: Int, name: String)? {
        if let strip = core.devices.first(where: { $0.kind == "pro" && $0.isPresent }) {
            return ("hardware", strip.leds ?? 8, strip.name ?? "strip")
        }
        if let dot = core.devices.first(where: { $0.kind == "dot" && $0.isPresent }) {
            return ("dot", dot.leds ?? 2, dot.name ?? "Dot")
        }
        return nil
    }

    var hasHardware: Bool { previewSurface != nil }

    /// Where a preview plays: the connected strip or Dot, else the Screen
    /// Bar — always on screen, so an effect can be auditioned with no
    /// hardware at all (`preview_program` takes the `screen_bar` surface).
    var playSurface: (surface: String, ledCount: Int, name: String) {
        previewSurface ?? ("screen_bar", ScreenBarGeometry.ledCount, "Screen Bar")
    }

    /// Whether a preview on `surface` needs the one-time hardware consent:
    /// a strip or a Dot lights the desk; the Screen Bar is the screen's
    /// own light and needs none.
    static func needsConsent(surface: String) -> Bool { surface != "screen_bar" }

    /// A `preview_program` request on the wire; the button stays enabled
    /// until the daemon answers without this, so a fast double-tap would
    /// queue two previews on the hardware.
    private(set) var hardwarePreviewInFlight = false

    /// The LED count previews render at: the connected device's real
    /// count snapped to a shape the sampler can play (the firmware's 2
    /// and 8), the catalog's 8 otherwise.
    var previewLedCount: Int {
        guard let ledCount = previewSurface?.ledCount else { return 8 }
        return LEDSProgram.normalizedLedCount(ledCount)
    }

    func previewOnHardware(_ effect: EffectDefinition) {
        let target = playSurface
        guard hardwareConsent || !Self.needsConsent(surface: target.surface) else { askingConsent = true; return }
        guard !hardwarePreviewInFlight else { return }
        let program = previewProgram(for: effect)
        hardwarePreviewInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.hardwarePreviewInFlight = false }
            do {
                let reply = try await self.core.previewProgramNow(surface: target.surface, program: program, seconds: Self.hardwarePreviewSeconds)
                guard self.isOpen else { return }
                if reply.ok {
                    self.hardwarePreviewUntil = Date().addingTimeInterval(Self.hardwarePreviewSeconds)
                    self.show(status: "Playing \(effect.label) on \(target.name) for \(Int(Self.hardwarePreviewSeconds)) s")
                } else {
                    self.fail(reply.error?.message ?? reply.error?.code ?? "Preview refused")
                }
            } catch {
                self.fail("Preview failed: \(Self.describe(error))")
            }
        }
    }

    func grantConsent(and effect: EffectDefinition?) {
        hardwareConsent = true
        askingConsent = false
        // A LEDS Studio play waiting on the consent goes first: it is what
        // the person pressed.
        if let pending = pendingHardwarePlay {
            pendingHardwarePlay = nil
            pending()
        } else if let effect {
            previewOnHardware(effect)
        }
    }

    /// A LEDS Studio play parked behind the consent alert.
    @ObservationIgnored var pendingHardwarePlay: (@MainActor () -> Void)?

    // MARK: Studio modes

    /// The window's three rooms: the effect library, the hand-written
    /// LEDS program, and the ambient moments the lights can play.
    enum Mode: String, CaseIterable, Identifiable {
        case effects, program, moments
        var id: String { rawValue }
        var label: String {
            switch self {
            case .effects: return "Effects"
            case .program: return "Program"
            case .moments: return "Moments"
            }
        }
        var symbol: String {
            switch self {
            case .effects: return "sparkles.rectangle.stack"
            case .program: return "chevron.left.forwardslash.chevron.right"
            case .moments: return "sparkle"
            }
        }
    }

    /// The room on screen — remembered per Mac, a viewer convenience.
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "effectStudioMode") ?? "") ?? .effects {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "effectStudioMode") }
    }

    /// The hand-written program's editor state.
    @ObservationIgnored private(set) lazy var ledsStudio: LEDSStudioModel = {
        let model = LEDSStudioModel(core: core)
        model.onStatus = { [weak self] text in self?.show(status: text) }
        model.onError = { [weak self] text in self?.fail(text) }
        model.requestHardwareConsent = { [weak self] play in
            guard let self else { return }
            if self.hardwareConsent { play(); return }
            self.pendingHardwarePlay = play
            self.askingConsent = true
        }
        return model
    }()

    // MARK: Assignments

    var activeScene: String {
        assignments?.activeScene ?? SettingsDocument(core.settings?.document ?? .object([:])).string(SettingsPath("active_scene")) ?? "calm"
    }

    func setActiveScene(_ scene: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.core.setSetting(SettingsPath("active_scene"), value: .string(scene))
                self.assignments = try await self.core.listAssignments()
            } catch {
                self.fail("Scene not changed: \(Self.describe(error))")
            }
        }
    }

    /// The `active_scene_pack` settings key: the installed pack whose
    /// policy rows the daemon applies over the built-in scenes, or nil
    /// for the built-ins. Read straight from the settings document —
    /// `list_assignments` does not carry it.
    var activeScenePackID: String? {
        SettingsDocument(core.settings?.document ?? .object([:])).string(SettingsPath("active_scene_pack"))
    }

    /// Writes `active_scene_pack` through `set_setting`; nil clears it
    /// back to the built-in policies. The settings document lands on
    /// `core.settings` by itself, so there is nothing to re-fetch.
    func setActiveScenePack(_ packID: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.core.setSetting(
                    SettingsPath("active_scene_pack"),
                    value: packID.map(JSONValue.string) ?? .null
                )
            } catch {
                self.fail("Scene pack not changed: \(Self.describe(error))")
            }
        }
    }

    func usage(of effect: EffectDefinition) -> [EffectAssignment] { assignments?.usage(of: effect.id) ?? [] }

    /// "Used by Everywhere, Codex (provider)" — where the effect is
    /// assigned, for the library row's tooltip.
    func usageSummary(of effect: EffectDefinition) -> String? {
        let uses = usage(of: effect)
        guard !uses.isEmpty else { return nil }
        let list = uses.map { assignment in
            assignment.scope == .global
                ? "Everywhere"
                : "\(targetTitle(for: assignment)) (\(assignment.scope.label.lowercased()))"
        }
        return "Used by " + list.joined(separator: ", ")
    }

    func beginAssigning(_ effect: EffectDefinition, scope: EffectScope? = nil, target: String? = nil) {
        // The sheet reads `selected`; a context-menu Assign on a row that
        // is not selected must not write the other effect's id.
        selectedID = effect.id
        if let scope { draftScope = scope }
        draftTarget = target ?? defaultTarget(for: draftScope)
        draftUsesParameters = true
        assigning = true
        hydrateDraftParameters(for: effect)
    }

    /// Re-reads the sheet's parameter values for the current (scope,
    /// target): the stored assignment's own parameters when one exists,
    /// else the catalog defaults. Runs when the sheet opens and whenever
    /// scope or target changes, so "keep the parameters" means the
    /// pair's tuning — not what was last edited for another target.
    private func hydrateDraftParameters(for effect: EffectDefinition? = nil) {
        guard let effect = effect ?? selected else { draftParameters = [:]; return }
        let target = draftScope == .global ? nil : draftTarget.trimmingCharacters(in: .whitespaces)
        draftParameters = assignments?.draftParameters(for: effect, scope: draftScope, targetID: target)
            ?? effect.defaultParameters
        scheduleRender(effect, values: draftParameters)
    }

    /// The assignment already stored at the draft's (scope, target), if
    /// any — the sheet shows it so a replace is never silent.
    var existingAssignmentForDraft: EffectAssignment? {
        guard let draft else { return nil }
        return assignments?.assignment(scope: draft.scope, targetID: draft.targetID)
    }

    var draft: EffectAssignment? {
        guard let effect = selected else { return nil }
        let target: String? = draftScope == .global ? nil : draftTarget.trimmingCharacters(in: .whitespaces)
        return EffectAssignment(effectID: effect.id, scope: draftScope, targetID: target,
                                parameters: draftUsesParameters ? draftParameters : [:])
    }

    /// The row title for an assignment: the device's name, the provider's
    /// display name, the state or scene word; ids for projects and instances.
    func targetTitle(for assignment: EffectAssignment) -> String {
        guard let target = assignment.targetID else { return "Everywhere" }
        switch assignment.scope {
        case .device:
            if target == "screen-bar" { return "Screen Bar" }
            return core.devices.first { $0.id == target }?.name ?? target
        case .provider:
            return ProviderStyle.style(for: target).name
        default:
            return assignment.targetLabel
        }
    }

    func commitAssignment() {
        guard let draft, draft.problem == nil else { return }
        assigning = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.core.setAssignment(draft)
                self.assignments = document
                let effectName = self.catalog?.effect(draft.effectID)?.label ?? draft.effectID
                let where_ = draft.scope == .global
                    ? "everywhere"
                    : "\(draft.scope.label.lowercased()) \(self.targetTitle(for: draft))"
                self.show(status: "\(effectName) assigned to \(where_)")
                if let warning = document.motionWarning, !warning.isEmpty {
                    self.fail("Assigned, but the provider's motion did not change: \(warning)")
                }
            } catch {
                self.fail("Assignment refused: \(Self.describe(error))")
            }
        }
    }

    func remove(_ assignment: EffectAssignment) {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.assignments = try await self.core.clearAssignment(scope: assignment.scope, targetID: assignment.targetID)
            } catch {
                self.fail("Could not remove: \(Self.describe(error))")
            }
        }
    }

    /// Providers that have actually been seen on this Mac: reporting a
    /// session or a usage window, or detected by the daemon's health
    /// probe. These lead the picker; every known provider follows.
    var providerTargets: [(id: String, label: String, live: Bool)] {
        var live: Set<String> = Set(core.state?.sessions.map(\.provider) ?? [])
        live.formUnion((core.state?.usage?.providers ?? []).map(\.id))
        let detected = core.state?.health?["detected"]
        for provider in SettingsKey.providers where detected?[provider]?.boolValue == true {
            live.insert(provider)
        }
        let liveFirst = SettingsKey.providers.filter { live.contains($0) }
        let rest = SettingsKey.providers.filter { !live.contains($0) }
        return (liveFirst + rest).map { ($0, ProviderStyle.style(for: $0).name, live.contains($0)) }
    }

    /// `provider_instance` targets in the daemon's `provider:instance`
    /// wire form — every non-default instance that reports usage. When
    /// none exist the sheet falls back to a free-text field.
    var instanceTargets: [(id: String, label: String)] {
        (core.state?.usage?.providers ?? [])
            .filter { $0.instance != nil && $0.instance != "default" && !$0.instance!.isEmpty }
            .map { ("\($0.id):\($0.instance!)", "\(ProviderStyle.style(for: $0.id).name) · \($0.instance!)") }
    }

    /// `project` targets are the sessions' origin labels ("Claude in VS
    /// Code") — that is what the daemon matches `project_id` against.
    var projectTargets: [(id: String, label: String)] {
        let labels = (core.state?.sessions ?? []).compactMap(\.origin?.label)
        return Array(Set(labels)).sorted().map { ($0, $0) }
    }

    /// Real devices only. The Screen Bar is not a device-scope target:
    /// its surface never resolves device assignments, so offering it
    /// wrote a row that could never fire.
    var deviceTargets: [(id: String, label: String)] {
        core.devices.filter { $0.kind != "screen_bar" }
            .map { device in
                var label = device.name ?? device.id
                if device.kind == "dot", device.linked == true || core.lights?.linked == true {
                    label += " (follows the strip)"
                }
                return (device.id, label)
            }
    }

    /// One row of the "what plays where" block: a live provider plus the
    /// assignments it resolves to — its provider-scope row (the working
    /// motion when the effect is a provider animation), the semantic
    /// effects its routed events can fire, and its instance rows.
    struct ProviderPlayback: Hashable, Identifiable {
        var id: String { providerID }
        let providerID: String
        let name: String
        let provider: EffectAssignment?
        let semantics: [EffectAssignment]
        let instances: [EffectAssignment]
    }

    /// The reverse lookup: one summary per provider the daemon has
    /// actually seen — the same live set the assign sheet's provider
    /// picker leads with.
    var providerPlayback: [ProviderPlayback] {
        providerTargets.filter(\.live).map { target in
            let playback = assignments?.playback(forProvider: target.id)
            return ProviderPlayback(providerID: target.id, name: target.label,
                                    provider: playback?.provider,
                                    semantics: playback?.semantics ?? [],
                                    instances: playback?.instances ?? [])
        }
    }

    /// The device-scope rows of the same block — only devices an
    /// assignment names.
    var devicePlayback: [EffectAssignment] {
        assignments?.assignments.filter { $0.scope == .device } ?? []
    }

    /// Tapping a "what plays on X" row: jump to the effect the provider's
    /// scope names, or — when it has no scope of its own — open the
    /// assign sheet pre-filled for it.
    func focusPlayback(_ playback: ProviderPlayback) {
        if let assignment = playback.provider {
            selectedID = assignment.effectID
        } else if let effect = selected {
            beginAssigning(effect, scope: .provider, target: playback.providerID)
        }
    }

    /// A stored device assignment naming a linked Dot: while it follows
    /// the strip, the scoped effect is shadowed. The check mirrors the
    /// picker label's — the lights document or the device itself can
    /// carry the linked flag.
    func isUnreachableDot(_ assignment: EffectAssignment) -> Bool {
        guard assignment.scope == .device,
              let dot = core.devices.first(where: { $0.id == assignment.targetID && $0.kind == "dot" })
        else { return false }
        return core.lights?.linked == true || dot.linked == true
    }

    /// The row's second line: what the assignment actually does — a
    /// provider-scope provider_animation writes the provider's working
    /// motion (persistent), anything else is an event flash; a linked Dot
    /// shadows its device row.
    func assignmentNote(_ assignment: EffectAssignment) -> String? {
        if isUnreachableDot(assignment) { return "the Dot follows the strip while linked" }
        let effect = catalog?.effect(assignment.effectID)
        if assignment.scope == .provider, effect?.catalog == "provider_animation" {
            return "plays as \(ProviderStyle.style(for: assignment.targetID ?? "").name)'s motion while it works"
        }
        // A provider-scope row naming an ordinary effect fires on that
        // provider's events only -- it does not set the working motion.
        if assignment.scope == .provider, effect != nil {
            return "Fires on this provider's events; the working motion is set by a Provider animation."
        }
        if assignment.scope == .semantic {
            return "fires on \(assignment.targetLabel.lowercased()) events"
        }
        return nil
    }

    func defaultTarget(for scope: EffectScope) -> String {
        switch scope {
        case .global: return ""
        case .semantic: return EffectSemantic.assignable.first?.rawValue ?? EffectSemantic.completion.rawValue
        case .scene: return EffectScene.calm.rawValue
        case .provider: return providerTargets.first { $0.live }?.id ?? providerTargets.first?.id ?? "claude"
        case .device: return deviceTargets.first?.id ?? ""
        case .providerInstance: return instanceTargets.first?.id ?? ""
        case .project: return projectTargets.first?.id ?? ""
        }
    }

    // MARK: Packs

    /// Installed scene packs and the pack whose preview is being shown.
    /// `scenePacksSupported` is true once `list_scene_packs` answers — an
    /// old core answering unknown_command hides the section entirely.
    private(set) var scenePacks: [ScenePackSummary] = []
    private(set) var scenePacksSupported = false
    var scenePreview: (packID: String, preview: EffectPreview)?

    /// Set when an import was refused with `already_installed`: the view
    /// offers an explicit Update retry, which is a different write, not a
    /// silent re-install.
    var packConflict: (path: String, name: String)?

    func loadScenePacks() async {
        do {
            self.scenePacks = try await self.core.listScenePacks()
            self.scenePacksSupported = true
        } catch {
            // A core without scene-pack commands answers unknown_command;
            // the section simply does not render.
            self.scenePacks = []
            self.scenePacksSupported = false
        }
    }

    func previewScenePack(_ pack: ScenePackSummary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await self.core.previewScenePack(packID: pack.id, ledCount: self.previewLedCount)
                // A reply landing after the window closed would resurface
                // as an unasked-for preview on the next open.
                guard self.isOpen else { return }
                self.scenePreview = (pack.id, preview)
            } catch {
                self.fail("Scene pack preview failed: \(Self.describe(error))")
            }
        }
    }

    /// `import_scene_pack {path}`: same data-only JSON file flow as effect
    /// packs; the reply carries the pack list plus the catalog delta.
    func importScenePack() {
        let panel = NSOpenPanel()
        panel.title = "Import Scene Pack"
        panel.message = "Scene packs are data-only JSON; the monitor validates the file."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.importScenePack(path: url.path)
                guard reply.ok else {
                    self.fail("Scene pack import refused: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                    return
                }
                await self.loadScenePacks()
                self.show(status: "Imported scenes from \(url.lastPathComponent)")
            } catch {
                self.fail("Scene pack import refused: \(Self.describe(error))")
            }
        }
    }

    /// Removes an installed effect pack via `remove_effect_pack`; the
    /// reply carries the fresh catalog like the import does.
    func removePack(_ pack: EffectPack) {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.catalog = try await self.core.removeEffectPack(packID: pack.id)
                self.catalogDidChange()
                self.show(status: "Removed pack \(pack.name)")
            } catch {
                self.fail("Remove refused: \(Self.describe(error))")
            }
        }
    }

    /// `import_effect_pack` with `update: true` — the retry offered after
    /// an `already_installed` conflict, so replacing a pack is an
    /// explicit choice rather than a surprise overwrite.
    func updatePack() {
        guard let conflict = packConflict else { return }
        packConflict = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                self.catalog = try await self.core.importEffectPack(path: conflict.path, update: true)
                self.catalogDidChange()
                self.show(status: "Updated \(conflict.name)")
            } catch {
                self.fail("Update refused: \(Self.describe(error))")
            }
        }
    }

    func importPack() {
        let panel = NSOpenPanel()
        panel.title = "Import Effect Pack"
        panel.message = "Packs are data-only JSON (v2). The monitor validates the file; nothing in it is executed."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.catalog = try await self.core.importEffectPack(path: url.path)
                self.catalogDidChange()
                self.show(status: "Imported \(url.lastPathComponent)")
            } catch let error as CoreReplyError where error.code == "conflict" || error.code == "already_installed" || (error.message ?? "").contains("already_installed") {
                self.packConflict = (url.path, url.lastPathComponent)
            } catch {
                self.fail("Import refused: \(Self.describe(error))")
            }
        }
    }

    /// Exports the selected effect, or every effect of its pack.
    func exportPack(ids: [String], suggestedName: String) {
        guard !ids.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Effect Pack"
        panel.message = "Writes a data-only JSON v2 pack with the current parameters as defaults."
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName + ".json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.exportEffectPack(ids: ids, path: url.path, name: name)
                let count = reply.result?["effects"]?.intValue ?? ids.count
                self.show(status: "Exported \(count) effect\(count == 1 ? "" : "s") to \(url.lastPathComponent)")
            } catch {
                self.fail("Export failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: Yours

    /// The effect "Save as Effect…" is naming, and the name so far —
    /// the alert's state.
    var savingEffect: EffectDefinition?
    var saveName = ""
    /// A save or delete in flight; the buttons wait for it.
    private(set) var yoursBusy = false

    func beginSaving(_ effect: EffectDefinition) {
        saveName = effect.label
        savingEffect = effect
    }

    /// Keeps `effect` with its tuned parameters as a new effect in Yours:
    /// Yours and the source are exported by the monitor, the source's row
    /// is copied under the new name with these values, and the pack goes
    /// back in (`update` when Yours already exists). Two exports, not one,
    /// so a source whose row id Yours already uses cannot collide.
    func saveAsEffect(_ effect: EffectDefinition, name: String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !yoursBusy else { return }
        let values = values(for: effect)
        let yours = catalog?.pack(EffectStudioYours.packID)
        yoursBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.yoursBusy = false }
            let scratch = FileManager.default.temporaryDirectory
            let yoursURL = scratch.appendingPathComponent("jrbar-yours-\(UUID().uuidString).json")
            let sourceURL = scratch.appendingPathComponent("jrbar-source-\(UUID().uuidString).json")
            defer {
                try? FileManager.default.removeItem(at: yoursURL)
                try? FileManager.default.removeItem(at: sourceURL)
            }
            do {
                var installed: JSONValue?
                if let yours, !yours.effectIDs.isEmpty {
                    try await self.core.exportEffectPack(ids: yours.effectIDs, path: yoursURL.path, name: EffectStudioYours.packName)
                    installed = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: yoursURL))
                }
                try await self.core.exportEffectPack(ids: [effect.id], path: sourceURL.path, name: EffectStudioYours.packName)
                let source = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: sourceURL))
                let newID = EffectStudioYours.slug(label, taken: Set(EffectStudioYours.rowIDs(installed)))
                let pack = try EffectStudioYours.pack(yours: installed, source: source, sourceLabel: effect.label,
                                                      newID: newID, label: label, values: values)
                let text = EffectStudioYours.text(pack) { [catalog = self.catalog] row in
                    row == newID ? EffectStudioYours.floatKeys(of: effect)
                        : EffectStudioYours.floatKeys(of: catalog?.effect(EffectStudioYours.effectID(local: row)))
                }
                try Data(text.utf8).write(to: yoursURL)
                self.catalog = try await self.core.importEffectPack(path: yoursURL.path, update: installed != nil)
                self.catalogDidChange()
                self.selectedID = EffectStudioYours.effectID(local: newID)
                self.show(status: "Saved “\(label)” to Yours")
            } catch {
                self.fail("Save refused: \(Self.describe(error))")
            }
        }
    }

    /// Takes one effect out of Yours; the last one removes the pack.
    func deleteFromYours(_ effect: EffectDefinition) {
        guard EffectStudioYours.isYours(effect), !yoursBusy,
              let yours = catalog?.pack(EffectStudioYours.packID) else { return }
        yoursBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.yoursBusy = false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("jrbar-yours-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try await self.core.exportEffectPack(ids: yours.effectIDs, path: url.path, name: EffectStudioYours.packName)
                let installed = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
                if let rest = EffectStudioYours.pack(yours: installed, removing: EffectStudioYours.localID(effect.id)) {
                    let text = EffectStudioYours.text(rest) { [catalog = self.catalog] row in
                        EffectStudioYours.floatKeys(of: catalog?.effect(EffectStudioYours.effectID(local: row)))
                    }
                    try Data(text.utf8).write(to: url)
                    self.catalog = try await self.core.importEffectPack(path: url.path, update: true)
                } else {
                    self.catalog = try await self.core.removeEffectPack(packID: EffectStudioYours.packID)
                }
                self.catalogDidChange()
                self.show(status: "Deleted “\(effect.label)” from Yours")
            } catch {
                self.fail("Delete refused: \(Self.describe(error))")
            }
        }
    }

    // MARK: Messages

    func show(status text: String) {
        status = text
        lastError = nil
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.status = nil } }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func fail(_ text: String) {
        lastError = text
        status = nil
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.lastError = nil } }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    static func describe(_ error: Error) -> String {
        if let reply = error as? CoreReplyError { return reply.message ?? reply.code }
        return "\(error)"
    }
}
