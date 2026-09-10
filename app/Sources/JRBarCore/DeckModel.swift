import CoreGraphics
import Foundation

// The Creator Micro 2 "deck": thirteen identity-scoped session slots per
// bank on a key matrix of rows [2, 4, 4, 3] (vendor keycodes
// KV_OAI_AG00..AG12), seven auxiliary controls AG13..AG19 (one encoder with
// three inputs, four joystick sectors), four analog sectors (20..23), a
// compact edge rail, and a keymap the daemon applies and restores. Mirrors
// src/jrbar/deck_session_board.py, creator_micro_keymap.py and
// creator_micro_lighting.py. `state.deck` is an app-proposed protocol
// extension (see app/README.md); every field is optional so a daemon
// without a deck decodes to nothing.

/// How the pad is attached. USB is preferred when both are present.
public enum DeckTransport: String, Codable, Hashable, Sendable {
    case bluetooth
    case usb

    public var label: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .usb: return "USB"
        }
    }
}

/// The last thing the daemon's keymap or device layer reported: a receipt
/// code and its user-facing sentence.
public struct DeckReceipt: Codable, Hashable, Sendable {
    public var code: String
    public var message: String?
    public var at: Double?

    public init(code: String, message: String? = nil, at: Double? = nil) {
        self.code = code
        self.message = message
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case code, message, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? "unknown"
        message = try c.decodeIfPresent(String.self, forKey: .message)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
    }

    /// The sentence to show: the daemon's, else the Python app's table.
    public var text: String { message ?? DeckReceiptMessages.message(for: code) }

    /// Receipts that mean the pad cannot be written right now.
    public var isProblem: Bool { DeckReceiptMessages.problems.contains(code) }
}

/// The user-facing strings of `creator_micro_setup_controller.py`, verbatim,
/// so a daemon that sends only a code still reads right.
public enum DeckReceiptMessages {
    public static let table: [String: String] = [
        "keymap_verified": "Creator Micro 2 stored keymap verified. Reconnect if needed, then check inputs.",
        "recovery_required": "A transfer was interrupted. Backup retained. Choose Restore device keymap, not Apply again.",
        "unsupported_file_protocol": "This firmware does not support the verified file-transfer protocol. No keymap was written.",
        "connection_changed": "The device connection changed. Inspect again; pending input was discarded.",
        "device_conflict": "Close Input and other hardware controllers, then inspect again.",
        "already_configured": "Creator Micro 2 keymap is already configured.",
        "keymap_restored": "Creator Micro 2 keymap restored and verified.",
        "already_restored": "Creator Micro 2 keymap is already restored.",
        "connection_required": "Connect and approve Creator Micro 2 before setup.",
        "approved_device_changed": "The approved Creator Micro 2 changed. Inspect it again.",
        "previous_owner_stopping": "Creator Micro 2 is still stopping. Try again in a moment.",
        "keymap_changed": "The device keymap changed. Inspect it again before applying.",
        "backup_failed": "The private backup could not be verified. No keymap was written.",
        "backup_invalid": "No valid private backup is available. No keymap was written.",
        "readback_mismatch": "The device did not verify the keymap write. The backup was kept.",
        "cancelled": "Creator Micro 2 setup was cancelled.",
    ]

    public static let problems: Set<String> = [
        "recovery_required", "device_conflict", "connection_changed", "connection_required", "approved_device_changed",
        "previous_owner_stopping", "keymap_changed", "backup_failed", "backup_invalid", "backup_conflict",
        "readback_mismatch", "readback_failed", "unsupported_file_protocol", "invalid_plan", "setup_failed",
    ]

    public static func message(for code: String) -> String {
        table[code] ?? "Creator Micro 2: \(code.replacingOccurrences(of: "_", with: " "))."
    }
}

/// The device the daemon is talking to (or not).
public struct DeckDevice: Codable, Hashable, Sendable {
    public var serial: String?
    public var name: String?
    public var transport: DeckTransport?
    public var connected: Bool
    public var approved: Bool
    public var firmware: String?
    public var layer: Int?
    public var profile: Int?
    /// `nil`, or a runtime reason such as `foreign_responses`: another app
    /// answered on the same report stream. The firmware has no ownership
    /// handshake, so the daemon stops writing rather than fight for it.
    public var conflict: String?
    public var receipt: DeckReceipt?

