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
    public var notch: NotchSettings

    public init(fold: FoldSettings = FoldSettings(), aquarium: AquariumSettings = AquariumSettings(),
                notchBuddy: NotchBuddySettings = NotchBuddySettings(), confetti: ConfettiSettings = ConfettiSettings(),
                notch: NotchSettings = NotchSettings()) {
        self.fold = fold
        self.aquarium = aquarium
        self.notchBuddy = notchBuddy
        self.confetti = confetti
        self.notch = notch
    }

    private enum CodingKeys: String, CodingKey {
        case fold, aquarium, notchBuddy, confetti, notch
        /// The island toy shipped as `alcove`; the key is read but never
        /// written — a saved file always lands under `notch`.
        case legacyAlcove = "alcove"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fold = (try? c.decodeIfPresent(FoldSettings.self, forKey: .fold)) ?? FoldSettings()
        aquarium = (try? c.decodeIfPresent(AquariumSettings.self, forKey: .aquarium)) ?? AquariumSettings()
        notchBuddy = (try? c.decodeIfPresent(NotchBuddySettings.self, forKey: .notchBuddy)) ?? NotchBuddySettings()
        confetti = (try? c.decodeIfPresent(ConfettiSettings.self, forKey: .confetti)) ?? ConfettiSettings()
        notch = (try? c.decodeIfPresent(NotchSettings.self, forKey: .notch))
            ?? (try? c.decodeIfPresent(NotchSettings.self, forKey: .legacyAlcove))
            ?? NotchSettings()
        // `externalApps` was the Toys page's app list — the feature is
        // gone; an old file's key is now just an ignored unknown key.
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fold, forKey: .fold)
        try c.encode(aquarium, forKey: .aquarium)
        try c.encode(notchBuddy, forKey: .notchBuddy)
        try c.encode(confetti, forKey: .confetti)
        try c.encode(notch, forKey: .notch)
    }
}

