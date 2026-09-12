import Foundation

// The Effect Studio's data model, mirroring `src/jrbar/effect_registry.py`,
// `effect_packs.py` and `effect_assignment_store.py`. The daemon is the
// authority: the app decodes `list_effects` / `list_assignments` (app-proposed
// protocol extensions, see app/README.md) and never registers an effect of
// its own. Every field the daemon might omit is optional or defaulted.

public enum EffectSafety: String, Codable, Hashable, Sendable, CaseIterable {
    case safe, attention, critical

    /// Attention and critical effects blink hard; the studio warns before
    /// assigning them.
    public var warns: Bool { self != .safe }

    public var label: String {
        switch self {
        case .safe: return "Safe"
        case .attention: return "Attention"
        case .critical: return "Critical"
        }
    }
}

public enum EffectEnergy: String, Codable, Hashable, Sendable, CaseIterable {
    case low, medium, high

    public var label: String { rawValue.capitalized }
}

public enum EffectParameterType: String, Codable, Hashable, Sendable, CaseIterable {
    case boolean, integer, number, choice, color, palette
}

/// Which native control renders a parameter. The mapping is pure so it can
/// be tested without SwiftUI.
public enum EffectParameterControl: Hashable, Sendable {
    case toggle
    /// Bounded integer: a slider with integer steps when the range is wide
    /// enough, else a stepper.
    case stepper(range: ClosedRange<Int>)
    case integerSlider(range: ClosedRange<Int>)
    case slider(range: ClosedRange<Double>, step: Double)
    /// Unbounded number: a text field.
    case numberField
    case menu(choices: [String])
    case colorWell
    case paletteEditor(minimum: Int, maximum: Int, allowEmpty: Bool)
}

