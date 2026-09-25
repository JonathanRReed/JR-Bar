import Foundation

/// What the linked Dot is for (`dot_role` in the settings document, echoed
/// as `lights.surfaces.dot.role`; `docs/CORE-PROTOCOL.md`, "The Dot's
/// role"). An unknown value reads as `extend`, exactly as the daemon does.
public enum DotRole: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// The strip's own program, phase-locked, rendered for two LEDs.
    case extend
    /// A designated attention beacon: dark until something needs the person.
    case asks
    /// A busylight: steady red while the person is on a call
    /// (`state.presence`, fed by the app's mic and camera reading), and
    /// exactly the `asks` beacon the rest of the time. The daemon also
    /// holds it red for a report's `meeting_until`, which the app does not
    /// send yet — the readout names that case for when a reporter does.
    case call
    /// The Dot renders its own two-LED semantic display; nothing drives it
    /// but the Dot, so `lights.surfaces.dot.role` is absent.
    case status

    public var id: String { rawValue }

    public static func parse(_ raw: String?) -> DotRole {
        guard let raw, let role = DotRole(rawValue: raw) else { return .extend }
        return role
    }

    public var label: String {
        switch self {
        case .extend: return "Extend the strip"
        case .asks: return "Alert beacon"
        case .call: return "Call light"
        case .status: return "On its own"
        }
    }

    /// One sentence under the picker: what this role actually does, not
    /// what it is called.
    public var explanation: String {
        switch self {
        case .extend:
            return "Carries the strip's light onto the Dot, timed to the strip's own start and the Dot's measured clock. The Look below says how: moving light runs on through the Dot, or the strip folds into its two LEDs."
        case .asks:
            return "Dark until something needs you: amber for a permission request, red for a blocked error. A glance at the Dot alone answers \"do they need me?\"."
        case .call:
            return "Steady red while a call has the mic or camera — held, never breathed, since it sits in view of the camera. Between calls it is the alert beacon."
        case .status:
            return "Its own two-LED status code, the way an unlinked Dot has always rendered. Nothing else drives it."
        }
    }

    /// Whether `dot_role_include_completions` means anything for this role:
    /// the beacon, and the call light between calls (it is the beacon then).
    public var usesCompletions: Bool { self == .asks || self == .call }
}

/// The live reading beside the picker: what the daemon says the Dot is
/// doing right now, from `lights.surfaces.dot` (the `role` it echoes and
/// the `why` the role decides). Pure, so the Settings page has no logic.
public struct DotRoleReadout: Equatable, Sendable {
    /// `dot_role` in the settings document (what the picker shows).
    public var chosen: DotRole
    /// `lights.surfaces.dot.role`; nil when the Dot renders its own display
    /// (or when no `lights` frame has arrived).
    public var active: DotRole?
    /// True when a `dot` surface is in the frame with no `role` on it: the
    /// Dot is driving itself.
    public var rendersItself: Bool
    /// "Extending the strip", "Beacon: amber — something needs you".
    public var headline: String
    /// A second line when there is one to add.
    public var detail: String?
    /// The chosen role has not reached the lights frame yet.
    public var settling: Bool
    /// True when the role is not in effect at all: `devices_linked` is off,
    /// so the daemon never plans the Dot and it renders itself.
    public var unlinked: Bool = false
    /// True while a shut lid has the daemon play an `extend` Dot as the
    /// alert beacon (`auto:lid_closed`): the role working, not settling.
    public var lidBeacon: Bool = false

    public init(chosen: DotRole, active: DotRole?, rendersItself: Bool, headline: String,
                detail: String? = nil, settling: Bool = false) {
        self.chosen = chosen
        self.active = active
        self.rendersItself = rendersItself
        self.headline = headline
        self.detail = detail
        self.settling = settling
    }

