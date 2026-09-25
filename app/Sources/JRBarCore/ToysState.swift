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
    /// "Quiet the toys during Focus, quiet hours and calls": while JR-Bar
    /// is quiet, a Focus is on or a call has the mic or camera, confetti
    /// holds its burst (and skips screens a fullscreen app owns), the
    /// buddy keeps its completion hop to itself, the tank holds its
    /// reward cards and the hinge stays silent. On by default — calm
    /// first.
    public var hushDuringQuiet: Bool = true

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
        case hushDuringQuiet
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
        hushDuringQuiet = (try? c.decodeIfPresent(Bool.self, forKey: .hushDuringQuiet)) ?? true
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
        try c.encode(hushDuringQuiet, forKey: .hushDuringQuiet)
    }
}

/// Fold: the desktop folds into the screen as the lid comes down. Two
/// looks: Duo (the default), the iPhone Duo's fold — one picture held
/// still in space while the glass swings through it, softening and
/// going dark away from the hinge — and Room, the older portal room
/// seen through a frosted cover. A new file folds from wherever the lid
/// rests, so the Duo reacts from the first degree; blur 0.6 and shade
/// 0.67 put the far edge a notch under the Duo's own softness and black
/// by half-closed. A file from before the looks moves to Duo and the
/// resting angle, keeping its own blur, shade and stored activation
/// angle (still used by "Set angle").
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
    /// How still the picture holds while the glass tilts over it, 0…1:
    /// 1 keeps the desktop where a seated eye saw it (the iPhone Duo's
    /// "stays put in space"), 0 glues it to the lid, and between drifts
    /// part way. Replaces the old `holdPicture` switch, which read true
    /// as "hold" but drove the picture toward the lid; a stored switch
    /// migrates by what its label meant (on → 1, off → 0).
    public var holdStrength: Double
    /// Mac Duo's pause-at-angle: a lid parked mid-fold hands the
    /// desktop back after this many seconds until the hinge moves
    /// again. 0 keeps the fold however long the lid sits.
    public var dwellTimeout: Double
    /// Bendy's return click — a Tink when the fold fully unwinds.
    public var restoreSound: Bool
    /// Without Screen Recording, fold the wallpaper alone (no window
    /// cards) instead of nothing. On by default: a first try should do
    /// something.
    public var wallpaperFallback: Bool = true
    /// The hinge voice: the lid's speed plays a creak or a softer paper
    /// rustle. Off by default.
    public var hingeVoice: HingeVoice = .off
    /// Which fold draws: the iPhone Duo's held picture, or the room.
    public var look: FoldLook = .duo
    /// Duo: how much of the close the picture takes to go soft and dark,
    /// as a share of the travel from where the fold starts down to the
    /// closed line. 0.55 is the Duo's own "done by half-closed".
    public var fadeLength: Double = 0.55
    /// The range the "Goes dark over" slider and the decoder keep
    /// `fadeLength` in: never a snap, never slower than the whole close.
    public static let fadeLengthRange: ClosedRange<Double> = 0.2...1

    public init(enabled: Bool = false, anchor: FoldAnchor = .movement,
                activationAngle: Double = 65,
                perspective: Double = 0.6, blur: Double = 0.6, shade: Double = 0.67,
                jitterTolerance: Double = 1.5, provider: FoldProvider = .jrbar,
                frost: Double = 0, holdStrength: Double = 1, dwellTimeout: Double = 0,
                restoreSound: Bool = false, look: FoldLook = .duo, fadeLength: Double = 0.55) {
        self.enabled = enabled
        self.anchor = anchor
        self.activationAngle = activationAngle
        self.perspective = perspective
        self.blur = blur
        self.shade = shade
        self.jitterTolerance = jitterTolerance
        self.provider = provider
        self.frost = frost
        self.holdStrength = holdStrength
        self.dwellTimeout = dwellTimeout
        self.restoreSound = restoreSound
        self.look = look
        self.fadeLength = fadeLength
    }

    private enum CodingKeys: String, CodingKey {
        // `style` is the retired Tilt/Dusk/Fog picker — decoded only so
        // a file parked on an old default set still migrates; nothing
        // reads it now and a stale value like "fog" decodes fine.
        case enabled, anchor, activationAngle, style, perspective, blur, shade, jitterTolerance
        case provider, frost, holdPicture, dwellTimeout, restoreSound
        case wallpaperFallback, hingeVoice
        // `holdPicture` above is decode-only now: the retired switch,
        // read once to seed `holdStrength`.
        case holdStrength
        case look, fadeLength
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        anchor = (try? c.decodeIfPresent(FoldAnchor.self, forKey: .anchor)) ?? .movement
        activationAngle = (try? c.decodeIfPresent(Double.self, forKey: .activationAngle)) ?? 65
        let style = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? "fog"
        perspective = (try? c.decodeIfPresent(Double.self, forKey: .perspective)) ?? 0.6
        // The legacy-default checks below compare against what an old
        // build read for a missing key (blur 0.5, shade 0.7), so the
        // stored values are kept apart from today's defaults.
        let storedBlur = try? c.decodeIfPresent(Double.self, forKey: .blur)
        let storedShade = try? c.decodeIfPresent(Double.self, forKey: .shade)
        blur = storedBlur ?? 0.6
        shade = storedShade ?? 0.67
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
        holdStrength = Self.decodeHold(c)
        dwellTimeout = (try? c.decodeIfPresent(Double.self, forKey: .dwellTimeout)) ?? 0
        restoreSound = (try? c.decodeIfPresent(Bool.self, forKey: .restoreSound)) ?? false
        wallpaperFallback = (try? c.decodeIfPresent(Bool.self, forKey: .wallpaperFallback)) ?? true
        let voiceRaw = (try? c.decodeIfPresent(String.self, forKey: .hingeVoice)) ?? nil
        hingeVoice = voiceRaw.flatMap(HingeVoice.init(rawValue:)) ?? .off
        // Each past default set is treated as untouched and moved to the
        // current one; any deliberate change means the file survives.
        // A file old enough to migrate never wrote `frost`, so the knob
        // reads its default there — a moved frost is a deliberate change.
        let legacyBlur = storedBlur ?? 0.5
        let legacyShade = storedShade ?? 0.7
        if activationAngle == 110, style == "tilt", perspective == 0.6,
           legacyBlur == 0.5, legacyShade == 0.4, jitterUntouched, frost == 0 {
            activationAngle = 65
            shade = 0.7
            jitterTolerance = 1.5
        } else if activationAngle == 82, style == "dusk", perspective == 0.6,
                  legacyBlur == 0.5, legacyShade == 0.4, jitterUntouched, frost == 0 {
            activationAngle = 65
            shade = 0.7
            jitterTolerance = 1.5
        }
        // The 0.65 milk shipped as a default for one build; a file that
        // still carries exactly that value never chose it.
        if frost == 0.65 { frost = 0 }
        look = ((try? c.decodeIfPresent(String.self, forKey: .look)) ?? nil)
            .flatMap(FoldLook.init(rawValue:)) ?? .duo
        let storedFade = try? c.decodeIfPresent(Double.self, forKey: .fadeLength)
        fadeLength = storedFade.map(Self.clampFadeLength) ?? 0.55
        // A file from before the looks folds from where the lid rests:
        // the Duo reacts from the first degree, and a fixed 65–70° start
        // sits below most of the close a seated eye can see. The stored
        // activation angle stays for anyone who picks "Set angle" again.
        if !c.contains(.look) { anchor = .movement }
    }

    /// `fadeLength` kept inside `fadeLengthRange`; a non-number reads
    /// as the default.
    public static func clampFadeLength(_ value: Double) -> Double {
        guard value.isFinite else { return 0.55 }
        return min(fadeLengthRange.upperBound, max(fadeLengthRange.lowerBound, value))
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
        try c.encode(dwellTimeout, forKey: .dwellTimeout)
        try c.encode(restoreSound, forKey: .restoreSound)
        try c.encode(wallpaperFallback, forKey: .wallpaperFallback)
        try c.encode(hingeVoice, forKey: .hingeVoice)
        try c.encode(holdStrength, forKey: .holdStrength)
        try c.encode(look, forKey: .look)
        try c.encode(fadeLength, forKey: .fadeLength)
    }

    /// The hold, read tolerantly: a stored strength wins (clamped to
    /// 0…1), else the retired switch by its label's meaning — on holds
    /// the picture (1), off rides the lid (0) — else a full hold.
    private static func decodeHold(_ c: KeyedDecodingContainer<CodingKeys>) -> Double {
        if let stored = try? c.decodeIfPresent(Double.self, forKey: .holdStrength),
           stored.isFinite {
            return min(1, max(0, stored))
        }
        if let legacy = try? c.decodeIfPresent(Bool.self, forKey: .holdPicture) {
            return legacy ? 1 : 0
        }
        return 1
    }
}

