import AppKit
import JRBarCore
import JRBarLEDS
import Observation
import UniformTypeIdentifiers

/// The Studio's state: the daemon's catalog and assignments, the
/// selected effect and its edited parameters, the re-rendered previews,
/// the hardware-preview consent, and the import/export flows.
@MainActor
@Observable
final class EffectStudioStore {
    static let hardwarePreviewSeconds: Double = 5
    static let consentKey = "effectHardwarePreviewConsent"

    let core: CoreModel
    let lightsStudio: EffectStudioLights
    @ObservationIgnored private var preparedForOpening = false
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    private(set) var providerSaving: Set<String> = []
    private struct ProviderDraft {
        let id = UUID()
        let effect: EffectDefinition?
        let parameters: [String: JSONValue]
    }
    private var providerDrafts: [String: ProviderDraft] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var catalog: EffectCatalog?
    private(set) var assignments: EffectAssignmentDocument?
    private(set) var loading = false
    private(set) var loadError: String?
    var lastError: String?
    var status: String?
    var spotlightExplained: Bool {
        didSet { defaults.set(spotlightExplained, forKey: "studioSpotlightExplained") }
    }
    var search = ""
    @ObservationIgnored var finishLookLoader: (@MainActor () async -> FinishLookList?)?
    var selectedID: String? {
        didSet { defaults.set(selectedID, forKey: "effectStudioSelection") }
    }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The window is open but nothing of it shows: covered, minimised, on
    /// another Space. The previews hold their frame and the clock stops
    /// until it shows again.
    var covered = false {
        didSet { if covered != oldValue { syncTicker() } }
    }

    /// Edited parameter values per effect id (only the ones the user touched).
    private(set) var edits: [String: [String: JSONValue]] = [:]
    /// `render_effect` results keyed by effect id and the parameter JSON.
    private(set) var renders: [String: EffectPreview] = [:]
    private(set) var rendering = false

    /// Hardware preview: consent remembered across launches, and the moment
    /// the current 5 s preview ends.
    var hardwareConsent: Bool = false {
        didSet { defaults.set(hardwareConsent, forKey: Self.consentKey) }
    }
    var askingConsent = false
    var hardwarePreviewUntil: Date?
    var now = Date()

    /// The "Assign…" sheet. Defaults to Provider scope — the flagship
    /// flow — with the first live provider as the target. Changing scope
    /// or target re-hydrates `draftParameters` for the new pair.
    var assigning = false {
        didSet {
            if !assigning {
                assignmentSheetID = UUID()
            }
        }
    }
    private(set) var assignmentEffect: EffectDefinition?
    private(set) var assignmentError: String?
    private struct AssignmentSubmission {
        let id = UUID()
        let sheetID: UUID
        let draft: EffectAssignment
        let snapshot: Int
        let isMix: Bool
    }
    private var pendingAssignment: AssignmentSubmission?
    @ObservationIgnored private var assignmentSheetID = UUID()

    var assignmentSaving: Bool { pendingAssignment != nil }
    var assignmentSavingThisDraft: Bool {
        guard let request = pendingAssignment else { return false }
        return ownsAssignmentSheet(request)
    }
    var assignmentEffectAvailable: Bool {
        guard let effect = assignmentEffect else { return false }
        return catalog?.effect(effect.id) != nil
    }
    var canCommitAssignment: Bool {
        guard assigning, !assignmentSaving, assignmentEffectAvailable, let draft else { return false }
        return draft.problem == nil && (draftIsMix ? mixSupported : !isRemoving(draft))
    }

    private func ownsAssignmentSheet(_ request: AssignmentSubmission) -> Bool {
        assigning && assignmentSheetID == request.sheetID && draft == request.draft && draftIsMix == request.isMix
    }
    var draftIsMix = false { didSet { assignmentError = nil; hydrateDraftParameters() } }
    var mixSupported: Bool { lightsStudio.plan?.mixes.contains { $0.id == "effect" } == true }
    private(set) var mixSaving = false

    var draftScope: EffectScope = .provider {
        didSet { assignmentError = nil; hydrateDraftParameters() }
    }
    var draftTarget: String = "claude" {
        didSet { assignmentError = nil; hydrateDraftParameters() }
    }
    var draftUsesParameters = true { didSet { assignmentError = nil } }
    /// The values the sheet's "keep the parameters" writes: the
    /// parameters stored on the assignment at (draftScope, draftTarget)
    /// when one exists, else the catalog defaults — never values tuned
    /// for a different target.
    private(set) var draftParameters: [String: JSONValue] = [:]