public struct EffectParameter: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: EffectParameterType
    public var defaultValue: JSONValue
    public var description: String
    public var minimum: Double?
    public var maximum: Double?
    public var choices: [String]
    public var minimumItems: Int?
    public var maximumItems: Int?
    public var allowEmpty: Bool
    public var unit: String?

    public var id: String { name }

    public init(name: String, type: EffectParameterType, defaultValue: JSONValue, description: String = "",
                minimum: Double? = nil, maximum: Double? = nil, choices: [String] = [],
                minimumItems: Int? = nil, maximumItems: Int? = nil, allowEmpty: Bool = false, unit: String? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.choices = choices
        self.minimumItems = minimumItems
        self.maximumItems = maximumItems
        self.allowEmpty = allowEmpty
        self.unit = unit
    }

    enum CodingKeys: String, CodingKey {
        case name, type, description, minimum, maximum, choices, unit
        case defaultValue = "default"
        case minimumItems = "minimum_items"
        case maximumItems = "maximum_items"
        case allowEmpty = "allow_empty"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
        let rawType = try c.decodeIfPresent(String.self, forKey: .type) ?? "number"
        type = EffectParameterType(rawValue: rawType) ?? .number
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue) ?? .null
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        minimum = try c.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum)
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        minimumItems = try c.decodeIfPresent(Int.self, forKey: .minimumItems)
        maximumItems = try c.decodeIfPresent(Int.self, forKey: .maximumItems)
        allowEmpty = try c.decodeIfPresent(Bool.self, forKey: .allowEmpty) ?? false
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
    }

    /// "Duration seconds" from `duration_seconds`.
    public var title: String {
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// The native control for this parameter.
    public var control: EffectParameterControl {
        switch type {
        case .boolean:
            return .toggle
        case .integer:
            guard let minimum, let maximum else { return .numberField }
            let range = Int(minimum)...Int(max(minimum, maximum))
            // A seed spans billions: a slider is useless there.
            if range.count > 64 { return .stepper(range: range) }
            return .integerSlider(range: range)
        case .number:
            guard let minimum, let maximum, maximum > minimum else { return .numberField }
            let span = maximum - minimum
            let step: Double
            if span <= 1 { step = 0.01 } else if span <= 10 { step = 0.1 } else if span <= 100 { step = 1 } else { step = 5 }
            return .slider(range: minimum...maximum, step: step)
        case .choice:
            return .menu(choices: choices)
        case .color:
            return .colorWell
        case .palette:
            return .paletteEditor(minimum: minimumItems ?? 0, maximum: maximumItems ?? 8, allowEmpty: allowEmpty)
        }
    }

    /// Clamps `value` into the parameter's bounds and type; unknown shapes
    /// fall back to the default. Mirrors `EffectParameter.normalize`.
    public func normalize(_ value: JSONValue?) -> JSONValue {
        guard let value else { return defaultValue }
        switch type {
        case .boolean:
            return value.boolValue.map(JSONValue.bool) ?? defaultValue
        case .integer:
            guard let number = value.doubleValue else { return defaultValue }
            var rounded = number.rounded()
            if let minimum { rounded = max(minimum, rounded) }
            if let maximum { rounded = min(maximum, rounded) }
            return .number(rounded)
        case .number:
            guard var number = value.doubleValue, number.isFinite else { return defaultValue }
            if let minimum { number = max(minimum, number) }
            if let maximum { number = min(maximum, number) }
            return .number(number)
        case .choice:
            guard let text = value.stringValue, choices.contains(text) else { return defaultValue }
            return .string(text)
        case .color:
            guard let text = value.stringValue, Self.isHexColor(text) else { return defaultValue }
            return .string(text.uppercased())
        case .palette:
            guard let items = value.arrayValue else { return defaultValue }
            var colors = items.compactMap(\.stringValue).filter(Self.isHexColor).map { $0.uppercased() }
            if colors.isEmpty { return allowEmpty ? .array([]) : defaultValue }
            if let maximumItems, colors.count > maximumItems { colors = Array(colors.prefix(maximumItems)) }
            if let minimumItems, colors.count < minimumItems { return defaultValue }
            return .array(colors.map(JSONValue.string))
        }
    }

    public static func isHexColor(_ text: String) -> Bool {
        guard text.count == 7, text.hasPrefix("#") else { return false }
        return text.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// A named hard-blink cadence; the daemon guarantees on + off ≥ 500 ms.
public struct BlinkCadence: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var onMs: Int
    public var offMs: Int
    public var pulses: Int
    public var restMs: Int

    public init(id: String, label: String, onMs: Int, offMs: Int, pulses: Int = 1, restMs: Int = 0) {
        self.id = id
        self.label = label
        self.onMs = onMs
        self.offMs = offMs
        self.pulses = pulses
        self.restMs = restMs
    }

    enum CodingKeys: String, CodingKey {
        case id, label, pulses
        case onMs = "on_ms"
        case offMs = "off_ms"
        case restMs = "rest_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "?"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id.capitalized
        onMs = try c.decodeIfPresent(Int.self, forKey: .onMs) ?? 500
        offMs = try c.decodeIfPresent(Int.self, forKey: .offMs) ?? 500
        pulses = try c.decodeIfPresent(Int.self, forKey: .pulses) ?? 1
        restMs = try c.decodeIfPresent(Int.self, forKey: .restMs) ?? 0
    }

    public var peakHz: Double { 1000 / Double(onMs + offMs) }
    public var durationMs: Int { pulses * (onMs + offMs) + restMs }

    /// "1.0 Hz · 500 ms on / 500 ms off" for the safety caption.
    public var summary: String {
        var text = String(format: "%.1f Hz · %d ms on / %d ms off", peakHz, onMs, offMs)
        if pulses > 1 { text += " × \(pulses)" }
        if restMs > 0 { text += ", \(restMs) ms rest" }
        return text
    }
}

public struct EffectPreview: Codable, Hashable, Sendable {
    public var program: String
    public var ledCount: Int
    /// `render_effect` also reports the blink cadence the parameters chose.
    public var cadence: BlinkCadence?

    public init(program: String, ledCount: Int = 8, cadence: BlinkCadence? = nil) {
        self.program = program
        self.ledCount = ledCount
        self.cadence = cadence
    }

    enum CodingKeys: String, CodingKey {
        case program, cadence
        case ledCount = "led_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        program = try c.decodeIfPresent(String.self, forKey: .program) ?? "off"
        ledCount = try c.decodeIfPresent(Int.self, forKey: .ledCount) ?? 8
        cadence = try c.decodeIfPresent(BlinkCadence.self, forKey: .cadence)
    }
}

public struct EffectDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var meaning: String
    public var surfaces: [String]
    public var parameters: [EffectParameter]
    public var safety: EffectSafety
    public var energy: EffectEnergy
    public var reduceMotionFallback: String?
    public var version: Int
    public var catalog: String
    public var role: String
    /// The pack id for `pack:<pack>:<effect>` identifiers.
    public var pack: String?
    public var preview: EffectPreview?
    public var cadence: BlinkCadence?

    public init(id: String, label: String, description: String = "", meaning: String, surfaces: [String] = ["status_bar"],
                parameters: [EffectParameter] = [], safety: EffectSafety = .safe, energy: EffectEnergy = .low,
                reduceMotionFallback: String? = nil, version: Int = 1, catalog: String = "general", role: String = "general",
                pack: String? = nil, preview: EffectPreview? = nil, cadence: BlinkCadence? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.meaning = meaning
        self.surfaces = surfaces
        self.parameters = parameters
        self.safety = safety
        self.energy = energy
        self.reduceMotionFallback = reduceMotionFallback
        self.version = version
        self.catalog = catalog
        self.role = role
        self.pack = pack
        self.preview = preview
        self.cadence = cadence
    }

    enum CodingKeys: String, CodingKey {
        case id, label, description, meaning, surfaces, parameters, safety, energy, version, catalog, role, pack, preview, cadence
        case reduceMotionFallback = "reduce_motion_fallback"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        surfaces = try c.decodeIfPresent([String].self, forKey: .surfaces) ?? []
        parameters = try c.decodeIfPresent([EffectParameter].self, forKey: .parameters) ?? []
        safety = EffectSafety(rawValue: try c.decodeIfPresent(String.self, forKey: .safety) ?? "safe") ?? .safe
        energy = EffectEnergy(rawValue: try c.decodeIfPresent(String.self, forKey: .energy) ?? "low") ?? .low
        reduceMotionFallback = try c.decodeIfPresent(String.self, forKey: .reduceMotionFallback)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        catalog = try c.decodeIfPresent(String.self, forKey: .catalog) ?? "general"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "general"
        let explicitPack = try c.decodeIfPresent(String.self, forKey: .pack)
        pack = explicitPack ?? Self.packID(in: id)
        preview = try c.decodeIfPresent(EffectPreview.self, forKey: .preview)
        cadence = try c.decodeIfPresent(BlinkCadence.self, forKey: .cadence)
    }

    /// `pack:<pack>:<effect>` → `<pack>`.
    public static func packID(in identifier: String) -> String? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "pack" else { return nil }
        return String(parts[1])
    }

    public var isFromPack: Bool { pack != nil }

    /// The library groups effects by meaning; provider animations share
    /// one group, everything else uses its own meaning ("Attention required").
    public var meaningGroup: String {
        if catalog == "provider_animation" || meaning.hasPrefix("provider animation") { return "Provider animation" }
        if let pack { return "Pack · \(pack)" }
        let text = meaning.split(separator: ":").first.map(String.init) ?? meaning
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "Other" }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    /// The grey line under the description: the family this effect is in
    /// and what it is for. The daemon's `meaning` for a provider animation
    /// is "provider animation: chase" — the catalog and the id over again —
    /// so it is only added when it says something new ("attention
    /// required", "new event").
    public var familyLine: String {
        var parts = [Self.humanised(catalog)]
        let roleWord = role.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if !roleWord.isEmpty, roleWord.caseInsensitiveCompare("general") != .orderedSame,
           roleWord.caseInsensitiveCompare(parts[0]) != .orderedSame {
            parts.append(roleWord)
        }
        let text = meaning.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !restates(text) { parts.append(text) }
        return parts.joined(separator: " · ")
    }

    /// True when `meaning` is just "<catalog>: <id>" or "<catalog>: <label>".
    private func restates(_ meaning: String) -> Bool {
        let family = Self.humanised(catalog).lowercased()
        let text = meaning.lowercased().replacingOccurrences(of: "_", with: " ")
        for tail in [id.lowercased(), label.lowercased()] where text == "\(family): \(tail)" { return true }
        return text == family
    }

    /// `provider_animation` → "Provider animation", `identity_state` → "identity state".
    static func humanised(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return "" }
        return String(first).uppercased() + words.dropFirst()
    }

    public func parameter(named name: String) -> EffectParameter? { parameters.first { $0.name == name } }

    /// The complete parameter map with defaults for anything missing and
    /// out-of-range values clamped, in declared order.
    public func normalizedParameters(_ values: [String: JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for parameter in parameters {
            result[parameter.name] = parameter.normalize(values[parameter.name])
        }
        return result
    }

    public var defaultParameters: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.defaultValue) })
    }
}