    public init(serial: String? = nil, name: String? = nil, transport: DeckTransport? = nil, connected: Bool = false,
                approved: Bool = false, firmware: String? = nil, layer: Int? = nil, profile: Int? = nil,
                conflict: String? = nil, receipt: DeckReceipt? = nil) {
        self.serial = serial
        self.name = name
        self.transport = transport
        self.connected = connected
        self.approved = approved
        self.firmware = firmware
        self.layer = layer
        self.profile = profile
        self.conflict = conflict
        self.receipt = receipt
    }

    enum CodingKeys: String, CodingKey { case serial, name, transport, connected, approved, firmware, layer, profile, conflict, receipt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        transport = try? c.decodeIfPresent(DeckTransport.self, forKey: .transport)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
        layer = try c.decodeIfPresent(Int.self, forKey: .layer)
        profile = try c.decodeIfPresent(Int.self, forKey: .profile)
        conflict = try c.decodeIfPresent(String.self, forKey: .conflict)
        receipt = try? c.decodeIfPresent(DeckReceipt.self, forKey: .receipt)
    }

    public var hasConflict: Bool { !(conflict ?? "").isEmpty }

    /// The device is there and the daemon may drive it.
    public var isUsable: Bool { connected && approved && !hasConflict }

    public var displayName: String { name ?? "Creator Micro 2" }

    /// The exact sentence the Python app uses for a conflict.
    public static let conflictText = "Another app is talking to the device; JR-Bar stopped writing"
}

/// The board's state vocabulary (`deck_session_board.py`) with the display
/// names of `deck_control_center_window.py`.
public enum DeckSlotState: String, Codable, Hashable, Sendable, CaseIterable {
    case inputRequired = "input_required"
    case failure
    case active
    case completed
    case idle
    case stale
    case unavailable
    case unknown
    case endedUnconfirmed = "ended_unconfirmed"

    public var displayName: String {
        switch self {
        case .inputRequired: return "Needs you"
        case .failure: return "Error"
        case .active: return "Working"
        case .completed: return "Completed"
        case .idle: return "Idle"
        case .stale: return "Stale"
        case .unavailable: return "Not observed"
        case .unknown: return "Unknown"
        case .endedUnconfirmed: return "Ended, unconfirmed"
        }
    }

    /// The rail's mark: "!" for attention, "·" for work, nothing otherwise.
    public var railMark: String {
        switch self {
        case .inputRequired, .failure: return "!"
        case .active: return "·"
        default: return ""
        }
    }

    public var needsAttention: Bool { self == .inputRequired || self == .failure }

    /// The colour the lighting layer gives this state (solid, no breathing).
    public var lightingHex: String {
        switch self {
        case .inputRequired, .failure: return DeckLighting.askHex
        case .active: return DeckLighting.workingHex
        case .completed: return DeckLighting.doneHex
        default: return DeckLighting.idleHex
        }
    }
}

/// `creator_micro_lighting.py`: per-key colour modes.
public enum DeckLighting {
    public static let askHex = "#FF3A00"
    public static let workingHex = "#00E5FF"
    public static let doneHex = "#00FF66"
    public static let idleHex = "#020204"

    /// Dark enough to count as "off" when drawing a key.
    public static func isDark(_ hex: String?) -> Bool {
        guard let hex else { return true }
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return true }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        return max(r, g, b) < 0x10
    }
}

