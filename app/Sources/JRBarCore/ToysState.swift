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
    public var alcove: AlcoveSettings
    /// Apps the user asked JR-Bar to sit next to, by bundle id.
    public var externalApps: [ExternalToyApp]

    public init(fold: FoldSettings = FoldSettings(), aquarium: AquariumSettings = AquariumSettings(),
                notchBuddy: NotchBuddySettings = NotchBuddySettings(), confetti: ConfettiSettings = ConfettiSettings(),
                alcove: AlcoveSettings = AlcoveSettings(), externalApps: [ExternalToyApp] = []) {
        self.fold = fold
        self.aquarium = aquarium
        self.notchBuddy = notchBuddy
        self.confetti = confetti
        self.alcove = alcove
        self.externalApps = externalApps
    }

    private enum CodingKeys: String, CodingKey {
        case fold, aquarium, notchBuddy, confetti, alcove, externalApps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fold = (try? c.decodeIfPresent(FoldSettings.self, forKey: .fold)) ?? FoldSettings()
        aquarium = (try? c.decodeIfPresent(AquariumSettings.self, forKey: .aquarium)) ?? AquariumSettings()
        notchBuddy = (try? c.decodeIfPresent(NotchBuddySettings.self, forKey: .notchBuddy)) ?? NotchBuddySettings()
        confetti = (try? c.decodeIfPresent(ConfettiSettings.self, forKey: .confetti)) ?? ConfettiSettings()
        alcove = (try? c.decodeIfPresent(AlcoveSettings.self, forKey: .alcove)) ?? AlcoveSettings()
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

/// A remembered point in screen coordinates (AppKit's bottom-left
/// origin, like `NSScreen.frame`). The floating buddy's panel centres
/// on it. A spot is only as good as both halves: a missing, mistyped or
/// non-finite one drops the whole thing, and the buddy docks.
public struct BuddySpot: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil
        let y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil
        guard let x, let y, x.isFinite, y.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .x, in: c,
                                                   debugDescription: "a spot needs two finite numbers")
        }
        self.x = x
        self.y = y
    }
}

/// Notch Buddy: the creature in the HUD panel. `character` is the
/// `BuddyCharacter` raw value, stored as a plain string so a file from a
/// newer build keeps its choice; anything unrecognised reads as `.dot`.
/// `buddyName` is what the user calls it — blank keeps the character's
/// own `defaultName`. `care` is the Tamagotchi-lite log: pets, treats
/// and eaten crumbs. `freePosition` is where a drag parked it on the
/// screen — nil keeps it docked under the notch — `tucked` hides it
/// until the next session event or a card re-enable, and `showCaption`
/// is the quiet "what it's doing" line under the floating pill. `scale`
/// is the floating buddy's size dial — the docked pill keeps its 18pt
/// self whatever this says; the notch slot is fixed.
public struct NotchBuddySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var character: String
    public var buddyName: String
    public var care: BuddyCare
    /// Where the free-floating buddy's panel centres; nil = docked.
    public var freePosition: BuddySpot?
    /// Hidden until the next session event or a re-enable from the card.
    public var tucked: Bool
    /// The caption under the floating buddy.
    public var showCaption: Bool
    /// The floating pet's size multiplier, stored clamped into
    /// `scaleRange` so a hand edit can't grow a screen-filling (or
    /// invisible) buddy.
    public var scale: Double

    /// The size slider's reach — 1× is the docked size, 3× is desk-pet.
    public static let scaleRange: ClosedRange<Double> = 1.0...3.0

    /// Scale only means something inside `scaleRange`; a non-finite
    /// value reads as the default.
    public static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
    }

    public init(enabled: Bool = false, character: String = "dot",
                buddyName: String = "", care: BuddyCare = BuddyCare(),
                freePosition: BuddySpot? = nil, tucked: Bool = false,
                showCaption: Bool = true, scale: Double = 1.0) {
        self.enabled = enabled
        self.character = character
        self.buddyName = buddyName
        self.care = care
        self.freePosition = freePosition
        self.tucked = tucked
        self.showCaption = showCaption
        self.scale = Self.clampedScale(scale)
    }

    /// The stored name as a `BuddyCharacter`; unknown strings (a newer
    /// build's roster, a hand edit) fall back to `.dot` while the raw
    /// value stays in the file.
    public var resolvedCharacter: BuddyCharacter {
        BuddyCharacter(rawValue: character) ?? .dot
    }

    /// Who the status line names: the stored name, or the character's
    /// own when the field is blank or all spaces.
    public var resolvedName: String {
        let trimmed = buddyName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? resolvedCharacter.defaultName : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, character, buddyName, care, freePosition, tucked, showCaption, scale
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        character = (try? c.decodeIfPresent(String.self, forKey: .character)) ?? "dot"
        buddyName = (try? c.decodeIfPresent(String.self, forKey: .buddyName)) ?? ""
        care = (try? c.decodeIfPresent(BuddyCare.self, forKey: .care)) ?? BuddyCare()
        // A spot that fails its own decode (a missing or mistyped half)
        // reads as docked rather than stranding the pill off-screen.
        freePosition = (try? c.decodeIfPresent(BuddySpot.self, forKey: .freePosition)) ?? nil
        tucked = (try? c.decodeIfPresent(Bool.self, forKey: .tucked)) ?? false
        showCaption = (try? c.decodeIfPresent(Bool.self, forKey: .showCaption)) ?? true
        // Missing or mistyped is 1×; a number outside the dial clamps.
        scale = Self.clampedScale((try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? 1.0)
    }
}

