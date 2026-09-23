import AppKit
import JRBarCore
import SwiftUI

/// One wing slot's content: a lobe of the notch itself — the selected
/// task on the left, the headline usage meter on the right, or a
/// transient device notice. The ear draws a mark only — the provider's
/// bare glyph, a quota ring, or an SF symbol; `text` is the peek's and
/// VoiceOver's copy, not the ear's face. `tone` is the state colour.
struct ScreenBarWingSlot: Equatable {
    enum Tone: Equatable {
        /// White on the black lobe — ambient information.
        case neutral
        /// Waiting is amber everywhere in the app.
        case attention
        /// Failed is red.
        case alert
    }

    var text: String
    var provider: String?
    /// An SF Symbol leading the words instead of a provider glyph —
    /// "bolt.fill" for a charger, "headphones" for an output route.
    var symbol: String?
    /// The ear's ring fill, 0…1 — the usage meter's fraction. nil means
    /// no ring (state ears, notices).
    var meter: Double?
    /// The mark is a live equalizer instead of a glyph — the media ear,
    /// drawn only while something is actually playing. `text` still
    /// carries the track line for the peek and VoiceOver.
    var visualizer = false
    /// The track's album art — a PNG/JPEG payload the mark shows as a
    /// rounded tile, Alcove's media-wing grammar: art on the left ear,
    /// the equalizer on the right. nil leaves the other marks to draw.
    var artworkData: Data?
    /// How long this ear's ask has waited, as a ring that fills on its
    /// own clock toward the loudest escalation stage. nil draws the bare
    /// glyph. Only the asking session's ear carries one.
    var askAge: ScreenBarAskAge?
    /// The privacy dots — the island's mic and camera LEDs, carried onto
    /// the right ear while the ears own the notch's shoulders (the island
    /// rests bare then, so they would otherwise never draw). nil or quiet
    /// draws none.
    var sensors: NotchSensorState?
    var tone: Tone = .neutral
    /// A second, smaller mark at the ear's outer end — the keep-awake
    /// cup or the closed-lid moon riding beside whatever the ear shows,
    /// so a hold that lasts all afternoon never takes the meter's place.
    /// nil draws none.
    var accessory: ScreenBarWingAccessory?
    /// A menu bar item's own glyph as the mark — a newcomer's, or a
    /// hidden item that changed — photographed off the bar, re-tinted
    /// when it is a template. nil leaves the other marks to draw.
    var glyph: ScreenBarWingGlyph?
    /// Which of its kind this mark is, when the kind alone does not say:
    /// two nudges both draw a glyph, and the second is news even while
    /// the first ear is dismissed. nil for every mark that needs none.
    var markID: String?

    /// Whether the slot draws a mark of its own beside any dots. A slot
    /// with neither still holds its claim with the lone resting dot.
    var hasMark: Bool {
        provider != nil || symbol != nil || meter != nil || visualizer
            || artworkData != nil || askAge != nil || glyph != nil
    }

    /// Whether the slot carries lit privacy dots.
    var showsSensors: Bool { sensors?.anyInUse ?? false }

    var textColor: Color {
        switch tone {
        case .neutral: return .white.opacity(0.92)
        case .attention: return .orange
        case .alert: return .red
        }
    }
}

/// A photographed menu bar glyph as an ear's mark. Equal when it is the
/// same picture — the glyph cache hands out one image per photograph.
struct ScreenBarWingGlyph: Equatable {
    var image: NSImage
    /// Drawn in the slot's tone, as the bar draws a template item.
    var template: Bool

    /// The room the mark may take inside the ear's 36 pt. Only an
    /// icon-sized photograph or an app icon reaches the ear — a glyph
    /// carrying text is the peek's, never the ear's — so the cap only
    /// ever eases a wide icon in a point or two rather than let it spill.
    static let maxWidth: CGFloat = 26
    static let maxHeight: CGFloat = 15
}

/// The ear's second mark: an SF symbol a size down from the main one,
/// at the ear's outer end, in its own tone.
struct ScreenBarWingAccessory: Equatable {
    var symbol: String
    var tone: ScreenBarWingSlot.Tone = .neutral