/// One of the thirteen session slots of the current bank.
public struct DeckSlot: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    /// The board's stable identity (a digest of the work key), or nil for an
    /// unassigned slot.
    public var identity: String?
    /// The live session id, or nil when the identity is remembered but the
    /// session is not observed ("Reserved").
    public var session: String?
    public var label: String?
    public var provider: String?
    public var state: DeckSlotState
    public var pinned: Bool
    /// A press reveals something.
    public var navigable: Bool
    /// `#RRGGBB` the key is lit with.
    public var color: String?

    public var id: Int { index }

    public init(index: Int, identity: String? = nil, session: String? = nil, label: String? = nil, provider: String? = nil,
                state: DeckSlotState = .unavailable, pinned: Bool = false, navigable: Bool = false, color: String? = nil) {
        self.index = index
        self.identity = identity
        self.session = session
        self.label = label
        self.provider = provider
        self.state = state
        self.pinned = pinned
        self.navigable = navigable
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case index, identity, session, label, provider, state, pinned, navigable, color }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        state = (try? c.decodeIfPresent(DeckSlotState.self, forKey: .state)) ?? .unknown
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        navigable = try c.decodeIfPresent(Bool.self, forKey: .navigable) ?? (session != nil)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    /// Nothing assigned: no identity at all.
    public var isEmpty: Bool { identity == nil }

    /// An identity the board keeps whose session is not observed.
    public var isReserved: Bool { identity != nil && session == nil }

    /// "Unassigned" / "Reserved" / the label, as the Python board titles
    /// it — through `SessionLabel`, so a key never reads "Claude Claude
    /// fca1eb06-f6d1-…" where every other surface says "fca1eb06".
    public var title: String {
        if let label, !label.isEmpty {
            return SessionLabel.display(label: label, shortId: nil, id: session ?? identity ?? "", provider: provider ?? "")
        }
        return isEmpty ? "Unassigned" : "Reserved"
    }

    /// The second line: the state word, or the board's subtitle for the two
    /// kinds of empty key.
    public var subtitle: String {
        if isEmpty { return "No session assigned" }
        if isReserved { return "Session not observed" }
        return state.displayName
    }

    /// The subtitle as it fits on a key: the state word, "Not observed" for
    /// a reserved key, "No session" for an unassigned one.
    public var shortSubtitle: String {
        if isEmpty { return "No session" }
        if isReserved { return DeckSlotState.unavailable.displayName }
        return state.displayName
    }

    /// The key is lit with something other than dark.
    public var isLit: Bool { !DeckLighting.isDark(color) }
}

/// One of the seven auxiliary controls (AG13..AG19).
public struct DeckAuxControl: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var label: String
    /// The explicit mapping bound to it (`next_bank`, `open_usage`, …), if any.
    public var mapping: String?

    public var id: Int { index }

    public init(index: Int, label: String, mapping: String? = nil) {
        self.index = index
        self.label = label
        self.mapping = mapping
    }

    enum CodingKeys: String, CodingKey { case index, label, mapping }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? DeckControls.label(for: index)
        mapping = try c.decodeIfPresent(String.self, forKey: .mapping)
    }

    public var isEncoder: Bool { DeckControls.encoderIndices.contains(index) }
    public var isJoystick: Bool { DeckControls.joystickIndices.contains(index) }

    /// A readable name for the mapping.
    public var mappingLabel: String? { mapping.map(DeckControls.actionLabel) }
}

/// The pad's controls by index: which are keys, which the encoder, which
/// the joystick, how they are laid out, and what to call them.
public enum DeckControls {
    /// Session slots per bank, and the key matrix rows.
    public static let slotCount = 13
    public static let rows = [2, 4, 4, 3]
    /// Auxiliary controls AG13..AG19.
    public static let auxIndices = 13..<20
    public static let encoderIndices = 13..<16
    public static let joystickIndices = 16..<20
    /// Calibrated analog joystick sectors, indices 20..23.
    public static let analogIndices = 20..<24
    public static let controlCount = 24

    /// (row, column) of a key in the matrix.
    public static func position(of index: Int) -> (row: Int, column: Int)? {
        guard (0..<slotCount).contains(index) else { return nil }
        var start = 0
        for (row, width) in rows.enumerated() {
            if index < start + width { return (row, index - start) }
            start += width
        }
        return nil
    }

    /// The key indices of each matrix row.
    public static var rowIndices: [[Int]] {
        var start = 0
        return rows.map { width in
            defer { start += width }
            return Array(start..<start + width)
        }
    }

    public static func label(for index: Int) -> String {
        switch index {
        case 0..<slotCount: return "Key \(index + 1)"
        case encoderIndices: return "Encoder 1 input \(index - encoderIndices.lowerBound + 1)"
        case joystickIndices: return "Joystick sector \(index - joystickIndices.lowerBound + 1)"
        case analogIndices: return "Analog sector \(index - analogIndices.lowerBound + 1)"
        default: return String(format: "AG%02d", index)
        }
    }

    /// The vendor keycode the keymap writes for a control.
    public static func keycode(for index: Int) -> String { String(format: "KV_OAI_AG%02d", index) }

