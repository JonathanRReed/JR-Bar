import Foundation

/// The remembered state of everything on the Toys page: the fun-first
/// features that track no agents and manage no usage (docs/TOYS.md).
/// Lives inside `AppState.toys` — `app-state.json`, never `UserDefaults`
/// (cfprefsd refuses this app's writes on the owner's Mac; see
/// `AppState.swift`). Every level decodes tolerantly: a missing or
/// mistyped key falls back to its default and unknown keys are ignored,
/// so an older or newer build can share the file.
public struct ToysState: Codable, Equatable, Sendable {
    public var fold: FoldSettings
    public var aquarium: AquariumSettings
    public var notchBuddy: NotchBuddySettings
    public var confetti: ConfettiSettings
    /// Apps the user asked JR-Bar to sit next to, by bundle id.
    public var externalApps: [ExternalToyApp]

    public init(fold: FoldSettings = FoldSettings(), aquarium: AquariumSettings = AquariumSettings(),
                notchBuddy: NotchBuddySettings = NotchBuddySettings(), confetti: ConfettiSettings = ConfettiSettings(),
                externalApps: [ExternalToyApp] = []) {
        self.fold = fold
        self.aquarium = aquarium
        self.notchBuddy = notchBuddy
        self.confetti = confetti
        self.externalApps = externalApps
    }

    private enum CodingKeys: String, CodingKey {
        case fold, aquarium, notchBuddy, confetti, externalApps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fold = (try? c.decodeIfPresent(FoldSettings.self, forKey: .fold)) ?? FoldSettings()
        aquarium = (try? c.decodeIfPresent(AquariumSettings.self, forKey: .aquarium)) ?? AquariumSettings()
        notchBuddy = (try? c.decodeIfPresent(NotchBuddySettings.self, forKey: .notchBuddy)) ?? NotchBuddySettings()
        confetti = (try? c.decodeIfPresent(ConfettiSettings.self, forKey: .confetti)) ?? ConfettiSettings()
        // An app with no bundle id can never be launched or found again;
        // it is dropped rather than carried as a dead row.
        externalApps = ((try? c.decodeIfPresent([ExternalToyApp].self, forKey: .externalApps)) ?? [])
            .filter { !$0.id.isEmpty }
    }
}

/// Fold: the desktop tilt/dim/blur as the lid comes down.
public struct FoldSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var activationAngle: Double
    public var style: FoldStyle
    public var perspective: Double
    public var blur: Double
    public var shade: Double
    public var jitterTolerance: Double
    /// Who renders the fold: JR-Bar's own overlay, or Bendy / Lid Plane.
    public var provider: FoldProvider

    public init(enabled: Bool = false, activationAngle: Double = 110, style: FoldStyle = .tilt,
                perspective: Double = 0.6, blur: Double = 0.5, shade: Double = 0.4,
                jitterTolerance: Double = 0, provider: FoldProvider = .jrbar) {
        self.enabled = enabled
        self.activationAngle = activationAngle
        self.style = style
        self.perspective = perspective
        self.blur = blur
        self.shade = shade
        self.jitterTolerance = jitterTolerance
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, activationAngle, style, perspective, blur, shade, jitterTolerance, provider
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        activationAngle = (try? c.decodeIfPresent(Double.self, forKey: .activationAngle)) ?? 110
        style = (try? c.decodeIfPresent(FoldStyle.self, forKey: .style)) ?? .tilt
        perspective = (try? c.decodeIfPresent(Double.self, forKey: .perspective)) ?? 0.6
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0.5
        shade = (try? c.decodeIfPresent(Double.self, forKey: .shade)) ?? 0.4
        jitterTolerance = (try? c.decodeIfPresent(Double.self, forKey: .jitterTolerance)) ?? 0
        provider = (try? c.decodeIfPresent(FoldProvider.self, forKey: .provider)) ?? .jrbar
    }
}

/// Perspective only / + darken / + blur.
public enum FoldStyle: String, Codable, CaseIterable, Sendable {
    case tilt, dusk, fog
}

/// Who renders the fold.
public enum FoldProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, bendy, lidPlane
}

/// Aquarium: every live session is a fish.
public struct AquariumSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var showLabels: Bool
    /// How much plankton/bubbles the tank draws.
    public var density: Double

    public init(enabled: Bool = false, showLabels: Bool = true, density: Double = 1.0) {
        self.enabled = enabled
        self.showLabels = showLabels
        self.density = density
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, showLabels, density
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        showLabels = (try? c.decodeIfPresent(Bool.self, forKey: .showLabels)) ?? true
        density = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? 1.0
    }
}

/// Notch Buddy: the creature in the HUD panel. `character` names which
/// one is drawn; "dot" is the only one so far and the enum is left open.
public struct NotchBuddySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var character: String

    public init(enabled: Bool = false, character: String = "dot") {
        self.enabled = enabled
        self.character = character
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, character
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        character = (try? c.decodeIfPresent(String.self, forKey: .character)) ?? "dot"
    }
}

/// Confetti: the weekly-quota-reset burst. The `onCompletion`/`onMilestone`
/// fields an earlier contract carried are gone — unknown keys are ignored.
public struct ConfettiSettings: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
    }
}

/// One app on the Toys page's external list. Identity is the bundle id:
/// the name is remembered so a row that is no longer installed can still
/// say what it was and offer Remove.
public struct ExternalToyApp: Codable, Equatable, Sendable, Identifiable {
    /// The bundle id.
    public var id: String
    public var name: String
    /// JR-Bar opens it at its own launch when it is not already running.
    public var launchWithJRBar: Bool

    public init(id: String, name: String, launchWithJRBar: Bool = false) {
        self.id = id
        self.name = name
        self.launchWithJRBar = launchWithJRBar
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, launchWithJRBar
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        launchWithJRBar = (try? c.decodeIfPresent(Bool.self, forKey: .launchWithJRBar)) ?? false
    }
}
