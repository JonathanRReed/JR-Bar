import AppKit
import JRBarCore
import SwiftUI

/// The second litter of Notch Buddy characters (`BuddyCharacter`'s
/// newer half), all on the same `BuddyFigure` skeleton as the original
/// six: pose, blink, care and effects come from the skeleton — these
/// only draw the body. Same rules: gradient-lit, features that read at
/// 18pt, the shared eyes and mouths where the anatomy allows them, and
/// `still` drops every sway to a fixed pose.

// MARK: - Axolotl

/// Axolotl — a wide soft head that never grew up: three pink gill
/// fronds fanning off each cheek (they sway, droop in the slump and
/// perk for asks), a faint permanent blush, and the shared hole-punch
/// eyes and mood mouths.
struct AxolotlBody: View {
    /// Each mood's share of the frame (`BuddyMoodShares`): the parts
    /// shaped by mood swing through a mood change with the pose.
    let moods: BuddyMoodShares
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// The frill pink — axolotl gills are this colour whatever accent
    /// the body wears.
    private var gill: Color { Color(red: 0.95, green: 0.42, blue: 0.58) }

    /// -1 drooped → 1 perked: the gill fan's posture per mood.
    static func frillLift(_ mood: NotchBuddyToy.Mood) -> Double {
        switch mood {
        case .waving, .celebrating: return 1.0
        case .gathering: return 0.4
        case .pacing: return 0.15
        case .slumped, .asleep: return -1.0
        }
    }

    /// How far the fan swings from its resting spread, in degrees: a
    /// perk lifts it up to 10°, a droop lets it fall up to 18°.
    static func frillSwing(_ mood: NotchBuddyToy.Mood) -> Double {
        let lift = frillLift(mood)
        return max(0, -lift) * 18 - max(0, lift) * 10
    }

    var body: some View {
        ZStack {
            frills(left: true)
            frills(left: false)
            head
            BuddyEyes(pose: pose, lid: lid, pupilColor: buddyHole, lidColor: tint)
                .offset(y: -1.1)
            BuddyMouth(mouth: pose.mouth, color: buddyHole, y: 2.4)
            blushMarks
        }
        .offset(y: 0.4)
    }

    /// The wide head: Dot's blob grown sideways, same lighting.
    private var head: some View {
        let shape = RoundedRectangle(cornerRadius: 5.6, style: .continuous)
        return ZStack {
            shape.fill(tint)
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.16)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().fill(.white.opacity(0.22))
                .frame(width: 4.8, height: 2.2)
                .rotationEffect(.degrees(-20))
                .offset(x: -3.0, y: -2.5)
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
        }
        .frame(width: 13.2, height: 9.8)
        .clipShape(shape)
        .offset(y: 0.9)
    }

    /// Three fronds off one cheek, drawn pointing left and mirrored for
    /// the right. `frillSwing` perks the fan or lets it droop; a slow
    /// sway rides on top so the gills always breathe a little.
    private func frills(left: Bool) -> some View {
        let swing = moods.mix(Self.frillSwing)
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let sway = still ? 0 : sin(phase * 2.1 + Double(i) * 0.9 + (left ? 0 : 1.4)) * 2.2
                frill
                    .rotationEffect(.degrees([-34.0, -10.0, 16.0][i] + swing + sway),
                                    anchor: UnitPoint(x: 1, y: 0.5))
            }
        }
        .scaleEffect(x: left ? 1 : -1)
        .offset(x: left ? -6.0 : 6.0, y: -0.7)
    }

    /// One frond: a tapered curve from the head outward.
    private var frill: some View {
        Path { p in
            p.move(to: CGPoint(x: 4.2, y: 1.1))
            p.addQuadCurve(to: CGPoint(x: 0.3, y: 0.9), control: CGPoint(x: 2.0, y: -0.5))
        }
        .stroke(gill, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        .frame(width: 4.4, height: 2.2)
    }

    /// Axolotls look permanently pleased: a soft blush that is always
    /// on, under whatever the trick's blush adds.
    private var blushMarks: some View {
        ZStack {
            Ellipse().fill(gill.opacity(0.20)).frame(width: 2.0, height: 1.1)
                .offset(x: -4.6, y: 1.4)
            Ellipse().fill(gill.opacity(0.20)).frame(width: 2.0, height: 1.1)
                .offset(x: 4.6, y: 1.4)
        }
    }
}