    /// The room it adds to its ear.
    static let width: CGFloat = 14
    /// Its point size — the menu bar's small glyphs, beside the 13 pt
    /// mark.
    static let size: CGFloat = 10
}

/// The two slots: nil means the side draws nothing and claims no room —
/// empty slots collapse rather than hold space open.
struct ScreenBarWings: Equatable {
    var left: ScreenBarWingSlot?
    var right: ScreenBarWingSlot?

    static let empty = ScreenBarWings()

    subscript(side: ScreenBarWingSide) -> ScreenBarWingSlot? {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    /// `wings` with the privacy dots on the right ear — the island's own
    /// shoulder for them — beside whatever mark it holds, or as an ear of
    /// their own when nothing else claims that side. The dots are a
    /// privacy fact, not a subject: they never change the ear's identity
    /// for a dismissal, and a dismissed ear still shows them.
    static func withSensors(_ sensors: NotchSensorState, on wings: ScreenBarWings) -> ScreenBarWings {
        guard sensors.anyInUse else { return wings }
        var dressed = wings
        let words = sensorWords(sensors)
        if var right = dressed.right {
            right.sensors = sensors
            right.text += " · " + words.lowercased()
            dressed.right = right
        } else {
            dressed.right = ScreenBarWingSlot(text: words, sensors: sensors)
        }
        return dressed
    }

    /// VoiceOver's words for the dots — the island's own phrasing.
    static func sensorWords(_ sensors: NotchSensorState) -> String {
        if sensors.cameraInUse, sensors.microphoneInUse { return "Camera and microphone in use" }
        return sensors.cameraInUse ? "Camera in use" : "Microphone in use"
    }
}

/// The privacy dots' measure on an ear: 5 pt dots at the island's 4 pt
/// rhythm, set in from the bezel's edge by the island's separator width,
/// so the pair reads as the hardware LED's neighbours, not a stray mark.
enum ScreenBarSensorDots {
    static let diameter: CGFloat = 5
    static let spacing: CGFloat = 4
    /// From the ear's inner (bezel) edge to the first dot, and from the
    /// last dot to the mark's own zone.
    static let inset: CGFloat = NotchIsland.sensorSeparatorWidth

    /// The dots' own width.
    static func width(_ sensors: NotchSensorState?) -> CGFloat {
        let dots = sensors.map { $0.anyInUse ? $0.dotCount : 0 } ?? 0
        return dots > 0 ? CGFloat(dots) * diameter + CGFloat(dots - 1) * spacing : 0
    }

    /// What the dots add to an ear: the inset before them and their
    /// width; a dots-only ear closes with the inset on its far side too.
    static func lead(_ sensors: NotchSensorState?) -> CGFloat {
        let dots = width(sensors)
        return dots > 0 ? inset + dots : 0
    }
}

/// An open ask's wait, read as the escalation ladder reads it: the ring
/// is empty when the ask opens and full when the ladder reaches the
/// loudest stage `escalation_tier` allows — the same seconds Settings ›
/// Notifications › Escalation sets. It fills on its own clock, so the
/// wings are not re-laid every tick; the ear redraws the arc alone.
struct ScreenBarAskAge: Equatable {
    /// When the ask opened — the daemon's `opened_at`.
    var openedAt: Date
    /// Seconds from open to a full ring.
    var fullAfter: TimeInterval
    /// Whose ask it is: the ring only lands on that provider's mark.
    var provider: String

