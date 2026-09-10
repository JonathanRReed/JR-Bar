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

    /// The "Assign…" sheet.
    var assigning = false
    var draftScope: EffectScope = .semantic
    var draftTarget: String = EffectSemantic.working.rawValue
    var draftUsesParameters = true

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusClear: DispatchWorkItem?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var wasLive = false

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
            _ = core.settings?.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.core.isLive, !self.wasLive { self.reload() }
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
                if self.selectedID == nil || self.catalog?.effect(self.selectedID ?? "") == nil {
                    self.selectedID = self.catalog?.effects.first?.id
                }
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
        let values = values(for: effect)
        if let render = renders[Self.renderKey(effect, values)] { return render.program }
        return effect.preview?.program ?? "off"
    }

    func previewLedCount(for effect: EffectDefinition) -> Int {
        effect.preview?.ledCount ?? 8
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
        renderTask?.cancel()
        let values = values(for: effect)
        let key = Self.renderKey(effect, values)
        guard renders[key] == nil, values != effect.defaultParameters else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.rendering = true
            defer { self.rendering = false }
            do {
                let preview = try await self.core.renderEffect(effect.id, parameters: values, ledCount: effect.preview?.ledCount ?? 8)
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

    var hasHardware: Bool { core.devices.contains { ($0.kind == "pro" || $0.kind == "dot") && $0.isPresent } }

    func previewOnHardware(_ effect: EffectDefinition) {
        guard hardwareConsent else { askingConsent = true; return }
        let program = previewProgram(for: effect)
        core.previewProgram(surface: "hardware", program: program, seconds: Self.hardwarePreviewSeconds)
        hardwarePreviewUntil = Date().addingTimeInterval(Self.hardwarePreviewSeconds)
        show(status: "Playing \(effect.label) on the strip for \(Int(Self.hardwarePreviewSeconds)) s")
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

    func beginAssigning(_ effect: EffectDefinition) {
        if draftScope == .semantic, EffectSemantic(rawValue: draftTarget) == nil { draftTarget = EffectSemantic.working.rawValue }
        assigning = true
    }

    var draft: EffectAssignment? {
        guard let effect = selected else { return nil }
        let target: String? = draftScope == .global ? nil : draftTarget.trimmingCharacters(in: .whitespaces)
        return EffectAssignment(effectID: effect.id, scope: draftScope, targetID: target,
                                parameters: draftUsesParameters ? values(for: effect) : [:])
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
                self.assignments = try await self.core.setAssignment(draft)
                self.show(status: "\(self.catalog?.effect(draft.effectID)?.label ?? draft.effectID) assigned to \(draft.scope.label.lowercased()) \(self.targetTitle(for: draft))")
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

    /// Targets the draft can pick from, by scope.
    var deviceTargets: [(id: String, label: String)] {
        core.devices.filter { $0.kind != "screen_bar" }.map { ($0.id, $0.name ?? $0.id) } + [("screen-bar", "Screen Bar")]
    }

    func defaultTarget(for scope: EffectScope) -> String {
        switch scope {
        case .global: return ""
        case .semantic: return EffectSemantic.working.rawValue
        case .scene: return EffectScene.calm.rawValue
        case .provider: return "claude"
        case .device: return deviceTargets.first?.id ?? ""
        case .providerInstance, .project: return ""
        }
    }

    // MARK: Packs

    func importPack() {
        let panel = NSOpenPanel()
        panel.title = "Import Effect Pack"
        panel.message = "Packs are data-only JSON (v2). The core validates the file; nothing in it is executed."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.catalog = try await self.core.importEffectPack(path: url.path)
                self.show(status: "Imported \(url.lastPathComponent)")
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