    /// `chosen` from the settings document, everything else from the
    /// `dot` surface of the newest `lights` frame (nil when there is none).
    /// `link` is the daemon's `dot_link` word — when present it is the
    /// authority and `linked` (the `devices_linked` setting) is only the
    /// fallback for daemons that predate it. The timing line comes from
    /// the link's own measurement (`phase_error_ms`, the Dot's clock rate),
    /// never the gap between two writes: "in step" from one write's gap
    /// stopped being true within a second. `lidClosed` is the
    /// daemon's lid reading (`state.power.closed_lid.lid_closed`): with it
    /// shut, an `extend` Dot playing the beacon is the daemon's rule for a
    /// lid that hides the strip and the band, not a choice still in flight.
    public static func make(chosen: DotRole, includeCompletions: Bool, linked: Bool = true,
                            link: CoreDotLink? = nil,
                            lidClosed: Bool = false, now: Date = Date(),
                            dot: CoreLightSurface?) -> DotRoleReadout {
        let active = dot?.role.map(DotRole.parse)
        let rendersItself = dot != nil && dot?.role == nil
        // The daemon's own link word answers first: it knows about states
        // the settings document cannot express (no strip to extend, a
        // failed linked write).
        if let link {
            switch link.state {
            case "off":
                return unlinked(chosen: chosen, active: active, rendersItself: rendersItself)
            case "no_dot":
                return missing(chosen: chosen)
            case "no_strip":
                return DotRoleReadout(chosen: chosen, active: active, rendersItself: rendersItself,
                                      headline: "Nothing to extend",
                                      detail: "No strip is connected. Plug in the SidePulse, or pick Alert beacon or On its own, which need no strip.",
                                      settling: false)
            case "failed":
                return DotRoleReadout(chosen: chosen, active: active, rendersItself: rendersItself,
                                      headline: "The Dot's last linked write failed",
                                      detail: link.error, settling: false)
            default:
                break  // linked / beacon / solo: the role mapping below applies
            }
        }
        guard let dot else { return missing(chosen: chosen) }
        if !linked { return unlinked(chosen: chosen, active: active, rendersItself: rendersItself) }
        // `status` is exactly the case the daemon reports by leaving `role`
        // off, so it is settled, not settling; "not picked up yet" only
        // ever names a genuine transition, never a steady state. A shut
        // lid's beacon standing in for `extend` is a steady state too:
        // the daemon's `auto:lid_closed`, undone when the lid opens.
        let lidBeacon = lidClosed && chosen == .extend && active == .asks
        let settling = !lidBeacon && (active ?? .status) != chosen

        var headline: String
        var detail: String?
        switch active {
        case .extend?:
            let continuing = link?.rung == "continue"
            headline = continuing ? "Continuing the strip" : "Extending the strip"
            detail = Self.lookSentence(rung: link?.rung)
            if let timing = Self.timingSentence(link: link, now: now) {
                detail = (detail ?? "") + " " + timing
            }
        case .asks?:
            let state = beaconState(why: dot.why, program: dot.program)
            headline = "Beacon: \(state.word)"
            detail = state.detail
            if !includeCompletions, state.isCompletion {
                detail = "A finished run nobody has looked at; turn on \"Also glow for finished runs\" to see it here."
            }
            if lidBeacon {
                detail = "The lid is shut, so the strip and the band are out of sight: the Dot is the alert beacon until it opens."
            }
        case .call?:
            switch dot.why?.lowercased() {
            case "on_call":
                headline = "Call light: steady red, on a call"
                detail = "Held still in view of the camera. It goes back to the alert beacon when the call ends."
            case "in_meeting":
                headline = "Call light: steady red, in a meeting"
                detail = "For the whole of the meeting on your calendar; a live call names itself first."
            default:
                // Between calls the call light is the beacon, word for word.
                let state = beaconState(why: dot.why, program: dot.program)
                headline = "Beacon: \(state.word)"
                detail = [state.detail, "Steady red once a call has the mic or camera."]
                    .compactMap { $0 }.joined(separator: " ")
                if !includeCompletions, state.isCompletion {
                    detail = "A finished run nobody has looked at; turn on \"Also glow for finished runs\" to see it here."
                }
            }
        case .status?:
            // The daemon is not expected to send this, but a role it does
            // send is what the app reports.
            headline = "Its own two-LED status code"
        case nil:
            headline = "Its own two-LED status code"
            detail = "Nothing is driving the Dot but the Dot."
        }
        if settling {
            detail = "The monitor has not picked this up yet."
        }
        var readout = DotRoleReadout(chosen: chosen, active: active, rendersItself: rendersItself,
                                     headline: headline, detail: detail, settling: settling)
        readout.lidBeacon = lidBeacon
        return readout
    }