    /// The ring's fill at `now`, 0…1.
    func fraction(at now: Date) -> Double {
        guard fullAfter > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(openedAt) / fullAfter))
    }

    /// When the ring is full and the ear stops redrawing it.
    var fullAt: Date { openedAt.addingTimeInterval(max(0, fullAfter)) }

    /// The span a full ring stands for: the threshold of the loudest
    /// stage the tier lets an ignored ask reach — the ramp for "light
    /// only", the menu-bar pulse for "menu bar", the final stage for
    /// chime and take-over. A ladder switched off still ages the ring,
    /// on the final stage's patient clock. Absent timings are the
    /// daemon's defaults (30 s, 120 s, 300 s).
    static func span(tier: String?, ramp: Double?, menuBar: Double?, final: Double?) -> TimeInterval {
        let ramp = max(1, ramp ?? 30)
        let menuBar = max(1, menuBar ?? 120)
        let final = max(1, final ?? 300)
        switch EventPolicy.escalationCeiling(tier) {
        case 1: return ramp
        case 2: return menuBar
        default: return final
        }
    }

    /// The tier that governs one provider's asks: the global
    /// `escalation_tier`, lowered by that provider's own ceiling in
    /// `escalation_tier_by_provider` — which only ever lowers the stage,
    /// never arms one the global tier does not.
    static func tier(global: String?, provider: String?) -> String? {
        guard let provider, EventPolicy.escalationCeiling(global) > 0,
              EventPolicy.escalationCeiling(provider) < EventPolicy.escalationCeiling(global) else { return global }
        return provider
    }

    /// The ring for `ask`, or nil when the daemon never dated it — an
    /// undated ask has no age to show, and a guess would be a lie.
    static func make(ask: CoreAsk?, provider: String, document: SettingsDocument) -> ScreenBarAskAge? {
        guard let opened = ask?.openedAt else { return nil }
        let ceiling = document.object("escalation_tier_by_provider")?[provider]?.stringValue
        return ScreenBarAskAge(
            openedAt: Date(timeIntervalSince1970: opened),
            fullAfter: span(tier: tier(global: document.string("escalation_tier"), provider: ceiling),
                            ramp: document.double("escalation_ramp_seconds"),
                            menuBar: document.double("escalation_menu_bar_seconds"),
                            final: document.double("escalation_final_seconds")),
            provider: provider)
    }
}

/// When the ask-age ring redraws: about 120 steps across the whole span
/// — under half a point of arc each on a 16 pt ring, so the fill reads
/// as continuous — and none once it is full. Low-frequency mode (the
/// display dimmed) takes quarter the steps.
struct ScreenBarAskAgeSchedule: TimelineSchedule {
    let age: ScreenBarAskAge

    static let steps: Double = 120

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let steps = mode == .lowFrequency ? Self.steps / 4 : Self.steps
        let step = max(1, age.fullAfter / steps)
        let end = age.fullAt
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            let following = current.addingTimeInterval(step)
            // One last entry lands exactly on full, then the ring rests.
            if current >= end {
                next = nil
            } else {
                next = following < end ? following : end
            }
            return current
        }
    }
}

/// What the ears add on top of the panel store's slots — facts only the
/// Screen Bar draws: the ask-age ring on the asking session's mark, the
/// moon while a quiet is dimming the lights, and the keep-awake mark on
/// the right. The store's slots stay the one pick of who is on top;
/// these only dress them.
struct ScreenBarEarMarks: Equatable {
    /// The quiet in force, as the ear shows it: a mark, and the words
    /// the peek and VoiceOver read ("Paused until 14:30").
    struct Quiet: Equatable {
        var symbol: String
        var text: String
    }

    /// The daemon's hold on sleep, as the right ear shows it: the cup
    /// while the person's own lease holds, the moon while the closed-lid
    /// hold runs; the words for the peek and VoiceOver ("Held awake
    /// until 14:30"). Amber when heat or the battery floor made it yield.
    struct Awake: Equatable {
        var symbol: String
        var text: String
        var tone: ScreenBarWingSlot.Tone = .neutral
    }

    var askAge: ScreenBarAskAge?
    var quiet: Quiet?
    var awake: Awake?

    /// The lease's cup — Amphetamine's mark, the notch chip's glyph.
    static let leaseSymbol = "cup.and.saucer.fill"
    /// The closed-lid hold's moon — the stars keep it apart from the
    /// quiet's plain moon on the other ear.
    static let lidSymbol = "moon.stars.fill"