/// Fold's two looks (docs/TOYS.md §Fold): `.duo` holds one picture
/// still in space while the glass swings through it, blurring and
/// darkening away from the hinge into black, the way the iPhone Duo
/// folds; `.room` is the earlier portal room of window cards and a
/// far wall, with Frost and the seam light.
public enum FoldLook: String, Codable, CaseIterable, Sendable {
    case duo, room
}

/// Fold's hinge voice: what the lid's movement sounds like, if anything.
public enum HingeVoice: String, Codable, CaseIterable, Sendable {
    case off, creak, rustle
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
    /// Sunrise and sunset for the time zone's city, worked out locally;
    /// a zone without a city keeps `realTime`'s hours.
    case sun
    /// Night while macOS wears Dark mode, day in Light.
    case appearance
    /// Always the bright tank.
    case alwaysDay
    /// Always the night tank.
    case alwaysNight
}

/// Aquarium: every live session is a fish.
public struct AquariumSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// The always-on name chip, kept in step with `labelStyle` (on only
    /// for `.always`) and still written, so an older build reads it.
    public var showLabels: Bool {
        didSet {
            if showLabels != (labelStyle == .always) {
                labelStyle = showLabels ? .always : .hover
            }
        }
    }
    /// How much plankton the tank draws (the card's Plankton). Before
    /// `bubbles` and `scenery` it also set those two.
    public var density: Double
    /// Provider id → `FishSpecies` raw value — the tank's per-provider
    /// casting, set from a fish's inspector. A missing or unknown entry
    /// falls back to the provider's table species.
    public var speciesOverrides: [String: String]
    /// Where the day/night wash takes its clock from.
    public var dayNight: DayNightMode
    /// The idle screensaver: after this many minutes without input the
    /// tank fills every free screen until the next touch. 0 is off.
    public var idleFillMinutes: Int = 0
    /// The live wallpaper: the display (by its name) the tank lives on
    /// behind every window, click-through. nil is off.
    public var ambientDisplay: String? = nil
    /// The screensaver wears a quiet clock in its corner. On by default.
    public var saverClock: Bool = true
    /// Where a fish's name shows: always under it, only on hover, or
    /// never (the selected fish still names itself).
    public var labelStyle: AquariumLabelStyle = .always {
        didSet {
            if showLabels != (labelStyle == .always) { showLabels = labelStyle == .always }
        }
    }
    /// The tank's little voice — a plop, a gulp, a clink — from taps
    /// and window events only. Off by default.
    public var sound: Bool = false
    /// The most adult fish the tank draws at once; 0 is all of them.
    /// Asking, failing and leaving fish always show.
    public var maxFish: Int = 0
    /// Raised fish keep swimming after their sessions leave.
    public var keepResidents: Bool = true
    /// How many ambient bubbles rise; 0 is none.
    public var bubbles: Double = 1.0
    /// How much of the seeded dressing (kelp, rocks, shells) shows.
    public var scenery: AquariumScenery = .full
    /// The occasional passers-by — whale, diver, submarine, alien.
    public var visitors: Bool = true

    /// The screensaver's choices, in minutes; 0 is off.
    public static let idleFillChoices = [0, 5, 10, 15, 30]
    /// Fish at once, as the card offers it; 0 is all.
    public static let maxFishChoices = [0, 6, 10, 16, 24]
    /// Plankton's range; 0 clears the water. The same track as
    /// Bubbles, so the two sliders' knobs agree at the same value.
    public static let densityRange: ClosedRange<Double> = 0...2
    /// Bubbles' range; 0 turns the stream off.
    public static let bubblesRange: ClosedRange<Double> = 0...2

    public init(enabled: Bool = false, showLabels: Bool = true, density: Double = 1.0,
                speciesOverrides: [String: String] = [:],
                dayNight: DayNightMode = .realTime) {
        self.enabled = enabled
        self.showLabels = showLabels
        self.density = density
        self.speciesOverrides = speciesOverrides
        self.dayNight = dayNight
        self.labelStyle = showLabels ? .always : .hover
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, showLabels, density, speciesOverrides, dayNight
        case idleFillMinutes, ambientDisplay, saverClock
        case swimPace, swimSpeed, fishScale
        case labelStyle, sound, maxFish, keepResidents, bubbles, scenery, visitors
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        showLabels = (try? c.decodeIfPresent(Bool.self, forKey: .showLabels)) ?? true
        let rawDensity = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? 1.0
        density = Self.clamp(rawDensity, to: Self.densityRange, default: 1.0)
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .speciesOverrides)) ?? [:]
        speciesOverrides = raw.filter { FishSpecies(rawValue: $0.value) != nil }
        let dayNightRaw = (try? c.decodeIfPresent(String.self, forKey: .dayNight)) ?? nil
        dayNight = dayNightRaw.flatMap(DayNightMode.init(rawValue:)) ?? .realTime
        let idle = (try? c.decodeIfPresent(Int.self, forKey: .idleFillMinutes)) ?? 0
        idleFillMinutes = Self.idleFillChoices.contains(idle) ? idle : 0
        let display = (try? c.decodeIfPresent(String.self, forKey: .ambientDisplay)) ?? nil
        ambientDisplay = display?.isEmpty == false ? display : nil
        saverClock = (try? c.decodeIfPresent(Bool.self, forKey: .saverClock)) ?? true
        let pace = (try? c.decodeIfPresent(String.self, forKey: .swimPace)) ?? nil
        swimPace = pace.flatMap(SwimPace.init(rawValue:)) ?? .natural
        swimSpeed = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .swimSpeed)) ?? 1,
                                 to: Self.swimSpeedRange)
        fishScale = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .fishScale)) ?? 1,
                                 to: Self.fishScaleRange)
        // The label style: a file from before it existed reads its old
        // switch — off was really "on hover", since the nameplate still
        // showed.
        let styleRaw = (try? c.decodeIfPresent(String.self, forKey: .labelStyle)) ?? nil
        labelStyle = styleRaw.flatMap(AquariumLabelStyle.init(rawValue:))
            ?? (showLabels ? .always : .hover)
        showLabels = labelStyle == .always
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? false
        let cap = (try? c.decodeIfPresent(Int.self, forKey: .maxFish)) ?? 0
        maxFish = Self.maxFishChoices.contains(cap) ? cap : 0
        keepResidents = (try? c.decodeIfPresent(Bool.self, forKey: .keepResidents)) ?? true
        // Bubbles and scenery split off the old density: a file without
        // them keeps the tank it had.
        let rawBubbles = (try? c.decodeIfPresent(Double.self, forKey: .bubbles)) ?? nil
        bubbles = Self.clamp(rawBubbles ?? rawDensity, to: Self.bubblesRange,
                             default: 1.0)
        let sceneryRaw = (try? c.decodeIfPresent(String.self, forKey: .scenery)) ?? nil
        scenery = sceneryRaw.flatMap(AquariumScenery.init(rawValue:))
            ?? (density < 1 ? .light : .full)
        visitors = (try? c.decodeIfPresent(Bool.self, forKey: .visitors)) ?? true
    }

    /// A finite value pinned to `range`; anything else is `fallback`.
    private static func clamp(_ value: Double, to range: ClosedRange<Double>,
                              default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// What `provider` swims as: the user's pick when one is stored,
    /// else the table species.
    public func species(for provider: String) -> FishSpecies {
        if let raw = speciesOverrides[provider.lowercased()],
           let species = FishSpecies(rawValue: raw) { return species }
        return FishSpecies.forProvider(provider)
    }

    /// How busy the swimmers are: how often they wander and turn round.
    public var swimPace: SwimPace = .natural
    /// Multiplies how fast every fish swims — and turns, so its paths
    /// keep their shape. Read through `swimSpeedRange`.
    public var swimSpeed: Double = 1
    /// Multiplies every fish's drawn size, and its hover box with it.
    /// Read through `fishScaleRange`.
    public var fishScale: Double = 1

    /// The Swimming speed slider's reach.
    public static let swimSpeedRange: ClosedRange<Double> = 0.5...1.6
    /// The Fish size slider's reach.
    public static let fishScaleRange: ClosedRange<Double> = 0.6...1.6

    /// `value` inside `range`; a non-finite value reads as 1×.
    public static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 1 }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Where the tank shows a fish's name.