public struct EffectPackLicense: Codable, Hashable, Sendable {
    public var spdxID: String
    public var label: String
    public var sourceURL: String?
    public var attributionURL: String?

    public init(spdxID: String, label: String, sourceURL: String? = nil, attributionURL: String? = nil) {
        self.spdxID = spdxID
        self.label = label
        self.sourceURL = sourceURL
        self.attributionURL = attributionURL
    }

    enum CodingKeys: String, CodingKey {
        case label
        case spdxID = "spdx_id"
        case sourceURL = "source_url"
        case attributionURL = "attribution_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spdxID = try c.decodeIfPresent(String.self, forKey: .spdxID) ?? "?"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? spdxID
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        attributionURL = try c.decodeIfPresent(String.self, forKey: .attributionURL)
    }
}

/// A data-only pack (JSON v2) the daemon has loaded; its effects appear in
/// the catalog as `pack:<id>:<effect>`.
public struct EffectPack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: Int
    public var effectIDs: [String]
    public var license: EffectPackLicense?
    public var path: String?

    public init(id: String, name: String, version: Int = 2, effectIDs: [String] = [], license: EffectPackLicense? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.effectIDs = effectIDs
        self.license = license
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, license, path
        case effectIDs = "effects"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        effectIDs = try c.decodeIfPresent([String].self, forKey: .effectIDs) ?? []
        license = try c.decodeIfPresent(EffectPackLicense.self, forKey: .license)
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

/// The reply of `list_effects`.
public struct EffectCatalog: Codable, Hashable, Sendable {
    public var effects: [EffectDefinition]
    public var packs: [EffectPack]
    public var cadences: [BlinkCadence]
    public var generation: Int

    public init(effects: [EffectDefinition] = [], packs: [EffectPack] = [], cadences: [BlinkCadence] = [], generation: Int = 0) {
        self.effects = effects
        self.packs = packs
        self.cadences = cadences
        self.generation = generation
    }

    enum CodingKeys: String, CodingKey { case effects, packs, cadences, generation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effects = try c.decodeIfPresent([EffectDefinition].self, forKey: .effects) ?? []
        packs = try c.decodeIfPresent([EffectPack].self, forKey: .packs) ?? []
        cadences = try c.decodeIfPresent([BlinkCadence].self, forKey: .cadences) ?? []
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
    }

    public func effect(_ id: String) -> EffectDefinition? { effects.first { $0.id == id } }

    public func pack(_ id: String) -> EffectPack? { packs.first { $0.id == id } }

    /// Effects matching `query` (id, label, description, meaning, pack),
    /// grouped by meaning in catalog order. Groups keep their first-seen order.
    public func groups(matching query: String = "") -> [(title: String, effects: [EffectDefinition])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var order: [String] = []
        var table: [String: [EffectDefinition]] = [:]
        for effect in effects {
            if !needle.isEmpty {
                let haystack = [effect.id, effect.label, effect.description, effect.meaning, effect.pack ?? "", effect.role]
                    .joined(separator: " ").lowercased()
                guard haystack.contains(needle) else { continue }
            }
            let group = effect.meaningGroup
            if table[group] == nil { order.append(group) }
            table[group, default: []].append(effect)
        }
        return order.map { (title: $0, effects: table[$0] ?? []) }
    }
}

public enum EffectScope: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case global, semantic, scene, provider
    case providerInstance = "provider_instance"
    case project, device

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .global: return "Everywhere"
        case .semantic: return "State"
        case .scene: return "Scene"
        case .provider: return "Provider"
        case .providerInstance: return "Provider instance"
        case .project: return "Project"
        case .device: return "Device"
        }
    }

    /// Every scope but `global` names a target.
    public var needsTarget: Bool { self != .global }

    /// Most specific first, the daemon's `_SCOPE_PRECEDENCE`.
    public static let precedence: [EffectScope] = [.device, .project, .providerInstance, .provider, .scene, .semantic, .global]
}