    /// The mark for `state.power`, or nil while neither hold runs. The
    /// agents' own automatic hold is not shown: it comes and goes with
    /// every run, and the band already says the agents are working. The
    /// closed-lid hold outranks a lease — it is the one that keeps a
    /// shut laptop running. A lease's end reads as a clock time, so the
    /// words only move when the lease does.
    static func awake(power: CorePower?, calendar: Calendar = .current) -> Awake? {
        guard let power else { return nil }
        if let lid = power.closedLid, lid.holding == true {
            return Awake(symbol: lidSymbol,
                         text: lid.lidClosed == true ? "Running with the lid closed"
                             : "Keeps running if the lid closes")
        }
        guard let hold = power.hold, hold.isManual, let lease = hold.lease else { return nil }
        if let yielded = hold.suspended {
            let why = yielded == "thermal" ? "the Mac is too warm"
                : yielded == "battery" ? "the battery is low" : "it yielded"
            return Awake(symbol: leaseSymbol, text: "Keep-awake paused — \(why)", tone: .attention)
        }
        var text: String
        switch lease.kind {
        case "duration":
            if let until = lease.until {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                text = "Held awake until \(formatter.string(from: Date(timeIntervalSince1970: until)))"
            } else {
                text = "Held awake"
            }
        case "agents":
            text = "Held awake until the agents finish"
        default:
            text = "Held awake until you turn it off"
        }
        if lease.display == true { text += ", the screen too" }
        return Awake(symbol: leaseSymbol, text: text)
    }

    /// The quiet modes that change the light. Mute stills only the
    /// sounds — the band is as bright as ever, so it needs no moon.
    static let lightQuietModes: Set<String> = ["pause", "dim", "asks_only", "dark"]