// MARK: - Crab

/// Crab — a wide shell with eyes on stalks and two pincers. The stalks
/// reuse the shared blink; the pincers clap while an ask is up or a hop
/// lands, hold a casual gape on patrol, and shut when it is down or
/// asleep. The pacing walk already waddles; the crab just owns it.
struct CrabBody: View {
    /// Each mood's share of the frame (`BuddyMoodShares`): the parts
    /// shaped by mood swing through a mood change with the pose.
    let moods: BuddyMoodShares
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// How wide the pincers gape: they clap for asks & hops, hold a
    /// casual gape on patrol, and shut tight when down or asleep.
    private var gape: Double {
        moods.mix { Self.gape($0, phase: phase, still: still) }
    }

    static func gape(_ mood: NotchBuddyToy.Mood, phase: TimeInterval, still: Bool) -> Double {
        switch mood {
        case .waving, .celebrating: return still ? 0.7 : 0.45 + 0.4 * sin(phase * 9)
        case .gathering: return still ? 0.5 : 0.35 + 0.25 * sin(phase * 7)
        case .pacing: return 0.3
        case .slumped, .asleep: return 0.06
        }
    }

    /// How high the claws ride: up for asks & hops, dragging on a fail,
    /// tucked in for sleep.
    private var clawLift: Double { moods.mix(Self.clawLift) }

    static func clawLift(_ mood: NotchBuddyToy.Mood) -> Double {
        switch mood {
        case .waving, .celebrating: return 1.0
        case .gathering: return 0.6
        case .pacing: return 0.25
        case .asleep: return -0.2
        case .slumped: return -0.6
        }
    }

    var body: some View {
        ZStack {
            claw(left: true)
            claw(left: false)
            legs(left: true)
            legs(left: false)
            stalks
            shell
            eyeballs
                .offset(y: -5.9)
            BuddyEyes(pose: pose, lid: lid, pupilColor: buddyHole, lidColor: tint,
                      pupilScale: 0.8)
                .offset(y: -5.9)
            BuddyMouth(mouth: pose.mouth, color: buddyHole, y: 2.2)
        }
        .offset(y: 0.6)
    }