/// The semantic targets a `semantic` assignment may name; ASK and FAILURE
/// are urgent and keep their reserved effects.
public enum EffectSemantic: String, CaseIterable, Sendable, Identifiable {
    case asking, failure, notification, transition, working, completion, recovery, quota, environment, idle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .asking: return "Needs you"
        case .failure: return "Failed"
        case .notification: return "Notification"
        case .transition: return "Hand-off"
        case .working: return "Working"
        case .completion: return "Done"
        case .recovery: return "Recovered"
        case .quota: return "Quota"
        case .environment: return "Environment"
        case .idle: return "Idle"
        }
    }

    public var isUrgent: Bool { self == .asking || self == .failure }

    /// The states an assignment can actually fire on. The daemon's event
    /// router only arms completion and notification for non-urgent
    /// semantics (asking/failure keep their reserved alert), so offering
    /// Working/Idle/… here would write a row that can never play.
    public static let assignable: [EffectSemantic] = [.notification, .completion]
}

public enum EffectScene: String, CaseIterable, Sendable, Identifiable {
    case calm, focus, night, demo, travel, dnd

    public var id: String { rawValue }

    public var label: String { self == .dnd ? "Do Not Disturb" : rawValue.capitalized }
}

public struct EffectAssignment: Codable, Hashable, Sendable, Identifiable {
    public var effectID: String
    public var scope: EffectScope
    public var targetID: String?
    public var parameters: [String: JSONValue]