    /// The moon for `mode` and its words, or nil for a quiet that leaves
    /// the lights alone. A timed quiet names its end as a clock time —
    /// the ear's words only move when the quiet does, never every minute.
    static func quiet(mode: String?, word: String, until: Date?, calendar: Calendar = .current) -> Quiet? {
        guard let mode, lightQuietModes.contains(mode) else { return nil }
        guard let until else { return Quiet(symbol: "moon.fill", text: word) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return Quiet(symbol: "moon.fill", text: "\(word) until \(formatter.string(from: until))")
    }

    /// `wings` dressed with these marks. The ring joins the left ear only
    /// while that ear is the asking session's own mark (amber, its
    /// provider's glyph). The moon takes a left ear that has nothing
    /// louder to say — empty, or a working or finished session — and
    /// never an ask, a failure, or the media ear, which is a live
    /// activity of its own. The keep-awake mark rides the right ear as
    /// its accessory, beside whatever it shows, or is the ear's own
    /// mark when nothing else claims the side.
    static func apply(_ marks: ScreenBarEarMarks, to wings: ScreenBarWings) -> ScreenBarWings {
        var dressed = wings
        if let age = marks.askAge, var left = dressed.left, left.tone == .attention,
           left.provider == age.provider, left.symbol == nil, left.artworkData == nil,
           !left.visualizer, left.meter == nil {
            left.askAge = age
            dressed.left = left
        }
        if let quiet = marks.quiet {
            let yields: Bool
            if let left = dressed.left {
                yields = left.tone == .neutral && left.artworkData == nil && !left.visualizer
            } else {
                yields = true
            }
            if yields {
                dressed.left = ScreenBarWingSlot(text: quiet.text, symbol: quiet.symbol)
            }
        }
        if let awake = marks.awake {
            if var right = dressed.right {
                right.accessory = ScreenBarWingAccessory(symbol: awake.symbol, tone: awake.tone)
                right.text += " · " + awake.text
                dressed.right = right
            } else {
                dressed.right = ScreenBarWingSlot(text: awake.text, symbol: awake.symbol, tone: awake.tone)
            }
        }
        return dressed
    }
}

extension PanelStore {
    /// The ears' own marks for this moment: the longest-waiting ask's
    /// age (the same row the left ear names — asks lead `rows`, oldest
    /// first), the light-changing quiet, if one is in force, and the
    /// keep-awake hold read from `state.power`.
    var screenBarEarMarks: ScreenBarEarMarks {
        var marks = ScreenBarEarMarks()
        let document = settingsDocument ?? SettingsDocument()
        if let row = askRows.first {
            marks.askAge = ScreenBarAskAge.make(ask: row.ask, provider: row.style.id, document: document)
        }
        if let quiet {
            marks.quiet = ScreenBarEarMarks.quiet(mode: quiet.mode, word: Self.quietWord(quiet.mode),
                                                  until: quiet.until)
        }
        // A dead daemon holds nothing: its last word is not a hold.
        if core.isLive {
            marks.awake = ScreenBarEarMarks.awake(power: core.state?.power)
        }
        return marks
    }
}

/// What the wings view draws: each side's slot and the rect the
/// geometry claimed for it, plus the tray — the one continuous shape
/// that runs from the left claim, under the bezel, to the right claim,
/// ending where the bezel ends. All in view coordinates (origin
/// bottom-left, as `ScreenBarGeometry.wingSlotRect` returns them — the
/// view flips y for SwiftUI's top-left space).
@MainActor
@Observable
final class ScreenBarWingsModel {
    /// Each tuple's rect is the mark's zone — on the right it stops
    /// short of the handle slice, so the mark centres in what is left.
    var left: (slot: ScreenBarWingSlot, rect: CGRect)?
    var right: (slot: ScreenBarWingSlot, rect: CGRect)?
    /// The right ear's full bounds — mark zone plus the handle slice —
    /// for the hover wash. nil when no right ear draws.
    var rightEar: CGRect?
    /// The hidden-run handle's slice of the right ear — a control drawn
    /// in our own surface, so it can never park the way a status item
    /// does. The ‹ is the fallback affordance while the menu-bar
    /// concealer runs and no mirror carries the icon (the Hidden style,
    /// or an empty target); nil otherwise.
    var rightHandle: CGRect?
    var rightHandleRevealed = false
    /// The shared body — the ears are its visible ends, the stretch
    /// behind the bezel joins them. nil on notch-less screens, where the chips
    /// carry their own capsules beside the band.
    var tray: CGRect?
    /// The tray's bottom corner — the notch profile's radius, so the
    /// wrap's silhouette is the bezel's own.
    var notchCorner: CGFloat = NotchProfile.standardCornerRadius
    var viewHeight: CGFloat = 0
    /// The dismiss-pull: the ear rides the finger's horizontal travel,
    /// already eased, so a flick visibly drags it off the notch.
    var leftPull: CGFloat = 0
    var rightPull: CGFloat = 0
    /// The hover tell: the ear under the pointer swells — proof the
    /// notch is alive while the intent debounce decides on the card.
    var leftSwell = false
    var rightSwell = false
}

/// The wing lobes. The drawn ear is a fixed-size complication hugging
/// the bezel — a mark inside the notch's own black shape continuing,
/// flush with the screen's top edge, where a centred capsule or bare
/// text in open menu-bar space reads as clutter. The claim is only the
/// ceiling on room; the ear's drawn bounds are what hit regions follow.
struct ScreenBarWingsView: View {
    @Bindable var model: ScreenBarWingsModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tray = model.tray {
                // A continuous body joins the wings across the physical notch.
                UnevenRoundedRectangle(bottomLeadingRadius: model.notchCorner,
                                       bottomTrailingRadius: model.notchCorner,
                                       style: .continuous)
                    .fill(.black)
                    .frame(width: tray.width, height: tray.height)
                    .position(x: tray.midX, y: model.viewHeight - tray.midY)
            }
            if let left = model.left { chip(left.slot, rect: left.rect, side: .left) }
            if let right = model.right { chip(right.slot, rect: right.rect, side: .right) }
            if let handle = model.rightHandle {
                // The hidden-run toggle — ‹ for "items parked left of
                // the bar", › while the run is out. Our own surface,
                // so it can never be covered or parked.
                Image(systemName: model.rightHandleRevealed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: handle.width, height: handle.height)
                    .position(x: handle.midX, y: model.viewHeight - handle.midY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Hidden menu bar items"))
            }
            // A handle-only right ear still needs its hover wash.
            if model.right == nil, let ear = model.rightEar, model.rightSwell {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: model.notchCorner,
                    topTrailingRadius: 0, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .frame(width: ear.width, height: ear.height)
                    .position(x: ear.midX, y: model.viewHeight - ear.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// The hover tell's reach — outward only, never over the bezel.
    static let swellReach: CGFloat = 3
    /// …and its grow — a whisper of scale on the mark itself.
    static let swellScale: CGFloat = 1.18

    /// The slot's mark — a symbol, never words. The ear is a complication
    /// on the bezel: the provider's bare glyph for state, a meter ring
    /// for quota, an SF mark for notices. The words stay in the peek and
    /// in VoiceOver.
    @ViewBuilder
    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        let tint = slot.tone == .neutral ? nil : slot.textColor
        // A dismiss-pull drags the ear off the bezel, fading as it goes.
        let pull = side == .left ? model.leftPull : model.rightPull
        // The tell reaches only outward — inward travel would paint the
        // mark over the bezel.
        let swell = side == .left ? model.leftSwell : model.rightSwell
        let reach = swell ? Self.swellReach * (side == .left ? -1 : 1) : 0
        let mark = Group {
            if let artwork = slot.artworkData, let image = NSImage(data: artwork) {
                // Album art — Alcove's media ear: a small rounded tile,
                // the track's own face against the notch black.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 19, height: 19)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else if let glyph = slot.glyph {
                // A menu bar item's own face — a newcomer, or a hidden
                // item that changed — at the bar's own glyph size.
                Image(nsImage: glyph.image)
                    .renderingMode(glyph.template ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(slot.textColor)
                    .frame(maxWidth: ScreenBarWingGlyph.maxWidth, maxHeight: ScreenBarWingGlyph.maxHeight)
            } else if slot.visualizer {
                // The media ear: three bars bouncing on their own
                // phases — the island strip's grammar, not a spectrum.
                // The slot only exists while the track plays; Reduce
                // Motion pins them still. 12 fps is plenty at 13 pt.
                TimelineView(.animation(minimumInterval: 1.0 / 12.0,
                                        paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(slot.textColor)
                                .frame(width: 2.5,
                                       height: 3 + 7 * abs(sin(t * 3.2 + Double(index) * 1.9)))
                        }
                    }
                    .frame(height: 13, alignment: .bottom)
                }
            } else if let symbol = slot.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(slot.textColor)
            } else if let meter = slot.meter {
                ring(meter, slot: slot, tint: tint)
            } else if let age = slot.askAge {
                // The ask's wait: the quota ear's ring grammar, in the
                // ask's amber, filling toward the loudest stage.
                TimelineView(ScreenBarAskAgeSchedule(age: age)) { context in
                    ring(age.fraction(at: context.date), slot: slot, tint: tint)
                }
            } else if let provider = slot.provider {
                glyph(.style(for: provider), size: 13, tint: tint)
            } else if !slot.showsSensors {
                // A slot with words but no mark still holds its claim —
                // the lone dot is the resting grammar.
                Circle().fill(slot.textColor).frame(width: 5, height: 5)
            }
        }
        .scaleEffect(swell ? Self.swellScale : 1)
        .opacity(1 - min(1, abs(pull) / 40))
        // The privacy dots sit at the ear's inner edge, beside the bezel
        // — the camera LED's own neighbourhood — the accessory at its
        // outer end, and the mark centres in what is left of the zone.
        // A flank too tight for both gives up the accessory first.
        let lead = slot.showsSensors ? ScreenBarSensorDots.lead(slot.sensors) : 0
        let accessoryW: CGFloat = slot.accessory != nil
            && rect.width - lead >= ScreenBarView.markMinWidth + ScreenBarWingAccessory.width
            ? ScreenBarWingAccessory.width : 0
        let markZone = CGRect(x: rect.minX + lead + (side == .left ? accessoryW : 0), y: rect.minY,
                              width: max(0, rect.width - lead - accessoryW), height: rect.height)
        let accessoryZone = CGRect(x: side == .left ? rect.minX : markZone.maxX, y: rect.minY,
                                   width: accessoryW, height: rect.height)

        if model.tray != nil {
            // The wash covers the ear's full span — the mark's zone plus
            // the handle's slice on the right; the mark keeps its own
            // rect so it centres left of the handle.
            let wash = side == .right ? (model.rightEar ?? rect) : rect
            ZStack {
                if swell {
                    // The hover tell's body: a light wash over the ear's
                    // own silhouette — square top, the outer bottom
                    // corner rounded like the tray's cap — so the wing
                    // itself answers the pointer, not just the mark.
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: side == .left ? model.notchCorner : 0,
                        bottomTrailingRadius: side == .right ? model.notchCorner : 0,
                        topTrailingRadius: 0, style: .continuous)
                        .fill(.white.opacity(0.10))
                }
                // An ear the flank shrank below a mark's room draws the
                // cap alone — a glyph that size clips against the edge.
                if markZone.width >= ScreenBarView.markMinWidth {
                    mark
                        .offset(x: markZone.midX - wash.midX + pull + reach)
                }
                if let accessory = slot.accessory, accessoryW > 0 {
                    accessoryMark(accessory)
                        .scaleEffect(swell ? Self.swellScale : 1)
                        .opacity(1 - min(1, abs(pull) / 40))
                        .offset(x: accessoryZone.midX - wash.midX + pull + reach)
                }
                // The dots outrank the mark for room: a privacy light
                // is never the thing a crowded flank squeezes out.
                if let sensors = slot.sensors, sensors.anyInUse,
                   rect.width >= ScreenBarSensorDots.lead(sensors) {
                    sensorDots(sensors)
                        .offset(x: rect.minX + ScreenBarSensorDots.inset
                                    + ScreenBarSensorDots.width(sensors) / 2 - wash.midX + pull)
                        .opacity(1 - min(1, abs(pull) / 40))
                }
            }
            .frame(width: wash.width, height: wash.height)
            // The wash stays welded to the tray; the mark rides the
            // pull and the outward reach inside it.
            .position(x: wash.midX, y: model.viewHeight - wash.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(slot.text))
        } else {
            HStack(spacing: ScreenBarSensorDots.inset) {
                if let sensors = slot.sensors, sensors.anyInUse { sensorDots(sensors) }
                if side == .left, let accessory = slot.accessory { accessoryMark(accessory) }
                mark
                if side == .right, let accessory = slot.accessory { accessoryMark(accessory) }
            }
                .padding(.vertical, 4)
                .fixedSize()
                .background(Capsule(style: .continuous).fill(.black))
                .frame(width: rect.width, height: rect.height,
                       alignment: side == .left ? .trailing : .leading)
                .position(x: rect.midX + pull + reach, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(slot.text))
        }
    }