    /// The carapace: a wide ellipse, lit like everyone else.
    private var shell: some View {
        let shape = Ellipse()
        return ZStack {
            shape.fill(tint)
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().fill(.white.opacity(0.22))
                .frame(width: 4.8, height: 1.8)
                .rotationEffect(.degrees(-18))
                .offset(x: -2.6, y: -1.8)
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.55)
        }
        .frame(width: 13.4, height: 8.4)
        .clipShape(shape)
        .offset(y: 1.8)
    }

    /// The eye stalks, drawn behind the shell so they grow out of it;
    /// the eyes themselves are the shared pair parked on the tips.
    private var stalks: some View {
        ZStack {
            Capsule().fill(tint).frame(width: 1.0, height: 3.4)
                .rotationEffect(.degrees(-7))
                .offset(x: -2.2, y: -3.6)
            Capsule().fill(tint).frame(width: 1.0, height: 3.4)
                .rotationEffect(.degrees(7))
                .offset(x: 2.2, y: -3.6)
        }
    }

    /// The eyes' own balls on the stalk tips — pale, so the pupils read
    /// against the pill instead of vanishing into it. Shut, they are
    /// the shell's colour, and the lid line is what shows.
    private var eyeballs: some View {
        HStack(spacing: 1.2) {
            eyeball
            eyeball
        }
    }

    private var eyeball: some View {
        Circle()
            .fill(pose.eyesClosed ? AnyShapeStyle(tint) : AnyShapeStyle(Color(white: 0.96)))
            .overlay(Circle().strokeBorder(tint.mix(with: .black, by: 0.25), lineWidth: 0.4))
            .frame(width: 3.2, height: 3.2)
    }

    /// Three little legs a side, peeking under the shell's rim.
    private func legs(left: Bool) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: 1.9, height: 0.85)
                    .rotationEffect(.degrees([-16.0, -30.0, -44.0][i]))
                    .offset(x: [3.6, 4.8, 5.7][i], y: [5.5, 4.9, 4.2][i])
            }
        }
        .scaleEffect(x: left ? -1 : 1)
    }

    /// One claw, drawn pointing right and mirrored for the left: an arm
    /// stub, a round palm and two capsule fingers hinged open by `gape`.
    /// `clawLift` rotates the whole arm up at the shoulder and carries
    /// it higher; mirroring keeps "up" up on both sides.
    private func claw(left: Bool) -> some View {
        let side: Double = left ? -1 : 1
        return ZStack {
            Capsule().fill(tint)
                .frame(width: 3.0, height: 1.2)
                .rotationEffect(.degrees(-35))
                .offset(x: -1.7, y: 0.9)
            Circle()
                .fill(tint)
                .overlay(Circle().fill(LinearGradient(
                    colors: [.white.opacity(0.16), .clear, .black.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.45))
                .frame(width: 3.6, height: 3.4)
            finger
                .rotationEffect(.degrees(-(16 + gape * 24)), anchor: .leading)
                .offset(x: 1.4, y: -0.7)
            finger
                .rotationEffect(.degrees(12 + gape * 22), anchor: .leading)
                .offset(x: 1.4, y: 0.8)
        }
        .rotationEffect(.degrees(-4 - clawLift * 26))
        .scaleEffect(x: side)
        .offset(x: side * 6.9, y: 1.2 - clawLift * 2.4)
    }

    /// One pincer finger: a stubby capsule is all a claw is at this size.
    private var finger: some View {
        Capsule().fill(tint)
            .frame(width: 3.0, height: 1.25)
    }
}

// MARK: - Mushroom

/// Mushroom — a spotted cap nodding on a pale stalk. Permanently drowsy:
/// the shared lids ride heavier here, the cap sways on a slow clock and
/// keels in the slump. Features are dark reads on the stalk, like the
/// ghost's — the stalk is pale whatever accent the cap wears.
struct MushroomBody: View {
    /// Each mood's share of the frame (`BuddyMoodShares`): the parts
    /// shaped by mood swing through a mood change with the pose.
    let moods: BuddyMoodShares
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// The stalk's cream — pale whatever the tint; the cap wears that.
    private var stalk: Color { Color(red: 0.93, green: 0.88, blue: 0.80) }
    private var feature: Color { Color(white: 0.12).opacity(0.85) }

    /// Always half-asleep: a resting lid on top of the skeleton's,
    /// which sleep's own shut eyes replace.
    private var drowsy: Double {
        min(1, lid + 0.18 * (1 - moods.share(of: .asleep)))
    }

    /// The cap's slow nod; the slump keels it a further 7°.
    private var capNod: Double {
        (still ? 0 : sin(phase * 1.4) * 1.6) + 7 * moods.share(of: .slumped)
    }

    var body: some View {
        ZStack {
            stalkBody
            BuddyEyes(pose: pose, lid: drowsy, pupilColor: feature, lidColor: stalk,
                      pupilScale: 0.85)
                .offset(y: 0.9)
            BuddyMouth(mouth: pose.mouth, color: feature.opacity(0.9), y: 3.6)
            cap
        }
        .offset(y: 0.2)
    }

    /// The stalk: a soft rounded peg under the cap.
    private var stalkBody: some View {
        let shape = RoundedRectangle(cornerRadius: 3.0, style: .continuous)
        return ZStack {
            shape.fill(stalk)
            shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.10)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
        }
        .frame(width: 6.8, height: 7.0)
        .clipShape(shape)
        .offset(y: 2.0)
    }

    /// The cap: a shallow dome with a slight under-lip, tinted, with
    /// three pale spots. It nods on its own clock — a mushroom's whole
    /// head is the cap.
    private var cap: some View {
        let dome = Path { p in
            // Frame 14×6.4: an arc over the top, a soft lip underneath.
            p.move(to: CGPoint(x: 0.4, y: 5.6))
            p.addQuadCurve(to: CGPoint(x: 7.0, y: -0.6), control: CGPoint(x: 0.6, y: 0.4))
            p.addQuadCurve(to: CGPoint(x: 13.6, y: 5.6), control: CGPoint(x: 13.4, y: 0.4))
            p.addQuadCurve(to: CGPoint(x: 0.4, y: 5.6), control: CGPoint(x: 7.0, y: 6.8))
        }
        return ZStack {
            dome.fill(tint)
            dome.fill(LinearGradient(colors: [.white.opacity(0.20), .clear, .black.opacity(0.14)],
                                     startPoint: .top, endPoint: .bottom))
            dome.stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.55))
            spot(x: -3.6, y: -1.6, d: 1.7)
            spot(x: 0.4, y: -2.7, d: 1.3)
            spot(x: 3.9, y: -1.3, d: 1.9)
        }
        .frame(width: 14, height: 6.4)
        .rotationEffect(.degrees(capNod), anchor: .bottom)
        .offset(y: -3.3)
    }

    private func spot(x: Double, y: Double, d: Double) -> some View {
        Ellipse().fill(.white.opacity(0.5))
            .frame(width: d, height: d * 0.8)
            .offset(x: x, y: y)
    }
}