    /// One assignment per (scope, target); the effect is the value.
    public var id: String { Self.key(scope: scope, targetID: targetID) }

    public static func key(scope: EffectScope, targetID: String?) -> String { scope.rawValue + "|" + (targetID ?? "") }

    public init(effectID: String, scope: EffectScope, targetID: String? = nil, parameters: [String: JSONValue] = [:]) {
        self.effectID = effectID
        self.scope = scope
        self.targetID = targetID
        self.parameters = parameters
    }

    /// The daemon's `apply_effect` reply names rows `{effect, scope, target}`;
    /// the mock's fuller rows say `effect_id` / `target_id` and carry
    /// `parameters`. Both decode.
    enum CodingKeys: String, CodingKey {
        case scope, parameters, effect, target
        case effectID = "effect_id"
        case targetID = "target_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effectID = try c.decodeIfPresent(String.self, forKey: .effectID)
            ?? c.decodeIfPresent(String.self, forKey: .effect) ?? "none"
        scope = EffectScope(rawValue: try c.decodeIfPresent(String.self, forKey: .scope) ?? "global") ?? .global
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
            ?? c.decodeIfPresent(String.self, forKey: .target)
        parameters = try c.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(effectID, forKey: .effectID)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(targetID, forKey: .targetID)
        try c.encode(parameters, forKey: .parameters)
    }

