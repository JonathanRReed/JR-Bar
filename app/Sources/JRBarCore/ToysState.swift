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

/// Fold: the desktop tilts, dims and blurs as the lid comes down. The
/// shipped defaults — 82°, Dusk — are the ones that read as the
/// hold-the-angle illusion rather than a warp: late enough that normal
/// typing angles never reach it, dim enough that the fold reads as
/// shadow before it reads as distortion.
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

    public init(enabled: Bool = false, activationAngle: Double = 82, style: FoldStyle = .dusk,
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
        activationAngle = (try? c.decodeIfPresent(Double.self, forKey: .activationAngle)) ?? 82
        style = (try? c.decodeIfPresent(FoldStyle.self, forKey: .style)) ?? .dusk
        perspective = (try? c.decodeIfPresent(Double.self, forKey: .perspective)) ?? 0.6
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0.5
        shade = (try? c.decodeIfPresent(Double.self, forKey: .shade)) ?? 0.4
        jitterTolerance = (try? c.decodeIfPresent(Double.self, forKey: .jitterTolerance)) ?? 0
        provider = (try? c.decodeIfPresent(FoldProvider.self, forKey: .provider)) ?? .jrbar
        // The pre-0.9.6 defaults (110°/Tilt) proved over-eager: a file
        // still carrying exactly the old default set is treated as
        // untouched and moved to the new ones. Any deliberate change —
        // including to a sibling field — means the angle survives.
        if activationAngle == 110, style == .tilt, perspective == 0.6,
           blur == 0.5, shade == 0.4, jitterTolerance == 0 {
            activationAngle = 82
            style = .dusk
        }
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

/// Notch Buddy: the creature in the HUD panel. `character` is the
/// `BuddyCharacter` raw value, stored as a plain string so a file from a
/// newer build keeps its choice; anything unrecognised reads as `.dot`.
public struct NotchBuddySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var character: String

    public init(enabled: Bool = false, character: String = "dot") {
        self.enabled = enabled
        self.character = character
    }

    /// The stored name as a `BuddyCharacter`; unknown strings (a newer
    /// build's roster, a hand edit) fall back to `.dot` while the raw
    /// value stays in the file.
    public var resolvedCharacter: BuddyCharacter {
        BuddyCharacter(rawValue: character) ?? .dot
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

/// The Notch Buddy roster. All six share one skeleton — the same pose,
/// blink and effects — and differ only in how the body is drawn. The
/// raw value is what `NotchBuddySettings.character` stores.
public enum BuddyCharacter: String, Codable, CaseIterable, Sendable {
    /// The original soft blob.
    case dot
    /// Ears, whiskers and a tail with opinions.
    case cat
    /// A translucent hoverer with a wavy hem.
    case ghost
    /// A little machine: visor, LED mouth, an antenna that glows.
    case robot
    /// All eyes: they track the "!", tufts and wings that lift.
    case owl
    /// A gooey drop: jiggles, melts in the slump, sheds a droplet.
    case slime

    /// The picker's label.
    public var displayName: String {
        switch self {
        case .dot: return "Dot"
        case .cat: return "Cat"
        case .ghost: return "Ghost"
        case .robot: return "Robot"
        case .owl: return "Owl"
        case .slime: return "Slime"
        }
    }

    /// One line for the preview cell's tooltip.
    public var blurb: String {
        switch self {
        case .dot: return "The original blob."
        case .cat: return "Ears, whiskers & a tail with opinions."
        case .ghost: return "Floats. Mostly harmless."
        case .robot: return "Antenna up, LEDs on."
        case .owl: return "Sees everything. Especially asks."
        case .slime: return "Mostly holds its shape."
        }
    }
}

/// Confetti: the weekly-quota-reset burst. The `onCompletion`/`onMilestone`
/// fields an earlier contract carried are gone — unknown keys are ignored.
/// Every setting's default is the shipped look, so a file from before
/// they existed decodes to today's burst.
public struct ConfettiSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Where the pieces end up.
    public var landing: ConfettiLanding
    /// Piece-count multiplier, 0.5…2.
    public var density: Double
    /// Burst-length multiplier, 0.7…1.5 — stretches the whole timeline.
    public var duration: Double
    /// Whose colours the burst wears.
    public var palette: ConfettiPalette
    /// What the pieces are.
    public var shapes: ConfettiShapes

    public init(enabled: Bool = false, landing: ConfettiLanding = .rest, density: Double = 1.0,
                duration: Double = 1.0, palette: ConfettiPalette = .provider,
                shapes: ConfettiShapes = .mixed) {
        self.enabled = enabled
        self.landing = landing
        self.density = density
        self.duration = duration
        self.palette = palette
        self.shapes = shapes
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, landing, density, duration, palette, shapes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        landing = (try? c.decodeIfPresent(ConfettiLanding.self, forKey: .landing)) ?? .rest
        density = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? 1.0
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 1.0
        palette = (try? c.decodeIfPresent(ConfettiPalette.self, forKey: .palette)) ?? .provider
        shapes = (try? c.decodeIfPresent(ConfettiShapes.self, forKey: .shapes)) ?? .mixed
    }
}

/// Where confetti ends up: resting as litter on the band floor, raining
/// to the bottom edge of the screen, or dissolving mid-air.
public enum ConfettiLanding: String, Codable, CaseIterable, Sendable {
    case rest, fall, fade
}

/// Whose colours the burst wears: the resetting provider's, the Toys
/// page tint, or a six-colour spectrum.
public enum ConfettiPalette: String, Codable, CaseIterable, Sendable {
    case provider, toys, rainbow
}

/// What the pieces are: the full mix, streamers only, or glyph flecks
/// only.
public enum ConfettiShapes: String, Codable, CaseIterable, Sendable {
    case mixed, streamers, flecks
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