// MARK: - UFO

/// UFO — a saucer that never lands (the skeleton keeps it hovering):
/// a metal disc with rim lights that cycle while it watches, a glass
/// dome with a small pilot inside — almond eyes that track and blink —
/// and a beam that brightens while an ask is up, as if it means to lift
/// the question clean out of the terminal.
struct UFOBody: View {
    /// Each mood's share of the frame (`BuddyMoodShares`): the parts
    /// shaped by mood swing through a mood change with the pose.
    let moods: BuddyMoodShares
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// The pilot's green — stays green whatever accent the saucer wears.
    private var alien: Color { Color(red: 0.45, green: 0.85, blue: 0.42) }

    /// Beam strength by mood: bright while it wants you, a night-light
    /// otherwise, nearly off while it sleeps.
    private var beam: Double { moods.mix(Self.beam) }

    static func beam(_ mood: NotchBuddyToy.Mood) -> Double {
        switch mood {
        case .waving: return 0.50
        case .celebrating: return 0.45
        case .gathering: return 0.25
        case .pacing: return 0.16
        case .slumped: return 0.10
        case .asleep: return 0.05
        }
    }

    var body: some View {
        ZStack {
            beamView
            pilot
            dome
            saucer
        }
        .offset(y: -0.6)
    }

    /// The tractor beam: a warm cone off the saucer's belly, fading out
    /// before it ever reaches the ground.
    private var beamView: some View {
        let flicker = still ? 0.0 : sin(phase * 11) * 0.04 + sin(phase * 4.3) * 0.03
        return Path { p in
            // Frame 10×7: narrow at the saucer, spreading as it falls.
            p.move(to: CGPoint(x: 3.4, y: 0))
            p.addLine(to: CGPoint(x: 6.6, y: 0))
            p.addLine(to: CGPoint(x: 9.6, y: 6.6))
            p.addLine(to: CGPoint(x: 0.4, y: 6.6))
            p.closeSubpath()
        }
        .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.95, blue: 0.6).opacity(max(0, beam + flicker)),
                                      Color(red: 1.0, green: 0.95, blue: 0.6).opacity(0)],
                             startPoint: .top, endPoint: .bottom))
        .frame(width: 10, height: 7)
        .offset(y: 2.6)
    }

    /// The metal disc: the robot's brushed gradient, a tint wash, a
    /// sheen along the top edge, and three rim lights cycling a slow
    /// chase.
    private var saucer: some View {
        let disc = Ellipse()
        return ZStack {
            disc.fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.52)],
                                     startPoint: .top, endPoint: .bottom))
            disc.fill(tint.opacity(0.28))
            Ellipse().fill(.white.opacity(0.3))
                .frame(width: 6, height: 1.4)
                .offset(y: -1.4)
            disc.strokeBorder(.black.opacity(0.22), lineWidth: 0.5)
            HStack(spacing: 3.2) {
                rimLight(0)
                rimLight(1)
                rimLight(2)
            }
            .offset(y: 0.6)
        }
        .frame(width: 14.2, height: 4.8)
        .clipShape(disc)
        .offset(y: 2.0)
    }

    /// One rim pip: the chase runs one light at a time, parked on the
    /// first when still.
    private func rimLight(_ i: Int) -> some View {
        let on = still ? i == 0 : (Int(phase * 3) + i) % 3 == 0
        return Circle()
            .fill(on ? Color(red: 1.0, green: 0.85, blue: 0.35) : Color(white: 0.35))
            .frame(width: 1.5, height: 1.5)
            .shadow(color: on ? .yellow.opacity(0.8) : .clear, radius: 0.6)
    }

    /// The dome: a half-ellipse of glass over the pilot.
    private var dome: some View {
        let glass = Path { p in
            // Frame 7.5×4.6, open at the bottom.
            p.move(to: CGPoint(x: 0.2, y: 4.4))
            p.addQuadCurve(to: CGPoint(x: 3.75, y: -0.8), control: CGPoint(x: 0.4, y: 0.2))
            p.addQuadCurve(to: CGPoint(x: 7.3, y: 4.4), control: CGPoint(x: 7.1, y: 0.2))
            p.closeSubpath()
        }
        return ZStack {
            glass.fill(.white.opacity(0.10))
            glass.fill(LinearGradient(colors: [.white.opacity(0.25), .clear],
                                      startPoint: .topLeading, endPoint: .center))
            glass.stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 0.5))
        }
        .frame(width: 7.5, height: 4.6)
        .offset(y: -1.7)
    }

    /// The pilot: a small green head with two almond eyes that drift
    /// with `look`, carry a catchlight, and shutter under the same lid
    /// trick everyone else uses. Its mouth is the shared set, small.
    private var pilot: some View {
        ZStack {
            Ellipse().fill(alien)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.25), .clear, .black.opacity(0.15)],
                                          startPoint: .top, endPoint: .bottom))
            HStack(spacing: 1.1) {
                alienEye(mirrored: false)
                alienEye(mirrored: true)
            }
            .offset(y: -0.5)
            BuddyMouth(mouth: pose.mouth, color: Color(white: 0.08).opacity(0.75), y: 1.6)
        }
        .frame(width: 5.4, height: 4.8)
        .clipShape(Ellipse())
        .offset(y: -0.8)
    }

    /// One almond eye: tilted dark oval, a catchlight glued up-left,
    /// the head's own colour sliding down as the lid. Asleep it is a
    /// thin shut line.
    private func alienEye(mirrored: Bool) -> some View {
        ZStack {
            if pose.eyesClosed {
                Capsule().fill(Color(white: 0.08)).frame(width: 1.7, height: 0.5)
            } else {
                Ellipse().fill(Color(white: 0.07))
                    .frame(width: 1.5, height: 2.1)
                    .rotationEffect(.degrees(mirrored ? 18 : -18))
                    .offset(x: pose.look.width * 0.6, y: pose.look.height * 0.5)
                Circle().fill(.white.opacity(0.7))
                    .frame(width: 0.45, height: 0.45)
                    .offset(x: pose.look.width * 0.6 - 0.3, y: pose.look.height * 0.5 - 0.55)
                if lid > 0.01 {
                    let lidHeight = 0.4 + 2.6 * lid
                    Capsule().fill(alien)
                        .frame(width: 2.2, height: lidHeight)
                        .offset(y: -1.3 + lidHeight / 2)
                }
            }
        }
        .frame(width: 2.0, height: 2.8)
    }
}