/// Fold: the desktop folds into the screen as the lid comes down — one
/// style now, the portal room seen through a frosted-PP cover, with
/// Perspective/Blur/Shade/Frost as the knobs. The shipped defaults —
/// 65°, shade 0.7, frost 0 — are the ones that read as the
/// hold-the-angle illusion rather than a warp: early enough that the
/// fold starts while the lid is still visibly moving, dim enough that
/// the fold reads as shadow before it reads as distortion, and a black
/// room behind it — the frost knob lifts the void to a grey milk, and
/// at 0.65 the whole fold read as "super grey instead of black".
public struct FoldSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Where a fold measures its travel from — the fixed
    /// `activationAngle`, or wherever the lid was resting when it
    /// started to move.
    public var anchor: FoldAnchor
    public var activationAngle: Double
    public var perspective: Double
    public var blur: Double
    public var shade: Double
    public var jitterTolerance: Double
    /// Who renders the fold: JR-Bar's own overlay, or Bendy / Lid Plane.
    public var provider: FoldProvider
    /// How milky the cover is: 0 is the bare dark portal room, 1 a
    /// fully frosted-polypropylene sheet over the room.
    public var frost: Double
    /// Bendy's hold-in-place: the content plane counter-rotates against
    /// the lid so a fixed eye sees the desktop stay put while the glass
    /// tilts over it. Off keeps the picture glued to the lid.
    public var holdPicture: Bool
    /// Mac Duo's pause-at-angle: a lid parked mid-fold hands the
    /// desktop back after this many seconds until the hinge moves
    /// again. 0 keeps the fold however long the lid sits.
    public var dwellTimeout: Double
    /// Bendy's return click — a Tink when the fold fully unwinds.
    public var restoreSound: Bool

    public init(enabled: Bool = false, anchor: FoldAnchor = .angle,
                activationAngle: Double = 65,
                perspective: Double = 0.6, blur: Double = 0.5, shade: Double = 0.7,
                jitterTolerance: Double = 1.5, provider: FoldProvider = .jrbar,
                frost: Double = 0, holdPicture: Bool = true, dwellTimeout: Double = 0,
                restoreSound: Bool = false) {
        self.enabled = enabled
        self.anchor = anchor
        self.activationAngle = activationAngle
        self.perspective = perspective
        self.blur = blur
        self.shade = shade
        self.jitterTolerance = jitterTolerance
        self.provider = provider
        self.frost = frost
        self.holdPicture = holdPicture
        self.dwellTimeout = dwellTimeout
        self.restoreSound = restoreSound
    }

    private enum CodingKeys: String, CodingKey {
        // `style` is the retired Tilt/Dusk/Fog picker — decoded only so
        // a file parked on an old default set still migrates; nothing
        // reads it now and a stale value like "fog" decodes fine.
        case enabled, anchor, activationAngle, style, perspective, blur, shade, jitterTolerance
        case provider, frost, holdPicture, dwellTimeout, restoreSound
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        anchor = (try? c.decodeIfPresent(FoldAnchor.self, forKey: .anchor)) ?? .angle
        activationAngle = (try? c.decodeIfPresent(Double.self, forKey: .activationAngle)) ?? 65
        let style = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? "fog"
        perspective = (try? c.decodeIfPresent(Double.self, forKey: .perspective)) ?? 0.6
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0.5
        shade = (try? c.decodeIfPresent(Double.self, forKey: .shade)) ?? 0.7
        // The hinge sensor wobbles ±1° while the lid sits still; with no
        // deadband that noise feeds the tracker forever and the vsync
        // link never stands down — a parked fold was a 60 fps timer.
        // 1.5 clears integer-sensor jitter while every real swing (a
        // move of 2°+ from the anchor) still streams through.
        // `storedJitter` keeps the raw file value for the legacy-default
        // checks below: a file that never wrote the key (or wrote the
        // old 0 default) still counts as untouched.
        let storedJitter = try? c.decodeIfPresent(Double.self, forKey: .jitterTolerance)
        jitterTolerance = storedJitter ?? 1.5
        let jitterUntouched = storedJitter == nil || storedJitter == 0
        provider = (try? c.decodeIfPresent(FoldProvider.self, forKey: .provider)) ?? .jrbar
        frost = (try? c.decodeIfPresent(Double.self, forKey: .frost)) ?? 0
        holdPicture = (try? c.decodeIfPresent(Bool.self, forKey: .holdPicture)) ?? true
        dwellTimeout = (try? c.decodeIfPresent(Double.self, forKey: .dwellTimeout)) ?? 0
        restoreSound = (try? c.decodeIfPresent(Bool.self, forKey: .restoreSound)) ?? false
        // Each past default set is treated as untouched and moved to the
        // current one; any deliberate change means the file survives.
        // A file old enough to migrate never wrote `frost`, so the knob
        // reads its default there — a moved frost is a deliberate change.
        if activationAngle == 110, style == "tilt", perspective == 0.6,
           blur == 0.5, shade == 0.4, jitterUntouched, frost == 0 {
            activationAngle = 65
            shade = 0.7
            jitterTolerance = 1.5
        } else if activationAngle == 82, style == "dusk", perspective == 0.6,
                  blur == 0.5, shade == 0.4, jitterUntouched, frost == 0 {
            activationAngle = 65
            shade = 0.7
            jitterTolerance = 1.5
        }
        // The 0.65 milk shipped as a default for one build; a file that
        // still carries exactly that value never chose it.
        if frost == 0.65 { frost = 0 }
    }

    /// `style` is decode-only — a saved file never writes the retired key,
    /// so the encoder lists real properties alone.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(activationAngle, forKey: .activationAngle)
        try c.encode(perspective, forKey: .perspective)
        try c.encode(blur, forKey: .blur)
        try c.encode(shade, forKey: .shade)
        try c.encode(jitterTolerance, forKey: .jitterTolerance)
        try c.encode(provider, forKey: .provider)
        try c.encode(frost, forKey: .frost)
        try c.encode(holdPicture, forKey: .holdPicture)
        try c.encode(dwellTimeout, forKey: .dwellTimeout)
        try c.encode(restoreSound, forKey: .restoreSound)
    }
}