/// The buddy's Tamagotchi-lite memory: pets, treats and the crumbs it
/// gets for completed sessions. It is a log, not a simulation — the only
/// read is `mood(at:)`, which decays attention: a treat reads as `fed`
/// for `fedWindow`, and once it has been petted at all it starts
/// `missing` you after `lonelyAfter`. All zeros is a buddy nobody has
/// met — it stays `content`, because it cannot miss what it never had.
public struct BuddyCare: Codable, Equatable, Sendable {
    /// Epoch seconds of the last pet or treat; 0 = never touched.
    public var lastInteractionAt: Double
    /// Epoch seconds of the last treat; 0 = never fed.
    public var lastTreatAt: Double
    /// Epoch seconds of the last crumb; 0 = never ate.
    public var lastCrumbAt: Double
    /// Lifetime pets — taps on the buddy and treats both count.
    public var petCount: Int
    /// Treats served from the card.
    public var treatsGiven: Int
    /// Completed sessions it has "eaten".
    public var crumbsEaten: Int

    public init(lastInteractionAt: Double = 0, lastTreatAt: Double = 0, lastCrumbAt: Double = 0,
                petCount: Int = 0, treatsGiven: Int = 0, crumbsEaten: Int = 0) {
        self.lastInteractionAt = lastInteractionAt
        self.lastTreatAt = lastTreatAt
        self.lastCrumbAt = lastCrumbAt
        self.petCount = petCount
        self.treatsGiven = treatsGiven
        self.crumbsEaten = crumbsEaten
    }

    /// How long a treat keeps it blissed out.
    public static let fedWindow: TimeInterval = 20 * 60
    /// The quiet that turns into missing you.
    public static let lonelyAfter: TimeInterval = 24 * 60 * 60

    /// What the care log adds up to. `fed` is checked first — a treat
    /// also freshens `lastInteractionAt`, so a fed buddy can never be
    /// missing you anyway; the order just makes that obvious.
    public enum Mood: String, Codable, Sendable, CaseIterable {
        /// Nothing owed either way.
        case content
        /// Inside `fedWindow` after a treat.
        case fed
        /// Petted before, untouched for `lonelyAfter`.
        case missing
    }

    public func mood(at now: Date = Date()) -> Mood {
        let t = now.timeIntervalSince1970
        if lastTreatAt > 0, t - lastTreatAt < Self.fedWindow { return .fed }
        if lastInteractionAt > 0, t - lastInteractionAt > Self.lonelyAfter { return .missing }
        return .content
    }

    /// A tap on the buddy or a scratch behind the ear.
    public mutating func pet(at now: Date = Date()) {
        petCount += 1
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// A treat counts as a pet and starts the `fed` window.
    public mutating func feed(at now: Date = Date()) {
        pet(at: now)
        treatsGiven += 1
        lastTreatAt = now.timeIntervalSince1970
    }

    /// A completed session is a crumb. Eating is ambient, not affection
    /// — it deliberately does not touch `lastInteractionAt`, so a buddy
    /// whose human never says hi still misses them.
    public mutating func eat(at now: Date = Date(), count: Int = 1) {
        crumbsEaten += count
        lastCrumbAt = now.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case lastInteractionAt, lastTreatAt, lastCrumbAt, petCount, treatsGiven, crumbsEaten
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastInteractionAt = (try? c.decodeIfPresent(Double.self, forKey: .lastInteractionAt)) ?? 0
        lastTreatAt = (try? c.decodeIfPresent(Double.self, forKey: .lastTreatAt)) ?? 0
        lastCrumbAt = (try? c.decodeIfPresent(Double.self, forKey: .lastCrumbAt)) ?? 0
        petCount = (try? c.decodeIfPresent(Int.self, forKey: .petCount)) ?? 0
        treatsGiven = (try? c.decodeIfPresent(Int.self, forKey: .treatsGiven)) ?? 0
        crumbsEaten = (try? c.decodeIfPresent(Int.self, forKey: .crumbsEaten)) ?? 0
    }
}

/// The Notch Buddy roster. All ten share one skeleton — the same pose,
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
    /// A frilly-gilled smiler that never grew up.
    case axolotl
    /// Eyes on stalks, pincers that clap for asks.
    case crab
    /// A spotted cap on a pale stalk, permanently drowsy.
    case mushroom
    /// A saucer that never lands: glass dome, small pilot, a beam.
    case ufo