    @ObservationIgnored private(set) var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderRevision = 0
    @ObservationIgnored var renderDelay: () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }
    /// How a preview is rendered: the daemon's `render_effect` unless a
    /// test hands in its own (effect id, values, LED count, colour).
    @ObservationIgnored var renderer: ((String, [String: JSONValue], Int, String?) async throws -> EffectPreview)?
    /// Insertion order for `renders`, so the cache can drop its oldest.
    @ObservationIgnored private var renderOrder: [String] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusClear: DispatchWorkItem?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var seenCatalogGeneration: Int?
    @ObservationIgnored private var libraryRevision = 0
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var assignmentSnapshotSequence = 0
    @ObservationIgnored private var appliedAssignmentSnapshot = 0
    @ObservationIgnored private var windowSession = UUID()
    private var pendingRemovals: [String: UUID] = [:]

    private enum SceneSetting: String, Hashable {
        case scene = "active_scene", pack = "active_scene_pack"
        var failurePrefix: String { self == .scene ? "Scene not changed" : "Scene pack not changed" }
        func accepts(_ value: JSONValue) -> Bool {
            if case .string(let text) = value { return !text.isEmpty }
            return self == .pack && value == .null
        }
    }
    private struct SceneConfirmation {
        let stream: String
        let generation: Int
        let value: JSONValue
    }
    private var sceneRequests: [SceneSetting: UUID] = [:]
    private var sceneConfirmations: [SceneSetting: SceneConfirmation] = [:]
    var sceneChanging: Bool { sceneRequests[.scene] != nil }
    var scenePackChanging: Bool { sceneRequests[.pack] != nil }

    init(core: CoreModel, defaults: UserDefaults = .standard, settings: SettingsStore? = nil) {
        self.core = core
        lightsStudio = EffectStudioLights(core: core, settings: settings)
        self.defaults = defaults
        spotlightExplained = defaults.bool(forKey: "studioSpotlightExplained")
        selectedID = defaults.string(forKey: "effectStudioSelection")
        hardwareConsent = defaults.bool(forKey: Self.consentKey)
        mode = Mode(rawValue: defaults.string(forKey: "effectStudioMode") ?? "") ?? .mix
    }

    // MARK: Lifecycle

    func prepareForOpening() {
        preparedForOpening = true
        observeCore()
        reload()
        warmLights()
    }

    private func warmLights() {
        guard core.isLive, preparedForOpening, warmTask == nil else { return }
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.warmTask = nil }
            await self.lightsStudio.refreshPlan()
            await self.lightsStudio.refreshPreviews()
            await self.lightsStudio.refreshSupportingPreviews()
        }
    }

    func windowDidOpen() {
        if !isOpen { windowSession = UUID() }
        isOpen = true
        syncTicker()
        observeCore()
        reload()
    }

    func windowDidClose() {
        windowSession = UUID()
        pendingRemovals.removeAll()
        sceneRequests.removeAll()
        isOpen = false
        preparedForOpening = false
        warmTask?.cancel()
        warmTask = nil
        lightsStudio.windowDidClose()
        libraryRevision += 1
        libraryTask?.cancel()
        libraryTask = nil
        loading = false
        sceneListRevision += 1
        syncTicker()
        hardwarePreviewUntil = nil
        cancelRender()
        scenePreviewRevision += 1
        scenePreviewTask?.cancel()
        scenePreviewTask = nil
        // Everything modal or transient belongs to the window session: a
        // half-finished assign sheet, a consent prompt, a pack-conflict
        // alert or a stale toast must not greet the next open.
        pendingAssignment = nil
        assigning = false
        assignmentEffect = nil
        assignmentError = nil
        askingConsent = false
        pendingHardwarePlay = nil
        packConflict = nil
        scenePreview = nil
        status = nil
        lastError = nil
        statusClear?.cancel()
        statusClear = nil
    }

    /// Whether the half-second clock runs: only while the window is open
    /// and some of it shows.
    var clockRunning: Bool { ticker != nil }

    private func syncTicker() {
        guard isOpen, !covered else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        tick()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let until = hardwarePreviewUntil, until <= now { hardwarePreviewUntil = nil }
    }

    private func observeCore() {
        guard !observing else { return }
        observing = true
        track()
    }

    /// Catalog reloads follow connection and catalog changes. Scene
    /// selection reads settings frames directly.
    static func observedFacts(_ core: CoreModel) {
        _ = core.isLive
        _ = core.catalogGeneration
    }

    private func track() {
        withObservationTracking {
            Self.observedFacts(core)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = self.core.catalogGeneration
                // Warm a cold catalog before the first open. Later changes
                // wait for the window to open again.
                if self.core.isLive, !self.wasLive, (self.isOpen || (self.preparedForOpening && self.catalog == nil)) { self.reload() }
                if generation != self.seenCatalogGeneration {
                    self.seenCatalogGeneration = generation
                    if self.core.isLive, (self.isOpen || (self.preparedForOpening && self.catalog == nil)) { self.reload() }
                }
                if self.lightsStudio.plan == nil { self.warmLights() }
                self.wasLive = self.core.isLive
                self.track()
            }
        }
    }

    var isLive: Bool { core.isLive }

    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard core.isLive, !loading else { return nil }
        libraryRevision += 1
        let revision = libraryRevision
        loading = true
        loadError = nil
        let generationAtStart = core.state?.catalogGeneration
        let assignmentSnapshot = nextAssignmentSnapshot()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.libraryRevision == revision {
                    self.loading = false
                    self.libraryTask = nil
                }
            }
            do {
                async let catalog = self.core.listEffects()
                async let assignments = self.core.listAssignments()
                let fetchedCatalog = try await catalog
                let fetchedAssignments = try await assignments
                guard self.libraryRevision == revision, !Task.isCancelled else { return }
                self.catalog = fetchedCatalog
                self.acceptAssignments(fetchedAssignments, snapshot: assignmentSnapshot)
                self.seenCatalogGeneration = self.core.state?.catalogGeneration ?? fetchedCatalog.generation
                self.catalogDidChange()
                await self.loadScenePacks()
            } catch {
                guard self.libraryRevision == revision, !Task.isCancelled else { return }
                let message = "Could not load effects: \(Self.describe(error))"
                self.loadError = message
                self.fail(message)
            }
            guard self.libraryRevision == revision, !Task.isCancelled else { return }
            self.loading = false
            self.libraryTask = nil
            if self.isOpen, self.core.isLive,
               self.core.state?.catalogGeneration != generationAtStart {
                self.reload()
            }
        }
        libraryTask = task
        return task
    }

    /// Selection and caches follow the catalog: after any write that
    /// replaces it — a reload, an import, an update, a pack removal —
    /// re-anchor the selection and drop edits and renders for effects
    /// that no longer exist.
    private func catalogDidChange() {
        // An updated pack may keep its ids while changing the programs.
        // Those renders belong to the previous catalog.
        cancelRender()
        renders.removeAll()
        renderOrder.removeAll()
        if selectedID == nil || catalog?.effect(selectedID ?? "") == nil {
            selectedID = catalog?.effects.first { $0.catalog != "provider_animation" }?.id ?? catalog?.effects.first?.id
        }
        pruneForRemovedEffects()
        if assigning, assignmentEffectAvailable, let effect = assignmentEffect {
            scheduleRender(effect, values: draftParameters, color: draftColor)
        } else if !assigning, let selected {
            scheduleRender(selected)
        }
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

    func editProviderEffect(_ effect: EffectDefinition, parameters: [String: JSONValue]) {
        edits[effect.id] = effect.normalizedParameters(parameters)
        selectedID = effect.id
        mode = .effects
        scheduleRender(effect)
    }

    func resetParameters(_ effect: EffectDefinition) {
        edits[effect.id] = nil
        scheduleRender(effect)
    }

    private static func renderKey(_ effect: EffectDefinition, _ values: [String: JSONValue], ledCount: Int, color: String? = nil) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(values)) ?? Data()
        return effect.id + "|" + String(ledCount) + "|" + (color ?? "") + "|" + String(decoding: data, as: UTF8.self)
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
        if let render = renders[Self.renderKey(effect, values, ledCount: previewLedCount)] { return render.program }
        return effect.preview?.program ?? "off"
    }

    /// The assign sheet previews what the (scope, target) pair plays —
    /// the hydrated draft values, not the inspector's tuning — and, for a
    /// provider, in that provider's own colour, so OpenCode's purple
    /// previews as purple rather than as the working cyan.
    func draftPreviewProgram(for effect: EffectDefinition) -> String {
        let shown = Self.displayedEffect(for: effect, catalog: catalog, reduceMotion: reduceMotion)
        if shown.id == effect.id, let color = draftColor,
           let render = renders[Self.renderKey(effect, draftParameters, ledCount: previewLedCount, color: color)] {
            return render.program
        }
        return previewProgram(for: effect, values: draftParameters)
    }

    /// The colour the assign sheet previews in: the target provider's own
    /// colour (as Settings has it) for a provider-scope draft, else none —
    /// the catalog's working cyan.
    var draftColor: String? {
        guard draftScope == .provider else { return nil }
        let provider = draftTarget.trimmingCharacters(in: .whitespaces)
        guard !provider.isEmpty else { return nil }
        let document = SettingsDocument(core.settings?.document ?? .object([:]))
        return document.agentColorHex(provider) ?? ProviderStyle.style(for: provider).accentHex
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
        if let render = renders[Self.renderKey(effect, values, ledCount: previewLedCount)], let cadence = render.cadence { return cadence }
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

    private func cancelRender() {
        renderRevision += 1
        renderTask?.cancel()
        renderTask = nil
        rendering = false
    }

    private func scheduleRender(_ effect: EffectDefinition, values: [String: JSONValue], color: String? = nil) {
        cancelRender()
        let revision = renderRevision
        let ledCount = previewLedCount
        let key = Self.renderKey(effect, values, ledCount: ledCount, color: color)
        // The catalog already carries each effect at its defaults in the
        // working cyan; anything else is the daemon's to draw.
        guard renders[key] == nil, values != effect.defaultParameters || color != nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.renderDelay() } catch { return }
            guard !Task.isCancelled, self.renderRevision == revision else { return }
            self.rendering = true
            defer { if self.renderRevision == revision { self.rendering = false } }
            do {
                let preview: EffectPreview
                if let renderer = self.renderer {
                    preview = try await renderer(effect.id, values, ledCount, color)
                } else {
                    preview = try await self.core.renderEffect(effect.id, parameters: values, ledCount: ledCount, color: color)
                }
                guard !Task.isCancelled, self.renderRevision == revision else { return }
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
                if Task.isCancelled || self.renderRevision != revision || error is CancellationError { return }
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
                    self.fail(reply.error?.sentence ?? "Preview refused")
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

    /// The light pages and the existing effect and program editors.
    enum Mode: String, CaseIterable, Identifiable {
        case providers, mix, moments, colours, profiles, scenes, devices, effects, assignments, program
        var id: String { rawValue }
        var label: String {
            switch self {
            case .providers: return "Providers"
            case .mix: return "Mix"
            case .colours: return "State colours"
            case .profiles: return "Profiles"
            case .assignments: return "Assignments"
            case .scenes: return "Scenes"
            case .devices: return "Devices"
            case .effects: return "Library"
            case .program: return "Program"
            case .moments: return "Cues"
            }
        }
        var symbol: String {
            switch self {
            case .providers: return "person.2"
            case .mix: return "slider.horizontal.3"
            case .colours: return "paintpalette"
            case .profiles: return "slider.horizontal.3"
            case .assignments: return "arrow.triangle.branch"
            case .scenes: return "moon"
            case .devices: return "light.beacon.max"
            case .effects: return "sparkles.rectangle.stack"
            case .program: return "chevron.left.forwardslash.chevron.right"
            case .moments: return "sparkle"
            }
        }
    }

    /// The room on screen — remembered per Mac, a viewer convenience.
    var searchPath: String?
    var searchRequest = 0
    var mode: Mode = .mix {
        didSet {
            if mode != oldValue { searchPath = nil }
            defaults.set(mode.rawValue, forKey: "effectStudioMode")
        }
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
        sceneValue(.scene)?.stringValue ?? assignments?.activeScene ?? "calm"
    }

    var activeSceneIsAutomatic: Bool {
        confirmationAheadOfFrame(.scene) == nil &&
            core.settings?.document["scene_state"]?["lease_id"]?.stringValue != nil
    }

    var selectedScene: String {
        core.settings?.document["active_scene"]?.stringValue ?? "calm"
    }

    var activeScenePackID: String? { sceneValue(.pack)?.stringValue }

    private func confirmationAheadOfFrame(_ key: SceneSetting) -> SceneConfirmation? {
        guard let confirmation = sceneConfirmations[key], confirmation.stream == core.hello?.stream else { return nil }
        let frame = core.settingsFrame
        return frame?.stream != confirmation.stream ||
            (frame?.settings.generation ?? -1) < confirmation.generation ? confirmation : nil
    }

    private func sceneValue(_ key: SceneSetting) -> JSONValue? {
        if let confirmation = confirmationAheadOfFrame(key) { return confirmation.value }
        if key == .scene,
           let scene = core.settings?.document["scene_state"]?["effective_scene"]?.stringValue,
           EffectScene(rawValue: scene) != nil {
            return .string(scene)
        }
        return SettingsDocument(core.settings?.document ?? .object([:])).value(at: SettingsPath(key.rawValue))
    }

    @discardableResult
    func setActiveScene(_ scene: String) -> Task<Void, Never>? {
        changeSceneSetting(.scene, value: .string(scene))
    }

    @discardableResult
    func setActiveScenePack(_ packID: String?) -> Task<Void, Never>? {
        changeSceneSetting(.pack, value: packID.map(JSONValue.string) ?? .null)
    }

    private func changeSceneSetting(_ key: SceneSetting, value: JSONValue) -> Task<Void, Never> {
        let request = UUID()
        let session = windowSession
        let stream = core.hello?.stream
        sceneRequests[key] = request
        return Task { [weak self] in
            guard let self else { return }
            defer { if self.sceneRequests[key] == request { self.sceneRequests[key] = nil } }
            do {
                let reply = try await self.core.setSetting(SettingsPath(key.rawValue), value: value)
                guard reply.ok else { throw reply.error ?? CoreReplyError(code: "refused") }
                guard reply.result?["path"]?.stringValue == key.rawValue,
                      let kept = reply.result?["value"], key.accepts(kept),
                      case .number(let rawGeneration) = reply.result?["generation"],
                      let generation = Int(exactly: rawGeneration), generation >= 0 else {
                    throw CoreReplyError(code: "invalid_reply", message: "The monitor returned an incomplete setting result.")
                }
                if let stream, !stream.isEmpty, self.core.hello?.stream == stream {
                    let previous = self.sceneConfirmations[key]
                    if previous?.stream != stream || (previous?.generation ?? -1) <= generation {
                        self.sceneConfirmations[key] = SceneConfirmation(stream: stream, generation: generation, value: kept)
                    }
                }
                if kept != value {
                    let description = kept.stringValue ?? "the built-in scenes"
                    throw CoreReplyError(code: "normalized", message: "The monitor kept \(description) instead.")
                }
            } catch {
                guard !Task.isCancelled, self.sceneRequests[key] == request,
                      self.windowSession == session, self.core.hello?.stream == stream else { return }
                let replyError = error as? CoreReplyError
                let unconfirmed = replyError == nil || replyError?.code == "invalid_reply"
                let prefix = unconfirmed
                    ? (key == .scene ? "Scene change not confirmed" : "Scene pack change not confirmed")
                    : key.failurePrefix
                self.fail("\(prefix): \(Self.describe(error))")
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
        assignmentSheetID = UUID()
        draftIsMix = false
        assignmentEffect = effect
        assignmentError = nil
        selectedID = effect.id
        if let scope { draftScope = scope }
        draftTarget = target ?? defaultTarget(for: draftScope)
        draftUsesParameters = true
        assigning = true
        hydrateDraftParameters(for: effect)
    }

    func beginAssigningMix(_ effect: EffectDefinition) {
        beginAssigning(effect)
        draftIsMix = true
    }

    private func writeMixEffect(_ effectID: String, parameters: [String: JSONValue]) async throws -> EffectAssignmentDocument {
        try await core.request("set_assignment", args: ["scope": .string("mix"),
            "effect_id": .string(effectID), "parameters": .object(parameters)], as: EffectAssignmentDocument.self)
    }

    @discardableResult
    func chooseMixEffect(_ effect: EffectDefinition) -> Task<Void, Never>? {
        guard isLive, mixSupported, !mixSaving, !assignmentSaving else { return nil }
        let parameters = lightsStudio.settings.values.string("colors.mix_effect.effect_id") == effect.id
            ? lightsStudio.settings.values.object("colors.mix_effect.parameters") ?? effect.defaultParameters
            : effect.defaultParameters
        mixSaving = true
        return Task { [weak self] in
            guard let self else { return }
            defer { self.mixSaving = false }
            do {
                _ = try await self.writeMixEffect(effect.id, parameters: parameters)
            } catch { self.fail("Mix effect not saved: \(Self.describe(error))") }
        }
    }

    /// Re-reads the sheet's parameter values for the current (scope,
    /// target): its saved or live values, then explicit inspector edits.
    /// Untouched values follow the target. Provider motion always loops.
    private func hydrateDraftParameters(for effect: EffectDefinition? = nil) {
        guard let effect = effect ?? assignmentEffect ?? selected else { draftParameters = [:]; return }
        let target = draftScope == .global ? nil : draftTarget.trimmingCharacters(in: .whitespaces)
        var values = draftIsMix ? effect.defaultParameters
            : assignments?.draftParameters(for: effect, scope: draftScope, targetID: target) ?? effect.defaultParameters
        if !draftIsMix, draftScope == .provider, let provider = target {
            if assignments?.assignment(scope: .provider, targetID: provider) == nil,
               let live = Self.liveValues(for: effect, provider: provider, settings: core.settings?.document) {
                values = live
            }
        }
        if draftIsMix, lightsStudio.settings.values.string("colors.mix_effect.effect_id") == effect.id {
            values = lightsStudio.settings.values.object("colors.mix_effect.parameters") ?? values
        }
        values.merge(edits[effect.id] ?? [:]) { _, edited in edited }
        values = effect.normalizedParameters(values)
        if draftScope == .provider || draftIsMix { values = Self.loopingDraft(values, for: effect) }
        draftParameters = values
        scheduleRender(effect, values: draftParameters, color: draftColor)
    }

    /// What `provider` already plays `effect` with when no assignment
    /// says so: the values stored beside the motion Settings gave it
    /// (`colors.provider_animation_parameters`). A motion picked on the
    /// Lighting page, or the tempo an older settings file was seeded with
    /// (breathe 5.5 s, blink 1.6 s), has no assignment row, and the sheet
    /// would otherwise preview the catalog's 2.2 s while the strip plays
    /// its own. Nil when the provider plays something else.
    nonisolated static func liveValues(for effect: EffectDefinition, provider: String,
                                       settings: JSONValue?) -> [String: JSONValue]? {
        let document = SettingsDocument(settings ?? .object([:]))
        let motion = SettingsPath(segments: [.key("colors"), .key("provider_animation"), .key(provider)])
        let stored = SettingsPath(segments: [.key("colors"), .key("provider_animation_parameters"), .key(provider)])
        guard document.string(motion) == effect.id, let values = document.object(stored) else { return nil }
        return effect.normalizedParameters(values)
    }

    /// `values` as a working loop plays them: a pass count (`pass_mode`
    /// once or twice, which a Moment or a cue can use) means nothing to a
    /// light that runs for as long as the agent works. The daemon drops it
    /// on assignment, so the sheet previews the loop the strip will play,
    /// not one pass and then dark.
    nonisolated static func loopingDraft(_ values: [String: JSONValue],
                                         for effect: EffectDefinition) -> [String: JSONValue] {
        guard let pass = effect.parameters.first(where: { $0.name == "pass_mode" }) else { return values }
        let loop = pass.choices.contains("continuous") ? "continuous" : (pass.choices.first ?? "continuous")
        var looping = values
        looping[pass.name] = .string(loop)
        return looping
    }

    /// The assignment already stored at the draft's (scope, target), if
    /// any — the sheet shows it so a replace is never silent.
    var existingAssignmentForDraft: EffectAssignment? {
        guard let draft else { return nil }
        return assignments?.assignment(scope: draft.scope, targetID: draft.targetID)
    }

    var draft: EffectAssignment? {
        guard let effect = assignmentEffect ?? selected else { return nil }
        let target: String? = draftIsMix || draftScope == .global ? nil : draftTarget.trimmingCharacters(in: .whitespaces)
        return EffectAssignment(effectID: effect.id, scope: draftIsMix ? .global : draftScope, targetID: target,
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

    @discardableResult
    func commitAssignment() -> Task<Void, Never>? {
        guard canCommitAssignment, let draft else { return nil }
        let request = AssignmentSubmission(sheetID: assignmentSheetID, draft: draft, snapshot: nextAssignmentSnapshot(), isMix: draftIsMix)
        let effectName = assignmentEffect?.label ?? draft.effectID
        let destination = draftIsMix ? "when several providers work" : draft.scope == .global
            ? "everywhere"
            : "\(draft.scope.label.lowercased()) \(targetTitle(for: draft))"
        pendingAssignment = request
        assignmentError = nil
        return Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pendingAssignment?.id == request.id { self.pendingAssignment = nil }
            }
            do {
                guard self.pendingAssignment?.id == request.id, !Task.isCancelled else { return }
                let document: EffectAssignmentDocument
                if request.isMix {
                    document = try await self.writeMixEffect(request.draft.effectID, parameters: request.draft.parameters)
                } else {
                    document = try await self.core.setAssignment(request.draft)
                }
                guard self.pendingAssignment?.id == request.id, !Task.isCancelled else { return }
                self.acceptAssignments(document, snapshot: request.snapshot)
                guard self.ownsAssignmentSheet(request) else { return }
                self.assigning = false
                self.show(status: "\(effectName) assigned to \(destination)")
                if let warning = document.motionWarning, !warning.isEmpty {
                    self.fail("Assigned, but the provider's motion did not change: \(warning)")
                }
            } catch {
                guard self.pendingAssignment?.id == request.id, !Task.isCancelled,
                      self.ownsAssignmentSheet(request) else { return }
                let prefix = error is CoreReplyError ? "Assignment refused" : "Assignment not confirmed"
                let message = "\(prefix): \(Self.describe(error))"
                self.assignmentError = message
                self.fail(message)
            }
        }
    }

    func isRemoving(_ assignment: EffectAssignment) -> Bool { pendingRemovals[assignment.id] != nil }

    func assignmentChanging(_ assignment: EffectAssignment) -> Bool {
        isRemoving(assignment) || pendingAssignment?.draft.id == assignment.id
    }

    private func nextAssignmentSnapshot() -> Int {
        assignmentSnapshotSequence += 1
        return assignmentSnapshotSequence
    }

    private func acceptAssignments(_ document: EffectAssignmentDocument, snapshot: Int) {
        guard snapshot >= appliedAssignmentSnapshot else { return }
        appliedAssignmentSnapshot = snapshot
        assignments = document
    }

    @discardableResult
    func remove(_ assignment: EffectAssignment) -> Task<Void, Never>? {
        guard !assignmentChanging(assignment) else { return nil }
        let request = UUID()
        let snapshot = nextAssignmentSnapshot()
        pendingRemovals[assignment.id] = request
        return Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pendingRemovals[assignment.id] == request { self.pendingRemovals[assignment.id] = nil }
            }
            do {
                guard self.pendingRemovals[assignment.id] == request, !Task.isCancelled else { return }
                let document = try await self.core.clearAssignment(scope: assignment.scope, targetID: assignment.targetID)
                guard self.pendingRemovals[assignment.id] == request, !Task.isCancelled else { return }
                self.acceptAssignments(document, snapshot: snapshot)
            } catch {
                guard self.pendingRemovals[assignment.id] == request, !Task.isCancelled else { return }
                let prefix = error is CoreReplyError ? "Could not remove" : "Removal not confirmed"
                self.fail("\(prefix): \(Self.describe(error))")
            }
        }
    }

    static func providerParameters(_ effect: EffectDefinition, assignment: [String: JSONValue],
                                   playback: [String: JSONValue]?) -> [String: JSONValue] {
        effect.normalizedParameters(playback ?? assignment)
    }

    func pendingProviderMotion(_ provider: String) -> String? {
        providerDrafts[provider].map { $0.effect?.id ?? "auto" }
    }

    func pendingProviderParameters(_ provider: String) -> [String: JSONValue]? {
        providerDrafts[provider]?.parameters
    }

    @discardableResult
    func saveProvider(_ provider: String, effect: EffectDefinition?, parameters: [String: JSONValue] = [:]) -> Task<Void, Never>? {
        if let existing = providerDrafts[provider], existing.effect == effect, existing.parameters == parameters { return nil }
        providerDrafts[provider] = ProviderDraft(effect: effect, parameters: parameters)
        guard !providerSaving.contains(provider) else { return nil }
        providerSaving.insert(provider)
        return Task { [weak self] in
            guard let self else { return }
            defer { self.providerSaving.remove(provider) }
            while let draft = self.providerDrafts[provider] {
                let snapshot = self.nextAssignmentSnapshot()
                do {
                    let document: EffectAssignmentDocument
                    if let effect = draft.effect {
                        let assignment = EffectAssignment(effectID: effect.id, scope: .provider,
                                                          targetID: provider, parameters: draft.parameters)
                        document = try await self.core.setAssignment(assignment)
                    } else {
                        document = try await self.core.clearAssignment(scope: .provider, targetID: provider)
                    }
                    self.acceptAssignments(document, snapshot: snapshot)
                    if self.providerDrafts[provider]?.id == draft.id,
                       let warning = document.motionWarning, !warning.isEmpty { self.fail(warning) }
                } catch {
                    if self.providerDrafts[provider]?.id == draft.id {
                        self.fail("Provider animation not changed: \(Self.describe(error))")
                    }
                }
                if self.providerDrafts[provider]?.id == draft.id { self.providerDrafts[provider] = nil }
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
    @ObservationIgnored private var scenePreviewRevision = 0
    @ObservationIgnored private var sceneListRevision = 0
    @ObservationIgnored private(set) var scenePreviewTask: Task<Void, Never>?
    @ObservationIgnored var scenePackRenderer: ((String, Int) async throws -> EffectPreview)?
    @ObservationIgnored var scenePackLoader: (() async throws -> [ScenePackSummary])?

    /// Set when an import was refused with `already_installed`: the view
    /// offers an explicit Update retry, which is a different write, not a
    /// silent re-install.
    var packConflict: (path: String, name: String)?

    func loadScenePacks() async {
        sceneListRevision += 1
        let revision = sceneListRevision
        do {
            let packs: [ScenePackSummary]
            if let loader = scenePackLoader { packs = try await loader() }
            else { packs = try await core.listScenePacks() }
            guard sceneListRevision == revision, !Task.isCancelled else { return }
            scenePacks = packs
            scenePacksSupported = true
        } catch {
            guard sceneListRevision == revision, !Task.isCancelled else { return }
            if let reply = error as? CoreReplyError, reply.code == "unknown_command" {
                scenePacks = []
                scenePacksSupported = false
            } else {
                fail("Could not load scene packs: \(Self.describe(error))")
            }
        }
    }

    @discardableResult
    func previewScenePack(_ pack: ScenePackSummary) -> Task<Void, Never> {
        scenePreviewRevision += 1
        let revision = scenePreviewRevision
        scenePreviewTask?.cancel()
        scenePreview = nil
        let ledCount = previewLedCount
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let preview: EffectPreview
                if let renderer = self.scenePackRenderer { preview = try await renderer(pack.id, ledCount) }
                else { preview = try await self.core.previewScenePack(packID: pack.id, ledCount: ledCount) }
                // A reply landing after the window closed would resurface
                // as an unasked-for preview on the next open.
                guard self.isOpen, !Task.isCancelled, self.scenePreviewRevision == revision else { return }
                self.scenePreview = (pack.id, preview)
            } catch {
                guard self.isOpen, !Task.isCancelled, self.scenePreviewRevision == revision,
                      !(error is CancellationError) else { return }
                self.fail("Scene pack preview failed: \(Self.describe(error))")
            }
        }
        scenePreviewTask = task
        return task
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
        guard WindowPresenter.automatic.runModal(panel) == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.importScenePack(path: url.path)
                guard reply.ok else {
                    self.fail("Scene pack import refused: \(reply.error?.sentence ?? "The monitor refused that.")")
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
    @discardableResult
    func removePack(_ pack: EffectPack) -> Task<Void, Never> {
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
        guard WindowPresenter.automatic.runModal(panel) == .OK, let url = panel.url else { return }
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
        panel.message = "Writes a data-only JSON v2 pack with catalog or saved defaults. To keep edited parameters, use Save as Effect, then export the saved effect."
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName + ".json"
        panel.canCreateDirectories = true
        guard WindowPresenter.automatic.runModal(panel) == .OK, let url = panel.url else { return }
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
    @discardableResult
    func saveAsEffect(_ effect: EffectDefinition, name: String) -> Task<Void, Never>? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !yoursBusy else { return nil }
        let values = values(for: effect)
        let yours = catalog?.pack(EffectStudioYours.packID)
        yoursBusy = true
        return Task { [weak self] in
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
        MonitorWords.reason(error)
    }
}
