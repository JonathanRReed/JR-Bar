import Foundation

/// What the linked Dot is for (`dot_role` in the settings document, echoed
/// as `lights.surfaces.dot.role`; `docs/CORE-PROTOCOL.md`, "The Dot's
/// role"). An unknown value reads as `extend`, exactly as the daemon does.
public enum DotRole: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// The strip's own program, phase-locked, rendered for two LEDs.
    case extend
    /// A designated attention beacon: dark until something needs the person.
    case asks
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
        case .extend: return "Extend"
        case .asks: return "Ask beacon"
        case .status: return "Status"
        }
    }

    /// One sentence under the picker: what this role actually does, not
    /// what it is called.
    public var explanation: String {
        switch self {
        case .extend:
            return "Plays the strip's animation across both, phase-locked: the eight LEDs are folded into two bands, so a chase still sweeps and a solid colour stays solid."
        case .asks:
            return "Dark until something needs you: amber for a permission request, red for a blocked error. A glance at the Dot alone answers \"do they need me?\"."
        case .status:
            return "Its own two-LED status code, the way an unlinked Dot has always rendered. Nothing else drives it."
        }
    }

    /// Whether `dot_role_include_completions` means anything for this role.
    public var usesCompletions: Bool { self == .asks }
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
    /// fallback for daemons that predate it. `linkedSkewMs` /
    /// `linkedSkewFresh` carry the measured gap, shown only while the
    /// measurement is still worth quoting.
    public static func make(chosen: DotRole, includeCompletions: Bool, linked: Bool = true,
                            link: CoreDotLink? = nil, linkedSkewMs: Double? = nil,
                            linkedSkewFresh: Bool = false,
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
                                      detail: "No strip is connected. Plug in the SidePulse, or pick Ask beacon or Status, which need no strip.",
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
        // ever names a genuine transition, never a steady state.
        let settling = (active ?? .status) != chosen

        var headline: String
        var detail: String?
        switch active {
        case .extend?:
            headline = "Extending the strip"
            detail = "Two bands, LEDs 0–3 and 4–7, each showing its band's brightest lit colour."
            if linkedSkewFresh, let skew = linkedSkewMs {
                detail! += " In step: the Dot restarts \(Int(skew.rounded())) ms after the strip."
            }
        case .asks?:
            let state = beaconState(why: dot.why, program: dot.program)
            headline = "Beacon: \(state.word)"
            detail = state.detail
            if !includeCompletions, state.isCompletion {
                detail = "A finished run nobody has looked at; turn on \"Also glow for finished runs\" to see it here."
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
            detail = "The core has not picked this up yet."
        }
        return DotRoleReadout(chosen: chosen, active: active, rendersItself: rendersItself,
                              headline: headline, detail: detail, settling: settling)
    }

    /// `dot_link.state == "no_dot"`, or no `dot` surface at all.
    private static func missing(chosen: DotRole) -> DotRoleReadout {
        DotRoleReadout(chosen: chosen, active: nil, rendersItself: false,
                       headline: "No Dot in the lights frame",
                       detail: "The core reports nothing for the Dot; plug it in or link it to see this.",
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