    /// The ear's second mark — a symbol a size down, in its own tone.
    private func accessoryMark(_ accessory: ScreenBarWingAccessory) -> some View {
        Image(systemName: accessory.symbol)
            .font(.system(size: ScreenBarWingAccessory.size, weight: .semibold))
            .foregroundStyle(ScreenBarWingSlot(text: "", tone: accessory.tone).textColor)
            .accessibilityHidden(true)
    }

    /// The privacy dots — macOS's own convention in the island's dot
    /// language: green while a camera rolls, orange while a mic is live,
    /// the camera nearest the notch like the hardware LED it mirrors.
    private func sensorDots(_ sensors: NotchSensorState) -> some View {
        HStack(spacing: ScreenBarSensorDots.spacing) {
            if sensors.cameraInUse {
                Circle().fill(.green)
                    .frame(width: ScreenBarSensorDots.diameter, height: ScreenBarSensorDots.diameter)
            }
            if sensors.microphoneInUse {
                Circle().fill(.orange)
                    .frame(width: ScreenBarSensorDots.diameter, height: ScreenBarSensorDots.diameter)
            }
        }
    }

    /// The quota ear: a thin ring filling to `fraction` — the battery-glyph
    /// grammar every Mac user reads — with the provider's mark inside.
    /// The reset countdown lives in the ear's text and tooltip: a second
    /// arc inside the ring read as a stray line over the mark, so it went.
    /// Sized to the menu bar's own glyphs: an 18 pt ring inked ~20 pt
    /// tall beside Wi-Fi's 11.5 and the battery's 13.5 (measured
    /// 2026-09-22) and made the right ear read heavy. 16 pt keeps the
    /// inner mark — Codex's `</>` included — legible at 8 pt.
    private func ring(_ fraction: Double, slot: ScreenBarWingSlot, tint: Color?) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 1.4)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint ?? (slot.provider.map { ProviderStyle.style(for: $0).accent } ?? .white),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let provider = slot.provider {
                glyph(.style(for: provider), size: 8, tint: tint)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// The provider's bare glyph in its accent — no badge: the boxed
    /// `ProviderTile` reads as a menu-bar icon where the references draw a
    /// plain mark against the notch extension. `tint` wins for the
    /// attention/alert tones.
    @ViewBuilder
    private func glyph(_ style: ProviderStyle, size: CGFloat, tint: Color? = nil) -> some View {
        switch style.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? style.accent)
        case .text(let text):
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(tint ?? style.accent)
        }
    }
}