    /// What the two LEDs show, by the period lock's rung: the strip folded
    /// into two bands, or the fallbacks that keep the strip's period when
    /// the fold would flash at two LEDs.
    static func lookSentence(rung: String?) -> String {
        switch rung {
        case "continue":
            return "The light runs off the end of the strip into the Dot, as if the strip went on."
        case "average", "soft":
            return "Two bands, LEDs 0–3 and 4–7, each showing its band's average: the brightest fold would flash on two LEDs."
        case "static":
            return "A still colour, the loop's average: this animation flashes when folded onto two LEDs."
        default:
            return "Two bands, LEDs 0–3 and 4–7, each showing its band's brightest lit colour."
        }
    }

    /// The honest timing line, from the daemon's own measurement: how far
    /// the Dot is from the strip right now and what its clock is doing.
    /// nil before the first timed write -- nothing is claimed unmeasured.
    static func timingSentence(link: CoreDotLink?, now: Date) -> String? {
        guard let link else { return nil }
        if let until = link.checkUntil, until > now.timeIntervalSince1970 {
            return "Checking sync: both flash white every 2 seconds. They should read as one flash."
        }
        guard let error = link.phaseErrorMs else { return nil }
        let off = Int(abs(error).rounded())
        if link.clockSource == "off" {
            return "Started on the strip's beat; clock correction is off, so it drifts between writes."
        }
        let tolerance = link.toleranceMs ?? 40
        if abs(error) > tolerance {
            return "Re-syncing: \(off) ms off the strip."
        }
        var sentence = "Within \(off) ms of the strip"
        if link.clockSource == "frozen" {
            return sentence + "; its clock can't be read fresh, so it is re-synced every minute."
        }
        if let rate = link.clockRate, abs(rate - 1) >= 0.001 {
            let percent = String(format: "%.1f", abs(rate - 1) * 100)
            let way = rate < 1 ? "slow" : "fast"
            sentence += "; the Dot's clock runs \(percent)% \(way), corrected."
        } else {
            sentence += "."
        }
        return sentence
    }

    /// `dot_link.state == "no_dot"`, or no `dot` surface at all.
    private static func missing(chosen: DotRole) -> DotRoleReadout {
        DotRoleReadout(chosen: chosen, active: nil, rendersItself: false,
                       headline: "No Dot in the lights frame",
                       detail: "The monitor reports nothing for the Dot; plug it in or link it to see this.",
                       settling: false)
    }

    /// `dot_link.state == "off"`, or `devices_linked` off on a daemon too
    /// old to send `dot_link`: no role is in effect whatever the key says.
    private static func unlinked(chosen: DotRole, active: DotRole?, rendersItself: Bool) -> DotRoleReadout {
        var readout = DotRoleReadout(chosen: chosen, active: active, rendersItself: rendersItself,
                                     headline: "Its own two-LED status code",
                                     detail: "Pro and Dot are not linked, so no role is in effect.",
                                     settling: false)
        readout.unlinked = true
        return readout
    }

    /// The beacon's four states, from the `why` the role decides (the
    /// program is the tie-breaker when the daemon sends no `why`).
    static func beaconState(why: String?, program: String) -> (word: String, detail: String?, isCompletion: Bool) {
        switch LightWhy.parse(why) {
        case .waiting:
            return ("amber, something needs you", "A permission request is open; the breath tightens with the escalation stage.", false)
        case .failed:
            return ("red, something is blocked", "A failed or blocked run outranks a waiting one.", false)
        case .completed:
            return ("green, a finished run nobody has seen", "The slowest cadence, and only while completions are included.", true)
        default:
            let dark = program.isEmpty || program.lowercased().contains("off")
            if dark {
                return ("dark, nothing needs you", "The device's own resting glow applies.", false)
            }
            return ("lit", nil, false)
        }
    }
}
