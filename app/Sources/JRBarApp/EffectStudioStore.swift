import AppKit
import JRBarCore
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
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusClear: DispatchWorkItem?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var seenCatalogGeneration: Int?

    init(core: CoreModel) {
        self.core = core
        selectedID = UserDefaults.standard.string(forKey: "effectStudioSelection")
    }

    // MARK: Lifecycle

    func windowDidOpen() {
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
        ticker?.invalidate()
        ticker = nil
        hardwarePreviewUntil = nil
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
                if self.core.isLive, !self.wasLive { self.reload() }
                if generation != self.seenCatalogGeneration {
                    self.seenCatalogGeneration = generation
                    if self.core.isLive { self.reload() }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                async let catalog = self.core.listEffects()
                async let assignments = self.core.listAssignments()
                self.catalog = try await catalog
                self.assignments = try await assignments
                self.seenCatalogGeneration = self.catalog?.generation
                if self.selectedID == nil || self.catalog?.effect(self.selectedID ?? "") == nil {
                    self.selectedID = self.catalog?.effects.first?.id
                }
                await self.loadScenePacks()
            } catch {
                self.fail("Could not load effects: \(Self.describe(error))")
            }
            self.loading = false
        }
    }

    // MARK: Selection and parameters

    var selected: EffectDefinition? { selectedID.flatMap { catalog?.effect($0) } }

    var groups: [(title: String, effects: [EffectDefinition])] { catalog?.groups(matching: search) ?? [] }

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

    /// The program the preview strip plays: the daemon's render for the
    /// edited parameters when it has arrived, else the catalog's default.
    func previewProgram(for effect: EffectDefinition) -> String {
        previewProgram(for: effect, values: values(for: effect))
    }

    func previewProgram(for effect: EffectDefinition, values: [String: JSONValue]) -> String {
        if let render = renders[Self.renderKey(effect, values)] { return render.program }
        return effect.preview?.program ?? "off"
    }

    /// The assign sheet previews what the (scope, target) pair plays —
    /// the hydrated draft values, not the inspector's tuning.
    func draftPreviewProgram(for effect: EffectDefinition) -> String {
        previewProgram(for: effect, values: draftParameters)
    }

    /// The LED count the on-screen strip renders at: the connected
    /// device's real count so the preview matches the hardware.
    func previewLedCount(for effect: EffectDefinition) -> Int {
        previewSurface.map { min(24, max(2, $0.ledCount)) } ?? effect.preview?.ledCount ?? 8
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
            } catch {
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

    /// The LED count previews render at: the connected device's real
    /// count (2–24 is what `render_effect` supports), the catalog's 8
    /// otherwise.
    var previewLedCount: Int {
        guard let ledCount = previewSurface?.ledCount else { return 8 }
        return min(24, max(2, ledCount))
    }

    func previewOnHardware(_ effect: EffectDefinition) {
        guard hardwareConsent else { askingConsent = true; return }
        guard let target = previewSurface else {
            fail("Nothing to play on: no strip or Dot is connected")
            return
        }
        let program = previewProgram(for: effect)
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.previewProgramNow(surface: target.surface, program: program, seconds: Self.hardwarePreviewSeconds)
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
        if let effect { previewOnHardware(effect) }
    }

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

    func usage(of effect: EffectDefinition) -> [EffectAssignment] { assignments?.usage(of: effect.id) ?? [] }

    func beginAssigning(_ effect: EffectDefinition, scope: EffectScope? = nil, target: String? = nil) {
        if let scope { draftScope = scope }
        draftTarget = target ?? defaultTarget(for: draftScope)
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
    /// the strip, the scoped effect is shadowed.
    func isUnreachableDot(_ assignment: EffectAssignment) -> Bool {
        assignment.scope == .device
            && (core.lights?.linked == true)
            && core.devices.contains { $0.id == assignment.targetID && $0.kind == "dot" }
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
                self.show(status: "Imported \(url.lastPathComponent)")
            } catch let error as CoreReplyError where error.code == "conflict" || (error.message ?? "").contains("already_installed") {
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

    // MARK: Messages

    private func show(status text: String) {
        status = text
        lastError = nil
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.status = nil } }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func fail(_ text: String) {
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