    /// Display names for the explicit deck actions (`deck_actions.py`).
    public static func actionLabel(_ action: String) -> String {
        switch action {
        case "open_app": return "Open app"
        case "shortcut": return "Shortcut"
        case "reveal_current_ask": return "Reveal current ask"
        case "open_agent_browser": return "Agent Browser"
        case "open_usage": return "Usage Center"
        case "open_control_center": return "Control Center"
        case "next_bank": return "Next bank"
        case "previous_bank": return "Previous bank"
        case "run_system_shortcut": return "System shortcut"
        case "reveal_session": return "Reveal session"
        default: return action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct DeckBanks: Codable, Hashable, Sendable {
    public var index: Int
    public var count: Int

    public init(index: Int = 0, count: Int = 1) {
        self.count = max(1, count)
        self.index = min(max(0, index), self.count - 1)
    }

    enum CodingKeys: String, CodingKey { case index, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(1, try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        index = min(max(0, try c.decodeIfPresent(Int.self, forKey: .index) ?? 0), count - 1)
    }

    /// The bank `delta` steps away, wrapping at both ends. With one bank
    /// every step lands on it.
    public func advanced(by delta: Int) -> DeckBanks {
        var copy = self
        let n = max(1, count)
        copy.index = ((index + delta) % n + n) % n
        return copy
    }

    public var hasMultiple: Bool { count > 1 }

    /// "Bank 2 of 3".
    public var title: String { "Bank \(index + 1) of \(count)" }
}

/// Where the compact rail sits. `off` hides it.
public enum DeckRailEdge: String, Codable, Hashable, Sendable, CaseIterable {
    case off, left, right, top, bottom

    public var label: String {
        switch self {
        case .off: return "Off"
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .top: return "Top edge"
        case .bottom: return "Bottom edge"
        }
    }

    public var isShown: Bool { self != .off }
    public var isVertical: Bool { self == .left || self == .right }
}

public struct DeckRail: Codable, Hashable, Sendable {
    public var edge: DeckRailEdge

    public init(edge: DeckRailEdge = .off) { self.edge = edge }

    enum CodingKeys: String, CodingKey { case edge }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = (try? c.decodeIfPresent(DeckRailEdge.self, forKey: .edge)) ?? .off
    }

    public var isShown: Bool { edge.isShown }
}

public enum DeckKeymapState: String, Codable, Hashable, Sendable {
    /// The pad still has its original keymap; presses type ordinary keys.
    case stock
    /// The daemon wrote `KV_OAI_AG00..12` to one layer; the first original
    /// is backed up next to the integration settings and never overwritten.
    case applied
    /// A transfer was interrupted; Restore is the only way forward.
    case recovering
    case unknown

    public var label: String {
        switch self {
        case .stock: return "Original keymap"
        case .applied: return "JR-Bar keymap"
        case .recovering: return "Recovery required"
        case .unknown: return "Keymap unknown"
        }
    }
}

/// One editable profile/layer of the pad's keymap.
public struct DeckKeymapLayer: Codable, Hashable, Sendable, Identifiable {
    public var profile: Int
    public var layer: Int
    public var label: String

    public var id: String { "\(profile)/\(layer)" }

    public init(profile: Int, layer: Int, label: String? = nil) {
        self.profile = profile
        self.layer = layer
        self.label = label ?? "Profile \(profile + 1) / Layer \(layer + 1)"
    }

    enum CodingKeys: String, CodingKey { case profile, layer, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(Int.self, forKey: .profile) ?? 0
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Profile \(profile + 1) / Layer \(layer + 1)"
    }
}

public struct DeckKeymap: Codable, Hashable, Sendable {
    public var state: DeckKeymapState
    public var backupAt: Double?
    /// The transfer generation the backup and any pending recovery are bound
    /// to; a reconnect starts a new one and never resumes an old write.
    public var generation: Int?
    public var layers: [DeckKeymapLayer]

    public init(state: DeckKeymapState = .stock, backupAt: Double? = nil, generation: Int? = nil, layers: [DeckKeymapLayer] = []) {
        self.state = state
        self.backupAt = backupAt
        self.generation = generation
        self.layers = layers
    }

    enum CodingKeys: String, CodingKey {
        case state, generation, layers
        case backupAt = "backup_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decodeIfPresent(DeckKeymapState.self, forKey: .state)) ?? .unknown
        backupAt = try c.decodeIfPresent(Double.self, forKey: .backupAt)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation)
        layers = (try? c.decodeIfPresent([DeckKeymapLayer].self, forKey: .layers)) ?? []
    }

    public var isApplied: Bool { state == .applied }
    public var needsRecovery: Bool { state == .recovering }
    public var label: String { state.label }
}

/// `deck_plan_keymap`'s reply: what Apply would change, as the Python
/// review alert shows it.
public struct DeckKeymapPlan: Hashable, Sendable {
    public var profile: Int
    public var layer: Int
    public var includeAuxiliary: Bool
    public var changes: [String]
    public var preview: String
    public var controls: [(index: Int, label: String)]

    public init(profile: Int, layer: Int, includeAuxiliary: Bool, changes: [String], preview: String,
                controls: [(index: Int, label: String)] = []) {
        self.profile = profile
        self.layer = layer
        self.includeAuxiliary = includeAuxiliary
        self.changes = changes
        self.preview = preview
        self.controls = controls
    }

    public init?(_ value: JSONValue?) {
        guard let value, let preview = value["preview"]?.stringValue else { return nil }
        profile = value["profile"]?.intValue ?? 0
        layer = value["layer"]?.intValue ?? 0
        includeAuxiliary = value["include_auxiliary"]?.boolValue ?? false
        changes = value["changes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.preview = preview
        controls = value["controls"]?.arrayValue?.compactMap { row in
            guard let index = row["index"]?.intValue else { return nil }
            return (index, row["label"]?.stringValue ?? DeckControls.label(for: index))
        } ?? []
    }

    public var isNoop: Bool { changes.isEmpty }

    public static func == (lhs: DeckKeymapPlan, rhs: DeckKeymapPlan) -> Bool {
        lhs.profile == rhs.profile && lhs.layer == rhs.layer && lhs.includeAuxiliary == rhs.includeAuxiliary
            && lhs.changes == rhs.changes && lhs.preview == rhs.preview && lhs.controls.map(\.index) == rhs.controls.map(\.index)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(profile)
        hasher.combine(layer)
        hasher.combine(includeAuxiliary)
        hasher.combine(preview)
    }
}

/// A physical input the daemon observed: `state.last_input` and the
/// `deck_input` event's `input`.
public struct DeckInput: Codable, Hashable, Sendable {
    public var index: Int
    /// `press` (a key), `dial`, `joystick`, `analog`.
    public var kind: String
    public var at: Double?

    public init(index: Int, kind: String = "press", at: Double? = nil) {
        self.index = index
        self.kind = kind
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case index, kind, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "press"
        at = try c.decodeIfPresent(Double.self, forKey: .at)
    }

    public var label: String { DeckControls.label(for: index) }

    /// "Key 3 pressed", "Encoder 1 input 2 turned", …
    public var sentence: String {
        switch kind {
        case "dial": return "\(label) turned"
        case "joystick", "analog": return "\(label) moved"
        default: return "\(label) pressed"
        }
    }
}

/// `deck-controls.json`: the three switches of the Devices card.
public struct DeckSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var sessionMode: Bool
    public var analogEnabled: Bool

    public init(enabled: Bool = false, sessionMode: Bool = true, analogEnabled: Bool = false) {
        self.enabled = enabled
        self.sessionMode = sessionMode
        self.analogEnabled = analogEnabled
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case sessionMode = "session_mode"
        case analogEnabled = "analog_enabled"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sessionMode = try c.decodeIfPresent(Bool.self, forKey: .sessionMode) ?? true
        analogEnabled = try c.decodeIfPresent(Bool.self, forKey: .analogEnabled) ?? false
    }
}

/// `state.deck`.
public struct DeckState: Codable, Hashable, Sendable {
    public var device: DeckDevice?
    public var slots: [DeckSlot]
    public var aux: [DeckAuxControl]
    public var banks: DeckBanks
    public var rail: DeckRail
    public var keymap: DeckKeymap
    /// Input check: the daemon forwards inputs as `deck_input` events and
    /// pauses the actions bound to them.
    public var inputCheck: Bool
    public var lastInput: DeckInput?
    public var settings: DeckSettings

    public init(device: DeckDevice? = nil, slots: [DeckSlot] = [], aux: [DeckAuxControl] = [], banks: DeckBanks = DeckBanks(),
                rail: DeckRail = DeckRail(), keymap: DeckKeymap = DeckKeymap(), inputCheck: Bool = false,
                lastInput: DeckInput? = nil, settings: DeckSettings = DeckSettings()) {
        self.device = device
        self.slots = slots
        self.aux = aux
        self.banks = banks
        self.rail = rail
        self.keymap = keymap
        self.inputCheck = inputCheck
        self.lastInput = lastInput
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case device, slots, aux, banks, rail, keymap, settings
        case inputCheck = "input_check"
        case lastInput = "last_input"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decodeIfPresent(DeckDevice.self, forKey: .device)
        slots = (try? c.decodeIfPresent([DeckSlot].self, forKey: .slots)) ?? []
        aux = (try? c.decodeIfPresent([DeckAuxControl].self, forKey: .aux)) ?? []
        banks = try c.decodeIfPresent(DeckBanks.self, forKey: .banks) ?? DeckBanks()
        rail = try c.decodeIfPresent(DeckRail.self, forKey: .rail) ?? DeckRail()
        keymap = try c.decodeIfPresent(DeckKeymap.self, forKey: .keymap) ?? DeckKeymap()
        inputCheck = try c.decodeIfPresent(Bool.self, forKey: .inputCheck) ?? false
        lastInput = try? c.decodeIfPresent(DeckInput.self, forKey: .lastInput)
        settings = try c.decodeIfPresent(DeckSettings.self, forKey: .settings) ?? DeckSettings()
    }

    /// Exactly thirteen slots in key order, padded with unassigned ones so
    /// the grid and the rail never have a hole; anything outside the bank
    /// is dropped.
    public var keySlots: [DeckSlot] {
        var byIndex: [Int: DeckSlot] = [:]
        for slot in slots where (0..<DeckControls.slotCount).contains(slot.index) { byIndex[slot.index] = slot }
        return (0..<DeckControls.slotCount).map { byIndex[$0] ?? DeckSlot(index: $0) }
    }

    /// The seven auxiliary controls, padded with their default labels.
    public var auxControls: [DeckAuxControl] {
        var byIndex: [Int: DeckAuxControl] = [:]
        for control in aux where DeckControls.auxIndices.contains(control.index) { byIndex[control.index] = control }
        return DeckControls.auxIndices.map { byIndex[$0] ?? DeckAuxControl(index: $0, label: DeckControls.label(for: $0)) }
    }

    public func slot(at index: Int) -> DeckSlot? {
        guard (0..<DeckControls.slotCount).contains(index) else { return nil }
        return keySlots[index]
    }

    public func slot(bound session: String) -> DeckSlot? { keySlots.first { $0.session == session } }

    /// The device is present.
    public var hasDevice: Bool { device?.connected == true }

    /// The rail is a host-side surface: it needs no pad, only an edge.
    public var railShown: Bool { rail.isShown }

    /// Sessions bound anywhere on the current bank.
    public var boundSessions: Set<String> { Set(slots.compactMap(\.session)) }

    /// Slots that would leave the board on Clear absent: unpinned and not observed.
    public var absentSlots: [DeckSlot] { keySlots.filter { $0.isReserved && !$0.pinned } }

    // MARK: Reducers

    /// The state after `deck_pin {index}` succeeds, for an optimistic overlay.
    public func togglingPin(at index: Int) -> DeckState {
        var copy = self
        copy.slots = keySlots.map { slot in
            guard slot.index == index, !slot.isEmpty else { return slot }
            var slot = slot
            slot.pinned.toggle()
            return slot
        }
        return copy
    }

    /// The state after `deck_bank {delta}`: the bank number moves, the slots
    /// are unknown until the daemon sends them, so they are cleared.
    public func advancingBank(by delta: Int) -> DeckState {
        var copy = self
        copy.banks = banks.advanced(by: delta)
        if copy.banks.index != banks.index { copy.slots = [] }
        return copy
    }

    /// The state after `deck_clear_absent`: unpinned, unobserved identities
    /// leave and later keys move up.
    public func clearingAbsent() -> DeckState {
        var copy = self
        let kept = keySlots.filter { !$0.isReserved || $0.pinned }.filter { !$0.isEmpty }
        copy.slots = kept.enumerated().map { offset, slot in
            var slot = slot
            slot.index = offset
            return slot
        }
        return copy
    }

    public func settingRail(edge: DeckRailEdge) -> DeckState {
        var copy = self
        copy.rail.edge = edge
        return copy
    }
}

// MARK: - Input flashes

/// Controls lit by `deck_input` events, each for a short while, so "press a
/// key, see it light" works without the daemon re-sending state.
public struct DeckInputFlashes: Hashable, Sendable {
    public static let duration: TimeInterval = 0.9

    public struct Flash: Hashable, Sendable {
        public var index: Int
        public var kind: String
        public var until: Double
    }

    public private(set) var flashes: [Int: Flash] = [:]

    public init() {}

    /// Records an input: any of the 24 controls lights for 0.9 s; anything
    /// else is ignored.
    public mutating func record(_ input: DeckInput, at now: Double) {
        guard (0..<DeckControls.controlCount).contains(input.index) else { return }
        flashes[input.index] = Flash(index: input.index, kind: input.kind, until: now + Self.duration)
    }

    public mutating func expire(at now: Double) {
        flashes = flashes.filter { $0.value.until > now }
    }

    public func isLit(_ index: Int, at now: Double) -> Bool {
        guard let flash = flashes[index] else { return false }
        return flash.until > now
    }

    public var isEmpty: Bool { flashes.isEmpty }

    /// The soonest expiry still pending, for a timer.
    public var nextExpiry: Double? { flashes.values.map(\.until).min() }
}

// MARK: - Rail geometry

/// Where the rail sits and how its fourteen cells (thirteen slots and "…")
/// run along it, as `deck_control_center_window.py` lays it out: a cell is
/// 18–30 pt, the band 34 pt deep. Pure arithmetic over the screen's visible
/// frame (AppKit coordinates, origin bottom-left) so it can be tested
/// without a screen.
public struct DeckRailGeometry: Sendable {
    public static let cellCount = DeckControls.slotCount + 1
    public static let minCell: CGFloat = 18
    public static let maxCell: CGFloat = 30
    public static let depth: CGFloat = 34
    /// Inset from the screen edge so the glass never touches the corner radius.
    public static let edgeInset: CGFloat = 4
    /// Cell padding across the band (the Python buttons are 30 pt in a 34 pt band).
    public static let cellInset: CGFloat = 2

    public let edge: DeckRailEdge
    /// One cell's run along the edge.
    public let unit: CGFloat
    /// The panel's frame in screen coordinates.
    public let frame: CGRect
    /// Each cell's rect in the panel's own coordinates (origin bottom-left),
    /// slot 0 first, the "…" cell last.
    public let cellRects: [CGRect]

    /// The cell size for an edge of `extent` points: `(extent - 20) / 14`, clamped.
    public static func unit(forExtent extent: CGFloat) -> CGFloat {
        min(maxCell, max(minCell, (extent - 20) / CGFloat(cellCount)))
    }

    public init(edge: DeckRailEdge, visibleFrame: CGRect) {
        self.edge = edge
        let vf = visibleFrame
        let extent = edge.isVertical ? vf.height : vf.width
        let unit = Self.unit(forExtent: extent)
        self.unit = unit
        let run = unit * CGFloat(Self.cellCount)
        let d = Self.depth
        let frame: CGRect
        switch edge {
        case .left, .off:
            frame = CGRect(x: vf.minX + Self.edgeInset, y: vf.midY - run / 2, width: d, height: run)
        case .right:
            frame = CGRect(x: vf.maxX - Self.edgeInset - d, y: vf.midY - run / 2, width: d, height: run)
        case .top:
            frame = CGRect(x: vf.midX - run / 2, y: vf.maxY - Self.edgeInset - d, width: run, height: d)
        case .bottom:
            frame = CGRect(x: vf.midX - run / 2, y: vf.minY + Self.edgeInset, width: run, height: d)
        }
        // Whole points, with the size kept exact: `integral` would grow the
        // strip by a point when the screen's midpoint is a half.
        self.frame = CGRect(x: frame.origin.x.rounded(), y: frame.origin.y.rounded(), width: frame.width, height: frame.height)
        var rects: [CGRect] = []
        for i in 0..<Self.cellCount {
            let offset = CGFloat(i) * unit
            if edge.isVertical || edge == .off {
                // Slot 0 at the top, like the pad's first key.
                rects.append(CGRect(x: Self.cellInset, y: run - offset - unit, width: d - Self.cellInset * 2, height: unit))
            } else {
                rects.append(CGRect(x: offset, y: Self.cellInset, width: unit, height: d - Self.cellInset * 2))
            }
        }
        self.cellRects = rects
    }

    /// The cell under a point in the panel's coordinates: 0..12 a slot, 13
    /// the "…" cell, nil outside.
    public func cell(at point: CGPoint) -> Int? {
        cellRects.firstIndex { $0.contains(point) }
    }

    public static func isOverflowCell(_ index: Int) -> Bool { index == DeckControls.slotCount }
}