/// Who renders the fold.
public enum FoldProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, bendy, lidPlane
}

/// Where a fold measures its travel from (docs/TOYS.md §Fold):
/// `.angle` holds a fixed activation angle; `.movement` auto-anchors —
/// wherever the lid has been resting is where the fold starts from.
public enum FoldAnchor: String, Codable, CaseIterable, Sendable {
    case angle, movement
}

/// How the tank's day/night wash picks its clock (docs/TOYS.md):
/// the real clock out the window, or a self-contained four-minute
/// cycle for a tank that always breathes.
public enum DayNightMode: String, Codable, CaseIterable, Sendable {
    /// 21:00–06:00 reads as night; the edges blend as dawn & dusk.
    case realTime
    /// The classic behaviour: a slow four-minute breathe.
    case cycle
}

/// Aquarium: every live session is a fish.
public struct AquariumSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var showLabels: Bool
    /// How much plankton/bubbles the tank draws.
    public var density: Double
    /// Provider id → `FishSpecies` raw value — the tank's per-provider
    /// casting, set from a fish's inspector. A missing or unknown entry
    /// falls back to the provider's table species.
    public var speciesOverrides: [String: String]
    /// Where the day/night wash takes its clock from.
    public var dayNight: DayNightMode

    public init(enabled: Bool = false, showLabels: Bool = true, density: Double = 1.0,
                speciesOverrides: [String: String] = [:],
                dayNight: DayNightMode = .realTime) {
        self.enabled = enabled
        self.showLabels = showLabels
        self.density = density
        self.speciesOverrides = speciesOverrides
        self.dayNight = dayNight
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, showLabels, density, speciesOverrides, dayNight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        showLabels = (try? c.decodeIfPresent(Bool.self, forKey: .showLabels)) ?? true
        density = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? 1.0
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .speciesOverrides)) ?? [:]
        speciesOverrides = raw.filter { FishSpecies(rawValue: $0.value) != nil }
        let dayNightRaw = (try? c.decodeIfPresent(String.self, forKey: .dayNight)) ?? nil
        dayNight = dayNightRaw.flatMap(DayNightMode.init(rawValue:)) ?? .realTime
    }

    /// What `provider` swims as: the user's pick when one is stored,
    /// else the table species.
    public func species(for provider: String) -> FishSpecies {
        if let raw = speciesOverrides[provider.lowercased()],
           let species = FishSpecies(rawValue: raw) { return species }
        return FishSpecies.forProvider(provider)
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
    /// `character` draws the picked creature; `mini` is the same
    /// controller — same summary, tap and menu — wearing a small status
    /// pill instead of a body. Stored raw so a newer build's mode keeps.
    public var presentation: String
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
                presentation: String = "character",
                buddyName: String = "", care: BuddyCare = BuddyCare(),
                freePosition: BuddySpot? = nil, tucked: Bool = false,
                showCaption: Bool = true, scale: Double = 1.0) {
        self.enabled = enabled
        self.character = character
        self.presentation = presentation
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

    /// Mini reads as "no body": anything but the stored `mini` word —
    /// including a hand edit's noise — presents the character.
    public var miniMode: Bool { presentation == "mini" }

    /// Who the status line names: the stored name, or the character's
    /// own when the field is blank or all spaces.
    public var resolvedName: String {
        let trimmed = buddyName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? resolvedCharacter.defaultName : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, character, presentation, buddyName, care, freePosition, tucked, showCaption, scale
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        character = (try? c.decodeIfPresent(String.self, forKey: .character)) ?? "dot"
        presentation = (try? c.decodeIfPresent(String.self, forKey: .presentation)) ?? "character"
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

/// Notch: the island — a capsule hugging the notch that shows who is
/// working and drops the shared card on hover. `provider` picks who
/// draws it, Fold-style: JR-Bar's own island, or the capsule owned by
/// Alcove / boring.notch, which JR-Bar then leaves alone. The other
/// fields are our island's knobs and mean nothing while an external app
/// owns the notch.
public struct NotchSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Who renders the island.
    public var provider: NotchProvider
    /// The capsule itself. Off parks the island without touching the
    /// provider pick.
    public var islandEnabled: Bool
    /// Per-provider quota meters in the card.
    public var showUsage: Bool
    /// Hover drops the card under the island.
    public var expandOnHover: Bool
    /// Daemon events briefly morph the island into a notification
    /// capsule (asks, finishes, failures, quota resets).
    public var capsuleNotifications: Bool
    /// Now Playing in the idle capsule and the card's transport row.
    public var mediaEnabled: Bool
    /// Which event kinds may raise a capsule.
    public var capsuleKinds: AlcoveCapsuleKinds
    /// The island's touch gestures: press-and-pull grows or folds it,
    /// a two-finger swipe down puts it away. Off leaves click and
    /// hover — the gestures default on, the native behaviour.
    public var pullGestures: Bool
    /// A soft trackpad tap as the island grows into the card —
    /// Alcove's felt edge. No-op on Macs without haptic hardware.
    public var hapticTick: Bool
    /// Volume and brightness key presses hang a level capsule under the
    /// notch — the HUD Alcove is known for. The key still does its job;
    /// we only draw it.
    public var mediaHUD: Bool
    /// System announcements in the pill: a Focus mode turning on or a
    /// Bluetooth device connecting.
    public var alerts: Bool
    /// A quiet tick when a capsule shows — Alcove's felt edge for the
    /// HUD.
    public var soundEffects: Bool
    /// The card's weather row — a keyless Open-Meteo read of the
    /// place `weatherCity` names, or the IP's coarse fix when empty.
    /// Off by default: it phones a third-party API, so the person
    /// turns it on.
    public var weather: Bool
    /// A city name to geocode ("London"); empty uses the IP's place.
    public var weatherCity: String
    /// On a screen with no hardware notch, draw a synthetic housing —
    /// the island reads as a notch rather than a floating pill, like
    /// Alcove's notch-on-any-display option. Off is the honest pill.
    public var simulateNotch: Bool
    /// The card's mirror row — a live camera preview, boring.notch's
    /// Mirror. Off by default: the camera's consent is asked only when
    /// the person turns the row on, and the lens never opens before it.
    public var mirror: Bool
    /// Real audio-reactive visualizer in the media row: a Core Audio
    /// process tap over the now-playing app (or the global mixdown)
    /// feeds six band levels. Off by default — the first enable asks
    /// the system-audio permission once, and the decorative animation
    /// stays until that consent lands.
    public var audioVisualizer: Bool
    /// Swallow the volume/brightness media keys and drive the level
    /// ourselves so Apple's overlay never draws. Off by default — it
    /// needs the event tap's Accessibility grant, and keys without a
    /// public set path (keyboard backlight) pass through either way.
    public var replaceSystemHUD: Bool
    /// Shake the pointer while dragging files and the shelf pulls open
    /// under the notch as a drop target — Alcove's summon gesture.
    public var shelfShakeToSummon: Bool
    /// Seconds a level (volume, brightness, backlight) and a toast hold
    /// at the notch — MediaMate's HUD duration. A saved value outside
    /// `hudDurationRange` is clamped when the file is read.
    public var hudDuration: Double = 2.0
    public static let hudDurationRange: ClosedRange<Double> = 1...6

    public init(enabled: Bool = false, provider: NotchProvider = .jrbar,
                islandEnabled: Bool = true, showUsage: Bool = true,
                expandOnHover: Bool = true, capsuleNotifications: Bool = true,
                mediaEnabled: Bool = true, capsuleKinds: AlcoveCapsuleKinds = AlcoveCapsuleKinds(),
                pullGestures: Bool = true, hapticTick: Bool = true,
                mediaHUD: Bool = true, alerts: Bool = true,
                soundEffects: Bool = true, weather: Bool = false,
                weatherCity: String = "", simulateNotch: Bool = false,
                mirror: Bool = false, audioVisualizer: Bool = false,
                replaceSystemHUD: Bool = false,
                shelfShakeToSummon: Bool = true) {
        self.enabled = enabled
        self.provider = provider
        self.islandEnabled = islandEnabled
        self.showUsage = showUsage
        self.expandOnHover = expandOnHover
        self.capsuleNotifications = capsuleNotifications
        self.mediaEnabled = mediaEnabled
        self.capsuleKinds = capsuleKinds
        self.pullGestures = pullGestures
        self.hapticTick = hapticTick
        self.mediaHUD = mediaHUD
        self.alerts = alerts
        self.soundEffects = soundEffects
        self.weather = weather
        self.weatherCity = weatherCity
        self.simulateNotch = simulateNotch
        self.mirror = mirror
        self.audioVisualizer = audioVisualizer
        self.replaceSystemHUD = replaceSystemHUD
        self.shelfShakeToSummon = shelfShakeToSummon
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, islandEnabled, showUsage, expandOnHover
        case capsuleNotifications, mediaEnabled, capsuleKinds, pullGestures
        case hapticTick, mediaHUD, alerts, soundEffects, weather, weatherCity
        case simulateNotch, mirror, audioVisualizer, replaceSystemHUD
        case shelfShakeToSummon
        case hudDuration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        provider = (try? c.decodeIfPresent(NotchProvider.self, forKey: .provider)) ?? .jrbar
        islandEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .islandEnabled)) ?? true
        showUsage = (try? c.decodeIfPresent(Bool.self, forKey: .showUsage)) ?? true
        expandOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .expandOnHover)) ?? true
        capsuleNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .capsuleNotifications)) ?? true
        mediaEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .mediaEnabled)) ?? true
        capsuleKinds = (try? c.decodeIfPresent(AlcoveCapsuleKinds.self, forKey: .capsuleKinds)) ?? AlcoveCapsuleKinds()
        pullGestures = (try? c.decodeIfPresent(Bool.self, forKey: .pullGestures)) ?? true
        hapticTick = (try? c.decodeIfPresent(Bool.self, forKey: .hapticTick)) ?? true
        mediaHUD = (try? c.decodeIfPresent(Bool.self, forKey: .mediaHUD)) ?? true
        alerts = (try? c.decodeIfPresent(Bool.self, forKey: .alerts)) ?? true
        soundEffects = (try? c.decodeIfPresent(Bool.self, forKey: .soundEffects)) ?? true
        weather = (try? c.decodeIfPresent(Bool.self, forKey: .weather)) ?? false
        weatherCity = (try? c.decodeIfPresent(String.self, forKey: .weatherCity)) ?? ""
        simulateNotch = (try? c.decodeIfPresent(Bool.self, forKey: .simulateNotch)) ?? false
        mirror = (try? c.decodeIfPresent(Bool.self, forKey: .mirror)) ?? false
        audioVisualizer = (try? c.decodeIfPresent(Bool.self, forKey: .audioVisualizer)) ?? false
        replaceSystemHUD = (try? c.decodeIfPresent(Bool.self, forKey: .replaceSystemHUD)) ?? false
        shelfShakeToSummon = (try? c.decodeIfPresent(Bool.self, forKey: .shelfShakeToSummon)) ?? true
        let hud = (try? c.decodeIfPresent(Double.self, forKey: .hudDuration)) ?? 2.0
        hudDuration = min(Self.hudDurationRange.upperBound, max(Self.hudDurationRange.lowerBound, hud))
    }
}

/// Who renders the island: ours, Henrik's Alcove, or boring.notch.
public enum NotchProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, alcove, boringNotch
}