public enum AquariumLabelStyle: String, Codable, CaseIterable, Sendable {
    /// A small chip under every main fish.
    case always
    /// Only the name tag over the fish under the pointer.
    case hover
    /// No names at all, except the fish you selected.
    case never
}

/// How much of the seeded dressing the tank lays out.
public enum AquariumScenery: String, Codable, CaseIterable, Sendable {
    /// Every kelp stand, rock, shell and coral.
    case full
    /// About half, the signature pieces first.
    case light
    /// Just the chest and the starfish.
    case bare

    /// The share of `AquariumModel.decorSet` that shows.
    public var fraction: Double {
        switch self {
        case .full: return 1
        case .light: return 0.5
        case .bare: return 0.12
        }
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
    /// Docked, the buddy wears the Screen Bar's colour while a program
    /// is published, instead of its own resting tint. On by default.
    public var wearsStripColor: Bool = true
    /// Floating, it takes the odd calm walk along a window's top edge
    /// while the agents work, then comes home. On by default.
    public var walkabout: Bool = true
    /// What it wears — a `ShopItem` raw value from the tank shop's buddy
    /// shelf, bought with the tank's pearls. nil wears nothing; the app
    /// checks the item is owned before drawing it.
    public var wearing: String?
    /// About how many minutes pass between the floating buddy's walks
    /// while the agents work — the card's "Time between walks". Twelve
    /// is the cadence the walkabout always had; stored clamped into
    /// `walkEveryRange`.
    public var walkEvery: Double = NotchBuddySettings.defaultWalkEvery

    /// The walk dial's reach, in minutes, and where it starts.
    public static let walkEveryRange: ClosedRange<Double> = 3.0...40.0
    public static let defaultWalkEvery: Double = 12

    /// Minutes between walks only mean something inside the dial; a
    /// non-finite value reads as the default.
    public static func clampedWalkEvery(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWalkEvery }
        return min(walkEveryRange.upperBound, max(walkEveryRange.lowerBound, value))
    }

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
        case wearsStripColor, walkabout, wearing
        case walkEvery
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
        wearsStripColor = (try? c.decodeIfPresent(Bool.self, forKey: .wearsStripColor)) ?? true
        walkabout = (try? c.decodeIfPresent(Bool.self, forKey: .walkabout)) ?? true
        let worn = (try? c.decodeIfPresent(String.self, forKey: .wearing)) ?? nil
        wearing = worn?.isEmpty == false ? worn : nil
        // Missing or mistyped is the old cadence; a number off the dial clamps.
        walkEvery = Self.clampedWalkEvery(
            (try? c.decodeIfPresent(Double.self, forKey: .walkEvery)) ?? Self.defaultWalkEvery)
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
    /// Epoch seconds of the first pet, treat or crumb; 0 = not met yet.
    /// A log from before this field is seeded with its earliest stamp and
    /// `firstMetIsFloor` — the pal card then says "at least since".
    public var firstMetAt: Double = 0
    public var firstMetIsFloor: Bool = false
    /// Crumbs by the provider whose session finished — the pal card's
    /// favourite agent.
    public var crumbsByProvider: [String: Int] = [:]
    /// The longest ask it waited through with you, in seconds.
    public var longestAskSeconds: Double = 0