    /// The picker's label.
    public var displayName: String {
        switch self {
        case .dot: return "Dot"
        case .cat: return "Cat"
        case .ghost: return "Ghost"
        case .robot: return "Robot"
        case .owl: return "Owl"
        case .slime: return "Slime"
        case .axolotl: return "Axolotl"
        case .crab: return "Crab"
        case .mushroom: return "Mushroom"
        case .ufo: return "UFO"
        }
    }

    /// What it answers to when the user has not picked a name.
    public var defaultName: String {
        switch self {
        case .dot: return "Dot"
        case .cat: return "Pixel"
        case .ghost: return "Boo"
        case .robot: return "Clank"
        case .owl: return "Hoot"
        case .slime: return "Gloop"
        case .axolotl: return "Axel"
        case .crab: return "Pinch"
        case .mushroom: return "Morel"
        case .ufo: return "Orbit"
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
        case .axolotl: return "Frills out. Still smiling."
        case .crab: return "Claws up. Walks sideways."
        case .mushroom: return "Half asleep under its cap."
        case .ufo: return "Hovering. Probably harmless."
        }
    }
}

/// Confetti: the celebratory burst. The `onCompletion`/`onMilestone`
/// fields an earlier contract carried are gone — unknown keys are ignored.
/// Every setting's default is the shipped look, so a file from before
/// they existed decodes to today's burst — and `ConfettiTriggers`' are
/// the behaviour it has always had, so the file's owner sees nothing new
/// until they opt in.
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
    /// Which facts may fire the burst.
    public var triggers: ConfettiTriggers
    /// The dedup ring: keys of recent fires, so a repeated event id or a
    /// re-folded state can never burst twice. Bookkeeping the toy
    /// maintains, not a control.
    public var firedKeys: [String]

    /// The ring's depth: an old key falls off long after the fact it
    /// guarded is history.
    public static let firedKeyLimit = 64

    public init(enabled: Bool = false, landing: ConfettiLanding = .rest, density: Double = 1.0,
                duration: Double = 1.0, palette: ConfettiPalette = .provider,
                shapes: ConfettiShapes = .mixed, triggers: ConfettiTriggers = ConfettiTriggers(),
                firedKeys: [String] = []) {
        self.enabled = enabled
        self.landing = landing
        self.density = density
        self.duration = duration
        self.palette = palette
        self.shapes = shapes
        self.triggers = triggers
        self.firedKeys = firedKeys
    }

    /// Record one fire's dedup key, oldest out past the limit.
    public mutating func noteFired(_ key: String) {
        guard !key.isEmpty else { return }
        firedKeys.append(key)
        if firedKeys.count > Self.firedKeyLimit {
            firedKeys.removeFirst(firedKeys.count - Self.firedKeyLimit)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, landing, density, duration, palette, shapes, triggers, firedKeys
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        landing = (try? c.decodeIfPresent(ConfettiLanding.self, forKey: .landing)) ?? .rest
        density = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? 1.0
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 1.0
        palette = (try? c.decodeIfPresent(ConfettiPalette.self, forKey: .palette)) ?? .provider
        shapes = (try? c.decodeIfPresent(ConfettiShapes.self, forKey: .shapes)) ?? .mixed
        triggers = (try? c.decodeIfPresent(ConfettiTriggers.self, forKey: .triggers)) ?? ConfettiTriggers()
        let keys = (try? c.decodeIfPresent([String].self, forKey: .firedKeys)) ?? []
        firedKeys = Array(keys.filter { !$0.isEmpty }.suffix(Self.firedKeyLimit))
    }
}