    /// Mirrors `EffectAssignmentRecord.__post_init__`: global has no target,
    /// every other scope has one, and the urgent semantics are reserved.
    public enum Problem: Equatable, Sendable {
        case globalWithTarget, missingTarget, urgentSemantic
    }

    public var problem: Problem? {
        let target = targetID?.trimmingCharacters(in: .whitespaces) ?? ""
        if scope == .global { return target.isEmpty ? nil : .globalWithTarget }
        if target.isEmpty { return .missingTarget }
        if scope == .semantic, let semantic = EffectSemantic(rawValue: target), semantic.isUrgent { return .urgentSemantic }
        return nil
    }

    /// "Working", "Codex", "Night", the raw id for devices and projects.
    public var targetLabel: String {
        guard let targetID else { return "Everywhere" }
        switch scope {
        case .semantic: return EffectSemantic(rawValue: targetID)?.label ?? targetID
        case .scene: return EffectScene(rawValue: targetID)?.label ?? targetID.capitalized
        default: return targetID
        }
    }
}

/// The reply of `list_assignments`/`set_assignment`/`clear_assignment`.
public struct EffectAssignmentDocument: Codable, Hashable, Sendable {
    public var assignments: [EffectAssignment]
    public var activeScene: String?
    public var generation: Int
    /// `set_assignment` adds this when the row persisted but its
    /// provider-motion write to settings failed — the assignment exists
    /// yet the persistent animation did not land.
    public var motionWarning: String?

    public init(assignments: [EffectAssignment] = [], activeScene: String? = nil, generation: Int = 0,
                motionWarning: String? = nil) {
        self.assignments = assignments
        self.activeScene = activeScene
        self.generation = generation
        self.motionWarning = motionWarning
    }

    enum CodingKeys: String, CodingKey {
        case assignments, generation
        case activeScene = "active_scene"
        case motionWarning = "motion_warning"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try c.decodeIfPresent([EffectAssignment].self, forKey: .assignments) ?? []
        activeScene = try c.decodeIfPresent(String.self, forKey: .activeScene)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        motionWarning = try c.decodeIfPresent(String.self, forKey: .motionWarning)
    }

    public func assignment(scope: EffectScope, targetID: String?) -> EffectAssignment? {
        assignments.first { $0.scope == scope && $0.targetID == targetID }
    }

    /// Assignments by scope in precedence order (most specific first),
    /// skipping empty scopes.
    public var byScope: [(scope: EffectScope, assignments: [EffectAssignment])] {
        EffectScope.precedence.compactMap { scope in
            let rows = assignments.filter { $0.scope == scope }.sorted { ($0.targetID ?? "") < ($1.targetID ?? "") }
            return rows.isEmpty ? nil : (scope: scope, assignments: rows)
        }
    }

    /// The effects that any assignment uses, for "used by" badges.
    public func usage(of effectID: String) -> [EffectAssignment] { assignments.filter { $0.effectID == effectID } }
}

/// A scene pack as `list_scene_packs` reports it: an installable bundle of
/// named scenes, each scene a set of per-state effect picks.
public struct ScenePackSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var scenes: [String]
    public var installed: Bool

    public init(id: String, name: String? = nil, scenes: [String] = [], installed: Bool = false) {
        self.id = id
        self.name = name
        self.scenes = scenes
        self.installed = installed
    }

    /// What the row should show — the pack's human name before its slug.
    public var displayName: String { name ?? id }
}

/// Decodes a `reply.result` (a `JSONValue`) into a Codable model.
public enum ReplyDecoding {
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        let data = try JSONEncoder().encode(value ?? .object([:]))
        return try JSONDecoder().decode(type, from: data)
    }
}