    public init(lastInteractionAt: Double = 0, lastTreatAt: Double = 0, lastCrumbAt: Double = 0,
                petCount: Int = 0, treatsGiven: Int = 0, crumbsEaten: Int = 0) {
        self.lastInteractionAt = lastInteractionAt
        self.lastTreatAt = lastTreatAt
        self.lastCrumbAt = lastCrumbAt
        self.petCount = petCount
        self.treatsGiven = treatsGiven
        self.crumbsEaten = crumbsEaten
        seedFirstMet()
    }

    /// A log with history but no meeting day met at least by its
    /// earliest stamp — the floor the pal card words as "at least since".
    private mutating func seedFirstMet() {
        guard firstMetAt <= 0 else { return }
        let stamps = [lastInteractionAt, lastTreatAt, lastCrumbAt].filter { $0 > 0 }
        guard let earliest = stamps.min() else { return }
        firstMetAt = earliest
        firstMetIsFloor = true
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
        meet(at: now)
        petCount += 1
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// The first time anything happens between you is the day you met.
    mutating func meet(at now: Date) {
        guard firstMetAt <= 0 else { return }
        firstMetAt = now.timeIntervalSince1970
        firstMetIsFloor = false
    }

    /// An ask resolved after `seconds` open — kept if it's the longest.
    public mutating func noteAsk(lasted seconds: Double) {
        guard seconds.isFinite, seconds > longestAskSeconds else { return }
        longestAskSeconds = seconds
    }

    /// The provider it has eaten the most crumbs from; ties break on the
    /// id so the pick can't flicker. nil before any crumb had a provider.
    public var favouriteProvider: (id: String, crumbs: Int)? {
        crumbsByProvider.filter { $0.value > 0 }
            .max { ($0.value, $1.key) < ($1.value, $0.key) }
            .map { ($0.key, $0.value) }
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
    public mutating func eat(at now: Date = Date(), count: Int = 1, provider: String? = nil) {
        meet(at: now)
        crumbsEaten += count
        lastCrumbAt = now.timeIntervalSince1970
        if let provider = provider?.lowercased(), !provider.isEmpty {
            crumbsByProvider[provider, default: 0] += count
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lastInteractionAt, lastTreatAt, lastCrumbAt, petCount, treatsGiven, crumbsEaten
        case firstMetAt, firstMetIsFloor, crumbsByProvider, longestAskSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastInteractionAt = (try? c.decodeIfPresent(Double.self, forKey: .lastInteractionAt)) ?? 0
        lastTreatAt = (try? c.decodeIfPresent(Double.self, forKey: .lastTreatAt)) ?? 0
        lastCrumbAt = (try? c.decodeIfPresent(Double.self, forKey: .lastCrumbAt)) ?? 0
        petCount = (try? c.decodeIfPresent(Int.self, forKey: .petCount)) ?? 0
        treatsGiven = (try? c.decodeIfPresent(Int.self, forKey: .treatsGiven)) ?? 0
        crumbsEaten = (try? c.decodeIfPresent(Int.self, forKey: .crumbsEaten)) ?? 0
        let crumbs = (try? c.decodeIfPresent([String: Int].self, forKey: .crumbsByProvider)) ?? [:]
        crumbsByProvider = crumbs.filter { $0.value > 0 }
        let longest = (try? c.decodeIfPresent(Double.self, forKey: .longestAskSeconds)) ?? 0
        longestAskSeconds = longest.isFinite ? max(0, longest) : 0
        if let met = (try? c.decodeIfPresent(Double.self, forKey: .firstMetAt)) ?? nil,
           met.isFinite, met > 0 {
            firstMetAt = met
            firstMetIsFloor = (try? c.decodeIfPresent(Bool.self, forKey: .firstMetIsFloor)) ?? false
        } else {
            // A log from before the field: the earliest stamp it kept is
            // the latest the two of you can have met.
            seedFirstMet()
        }
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
    /// Piece-count multiplier, 0.5…2 — the card's "Amount", a fine-tune
    /// on top of `intensity`.
    public var density: Double
    /// Hang-time multiplier, 0.7…1.5: how slowly the pieces fall and how
    /// long they rest. The pop and the spray keep their speed.
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
    /// A burst the room held (see `ToysState.hushDuringQuiet`): played
    /// smaller once the room clears, or let go.
    public var whenHeld: ConfettiHeldBurst = .later
    /// A soft synthesized pop and rustle with the burst. Off by default,
    /// and silent while JR-Bar is quiet.
    public var sound: Bool = false
    /// Where the burst comes from: the notch's lower lip by default.
    public var origin: ConfettiOrigin = .notch
    /// How big a burst is — about 90, 180 or 300 pieces on a laptop
    /// screen, scaled by each screen's area.
    public var intensity: ConfettiIntensity = .standard
    /// On a holiday, that day's colours and shapes (a local calendar,
    /// nothing asked of the network). Off by default.
    public var seasonal: Bool = false
    /// Every free screen, or only the main one.
    public var screens: ConfettiScreens = .all
    /// Milestones burst gold, big and from the corners, and "All caught
    /// up" is a gentle rain, whatever the look above. Off by default.
    public var momentStyles: Bool = false

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
        case whenHeld, sound
        case origin, intensity, seasonal, screens, momentStyles
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
        whenHeld = (try? c.decodeIfPresent(ConfettiHeldBurst.self, forKey: .whenHeld)) ?? .later
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? false
        origin = (try? c.decodeIfPresent(ConfettiOrigin.self, forKey: .origin)) ?? .notch
        intensity = (try? c.decodeIfPresent(ConfettiIntensity.self, forKey: .intensity)) ?? .standard
        seasonal = (try? c.decodeIfPresent(Bool.self, forKey: .seasonal)) ?? false
        screens = (try? c.decodeIfPresent(ConfettiScreens.self, forKey: .screens)) ?? .all
        momentStyles = (try? c.decodeIfPresent(Bool.self, forKey: .momentStyles)) ?? false
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
    /// A rare moment JR-Bar itself noticed: an Aquarium achievement, a
    /// new tank level, or the daemon's Milestone Odometer crossing a step
    /// (a `milestone` event). Opt-in like every trigger after the first.
    public var milestones: Bool = false

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
        case milestones
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .sessionCompleted)) ?? false
        weeklyReset = (try? c.decodeIfPresent(Bool.self, forKey: .weeklyReset)) ?? true
        perProviderReset = Set(((try? c.decodeIfPresent(Set<String>.self, forKey: .perProviderReset)) ?? [])
            .map { $0.lowercased() })
        codexBankedReset = (try? c.decodeIfPresent(Bool.self, forKey: .codexBankedReset)) ?? false
        allClear = (try? c.decodeIfPresent(Bool.self, forKey: .allClear)) ?? false
        milestones = (try? c.decodeIfPresent(Bool.self, forKey: .milestones)) ?? false
    }
}

/// Where confetti ends up: resting on the top edges of windows and the
/// Dock, raining off the bottom edge of the screen, or dissolving
/// mid-air.
public enum ConfettiLanding: String, Codable, CaseIterable, Sendable {
    case rest, fall, fade
}

/// Whose colours the burst wears: the provider's, the Toys page tint,
/// a party spectrum, gold and champagne, pastels, the tint alone, or
/// every provider working right now. An older file's `rainbow` reads
/// as Party, the palette that replaced it.
public enum ConfettiPalette: String, Codable, CaseIterable, Sendable {
    case provider, toys, party, gold, pastel, mono, everyone

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "rainbow" {
            self = .party
            return
        }
        guard let palette = ConfettiPalette(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "no palette named \(raw)"))
        }
        self = palette
    }
}