/// What may fire the burst. The defaults are exactly what the toy has
/// always done — a weekly refill and nothing else — so a file from
/// before these keys decodes to the same behaviour and every new
/// trigger is opt-in.
public struct ConfettiTriggers: Codable, Equatable, Sendable {
    /// An agent finished a run (`completed` events).
    public var sessionCompleted: Bool
    /// Any provider's weekly quota window refilled (`quota_reset` on a
    /// `weekly` / `*-weekly` lane).
    public var weeklyReset: Bool
    /// Providers whose EVERY lane reset fires it — the five-hour window
    /// and product-scoped lanes included, not only the weekly one.
    public var perProviderReset: Set<String>
    /// Codex's banked-credit balance (`credits_remaining`) grew.
    public var codexBankedReset: Bool
    /// The last open ask resolved — nothing left waiting on you.
    public var allClear: Bool

    public init(sessionCompleted: Bool = false, weeklyReset: Bool = true,
                perProviderReset: Set<String> = [], codexBankedReset: Bool = false,
                allClear: Bool = false) {
        self.sessionCompleted = sessionCompleted
        self.weeklyReset = weeklyReset
        self.perProviderReset = perProviderReset
        self.codexBankedReset = codexBankedReset
        self.allClear = allClear
    }

    private enum CodingKeys: String, CodingKey {
        case sessionCompleted, weeklyReset, perProviderReset, codexBankedReset, allClear
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .sessionCompleted)) ?? false
        weeklyReset = (try? c.decodeIfPresent(Bool.self, forKey: .weeklyReset)) ?? true
        perProviderReset = Set(((try? c.decodeIfPresent(Set<String>.self, forKey: .perProviderReset)) ?? [])
            .map { $0.lowercased() })
        codexBankedReset = (try? c.decodeIfPresent(Bool.self, forKey: .codexBankedReset)) ?? false
        allClear = (try? c.decodeIfPresent(Bool.self, forKey: .allClear)) ?? false
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

/// Alcove: the notch island — a capsule hugging the notch that shows who
/// is working and grows into a session card on hover. `provider` picks
/// who draws it, Fold-style: JR-Bar's own island, or the capsule owned
/// by Alcove / boring.notch, which JR-Bar then leaves alone. The other
/// fields are our island's knobs and mean nothing while an external app
/// owns the notch.
public struct AlcoveSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Who renders the island.
    public var provider: AlcoveProvider
    /// The capsule itself. Off parks the island without touching the
    /// provider pick.
    public var islandEnabled: Bool
    /// Per-provider quota meters in the expanded card.
    public var showUsage: Bool
    /// Hover grows the capsule into the card.
    public var expandOnHover: Bool
    /// Daemon events briefly morph the island into a notification
    /// capsule (asks, finishes, failures, quota resets).
    public var capsuleNotifications: Bool
    /// Now Playing in the idle capsule and the card's transport row.
    public var mediaEnabled: Bool
    /// Which event kinds may raise a capsule.
    public var capsuleKinds: AlcoveCapsuleKinds

    public init(enabled: Bool = false, provider: AlcoveProvider = .jrbar,
                islandEnabled: Bool = true, showUsage: Bool = true,
                expandOnHover: Bool = true, capsuleNotifications: Bool = true,
                mediaEnabled: Bool = true, capsuleKinds: AlcoveCapsuleKinds = AlcoveCapsuleKinds()) {
        self.enabled = enabled
        self.provider = provider
        self.islandEnabled = islandEnabled
        self.showUsage = showUsage
        self.expandOnHover = expandOnHover
        self.capsuleNotifications = capsuleNotifications
        self.mediaEnabled = mediaEnabled
        self.capsuleKinds = capsuleKinds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, islandEnabled, showUsage, expandOnHover
        case capsuleNotifications, mediaEnabled, capsuleKinds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        provider = (try? c.decodeIfPresent(AlcoveProvider.self, forKey: .provider)) ?? .jrbar
        islandEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .islandEnabled)) ?? true
        showUsage = (try? c.decodeIfPresent(Bool.self, forKey: .showUsage)) ?? true
        expandOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .expandOnHover)) ?? true
        capsuleNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .capsuleNotifications)) ?? true
        mediaEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .mediaEnabled)) ?? true
        capsuleKinds = (try? c.decodeIfPresent(AlcoveCapsuleKinds.self, forKey: .capsuleKinds)) ?? AlcoveCapsuleKinds()
    }
}

/// Who renders the island: ours, Henrik's Alcove, or boring.notch.
public enum AlcoveProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, alcove, boringNotch
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