/// What the pieces are: the full mix, streamers only, small flecks,
/// the provider's own glyph, or stars.
public enum ConfettiShapes: String, Codable, CaseIterable, Sendable {
    case mixed, streamers, flecks, glyphs, stars
}

/// Where a burst comes from: out of the notch's lower lip (the menu
/// bar's bottom centre on a screen without one), out of JR-Bar's own
/// menu-bar icon, from cannons at the bottom corners, or as rain along
/// the top edge.
public enum ConfettiOrigin: String, Codable, CaseIterable, Sendable {
    case notch, icon, corners, rain
}

/// How big a burst is: Subtle, Standard or Big (Big throws a second
/// volley a beat later).
public enum ConfettiIntensity: String, Codable, CaseIterable, Sendable {
    case subtle, standard, big
}

/// Which screens a burst plays on: every screen no fullscreen app owns,
/// or only the main one.
public enum ConfettiScreens: String, Codable, CaseIterable, Sendable {
    case all, main
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
    /// place `weatherCity` names (the IP's coarse fix only with
    /// `weatherUseIPLocation`). Off by default: it phones a third-party
    /// API, so the person turns it on.
    public var weather: Bool
    /// A city name to geocode ("London"); empty means no row unless
    /// `weatherUseIPLocation` allows the IP lookup.
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
    /// The card's calendar glance. On by default — it reads only where
    /// Calendar access was granted (the ask is Setup's and this
    /// switch's), and off keeps the row away entirely.
    public var calendar: Bool = true
    /// The card's reminders glance — the same rule as `calendar`.
    public var reminders: Bool = true
    /// With no `weatherCity`, place the weather by a coarse IP lookup
    /// (ipapi.co). Off by default: it sends the IP to a second third
    /// party, so an empty city otherwise just means no weather row.
    public var weatherUseIPLocation: Bool = false
    /// Synced lyrics from LRCLIB under the card's media row. Off by
    /// default: it sends the track's title, artist, album and length to
    /// a third party, so it waits for the person's own switch.
    public var lyrics: Bool = false
    /// The person said yes to LRCLIB: the switch turned on in Settings,
    /// or the card's one-line offer clicked. Lyrics shipped on by
    /// default, so a saved `lyrics: true` from then carries no consent:
    /// a missing key reads false and the card offers it once.
    public var lyricsConsented: Bool = false
    /// Lookups may leave the Mac: the switch is on and agreed to.
    public var lyricsAllowed: Bool { lyrics && lyricsConsented }
    /// While the Mac is quiet (a Focus synced in, or a quiet mode),
    /// completions and quota resets wait and replay as one summary
    /// capsule afterwards; asks and failures still show.
    public var holdNewsWhileQuiet: Bool = true
    /// Two minutes before a timed event with a join link, the island
    /// says so with Join; while it runs it is a quiet stretch like a
    /// Focus. Off by default: it reads the calendar in the background,
    /// not only while the card is open.
    public var meetingAlerts: Bool = false
    /// A due timer breathes the LED strips orange three times, so it is
    /// noticed across the room — only where a strip is connected, never
    /// while the Mac is quiet.
    public var timerLights: Bool = true

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
        case calendar, reminders
        case weatherUseIPLocation
        case lyrics
        case lyricsConsented
        case holdNewsWhileQuiet
        case meetingAlerts
        case timerLights
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
        calendar = (try? c.decodeIfPresent(Bool.self, forKey: .calendar)) ?? true
        reminders = (try? c.decodeIfPresent(Bool.self, forKey: .reminders)) ?? true
        weatherUseIPLocation = (try? c.decodeIfPresent(Bool.self, forKey: .weatherUseIPLocation)) ?? false
        lyrics = (try? c.decodeIfPresent(Bool.self, forKey: .lyrics)) ?? false
        lyricsConsented = (try? c.decodeIfPresent(Bool.self, forKey: .lyricsConsented)) ?? false
        holdNewsWhileQuiet = (try? c.decodeIfPresent(Bool.self, forKey: .holdNewsWhileQuiet)) ?? true
        meetingAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .meetingAlerts)) ?? false
        timerLights = (try? c.decodeIfPresent(Bool.self, forKey: .timerLights)) ?? true
    }
}

/// Who renders the island: ours, Henrik's Alcove, or boring.notch.
public enum NotchProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, alcove, boringNotch
}


