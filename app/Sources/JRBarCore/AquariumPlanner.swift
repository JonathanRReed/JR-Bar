import Foundation

/// W13's semantic layer between a session and its fish. `AquariumModel`
/// decides *where* a fish is; the planner decides *what it's doing* —
/// one `FishPlan` per session per reduce, pure and deterministic, so a
/// fixture run and the live render never disagree (T54).
///
/// Honesty rules baked in:
/// * An action is only as specific as the wire allows — `tool` names a
///   real hook's tool, so "forage" only ever follows an observed read.
///   No tool name means generic station work, never an invented one.
/// * Overlays are evidence, not cosmetics: a pearl is a real
///   unreviewed completion (review axis), a buoy a real blocked/failed
///   state, a question bubble a real ask. Nothing here routes a
///   command — clicking a fish never answers anything.
/// * Stale beats precise: a `stale` row or a `freshness` axis that
///   isn't "live" stops claiming a tool-level action — the fish drifts
///   neutrally (AQ23) rather than performing an old fact as current.
public struct FishPlan: Equatable, Sendable {
    /// The base swim — same vocabulary as `FishState`, carried here so
    /// the plan is self-describing for fixtures and the inspector.
    public var state: FishState
    /// The semantic action (AQ01–AQ24's "what it's doing") — finer than
    /// the state: a swimming fish might be patrolling (working, no
    /// detail) or foraging (an observed Read just happened).
    public var action: FishAction
    /// The one attention overlay — highest-evidence wins; see
    /// `overlayPrecedence`. `nil` means nothing is asking for notice.
    public var overlay: FishOverlay?
    /// AQ13's parallel markers: sub-agent count when a working main
    /// session has schooling workers. Zero means none drawn.
    public var parallelMarkers: Int
    /// What the plan read to decide — one line for the inspector so a
    /// fixture and a live fish cite the same evidence (T54).
    public var evidence: String

    public init(state: FishState, action: FishAction, overlay: FishOverlay?,
                parallelMarkers: Int, evidence: String) {
        self.state = state
        self.action = action
        self.overlay = overlay
        self.parallelMarkers = parallelMarkers
        self.evidence = evidence
    }
}

/// The AQ01–AQ24 actions a session can drive. Every case is reachable
/// only through observed wire facts — the enum is the contract fixtures
/// enumerate, so a claimed action is never wider than its evidence.
public enum FishAction: String, Equatable, Sendable, CaseIterable {
    /// AQ01 — first observed: the fish swims in (`enteredAt` drives it).
    case enter
    /// AQ02 — explicitly idle/ready: rest under cover.
    case idleRest
    /// AQ03 — working, detail unavailable: purposeful patrol, no
    /// invented tool or step.
    case patrol
    /// AQ04 — reported processing boundary (`long_task_progress`,
    /// `thinking`): an attentive hover-arc, phase timing only.
    case attentiveHover
    /// AQ05 — generic tool started: visit a neutral work station.
    case feedStation
    /// AQ06 — observed read/retrieval tool: forage at a document reef.
    case forage
    /// AQ07 — observed search/browse tool: explore several points.
    case explore
    /// AQ08 — observed edit/patch tool: tend a structure.
    case tendStones
    /// AQ09 — observed shell command: work at a current-driven object.
    case currentWork
    /// AQ10 — observed test/build in progress: inspect a structure.
    case inspectStructure
    /// AQ11 — test/build result arrived: a result-coloured bubble.
    /// Distinct from AQ10 — a failed result inside a completed turn is
    /// still a failed result.
    case resultBubble
    /// AQ12 — observed MCP/service call: visit a service station.
    case serviceVisit
    /// AQ15 — a verified delegation event: a token passes between
    /// related fish. Only a real `delegation`/`handoff` event sets it —
    /// proximity never implies a handoff.
    case tokenPass
    /// AQ16 — waiting for input: front glass + question cue.
    case surfaceQuestion
    /// AQ17 — permission/approval ask: attention buoy with a lock cue.
    case attentionBuoy
    /// AQ20 — blocked/failed: hold beside a warning buoy, visible —
    /// never injured, dead, or hidden.
    case warningBuoy
    /// AQ21 — completed awaiting review: deposit a pearl.
    case pearlDeposit
    /// AQ22 — acknowledged/reviewed: return to normal, pearl cleared.
    case returnNormal
    /// AQ23 — stale/disconnected observation: neutral uncertain drift;
    /// no precise activity is claimed.
    case uncertainDrift
    /// AQ24 — unconfirmed process exit: inactive/history presentation,
    /// kept distinct from completed and failed.
    case inactiveDrift
}

/// Attention overlays — one at a time, ordered by evidence strength.
public enum FishOverlay: String, Equatable, Sendable, CaseIterable {
    /// AQ17 — a permission/approval ask rides a lock buoy.
    case attentionBuoy
    /// AQ20 — blocked/failed rides a warning buoy.
    case warningBuoy
    /// AQ16 — a non-permission ask or plain waiting rides a bubble.
    case questionBubble
    /// AQ21 — a completed run nobody has reviewed holds a pearl.
    case pearl
    /// AQ23 — stale observation gets a neutral marker — only when no
    /// stronger evidence (ask/failure) already speaks.
    case staleMarker
}

public enum AquariumPlanner {
    /// A tool event older than this doesn't drive a station action —
    /// the last hook's word is history, not something happening now.
    public static let toolEventLife: TimeInterval = 45

    /// The session's plan for `now`. Reads the same fields the panel's
    /// reduce reads; `axes` is the roster's separated record, carried on
    /// the session itself (`CoreSession.axes`) — the tank passes it
    /// through in `AquariumModel.fishFor`. A caller without it may pass
    /// nil: review/freshness overlays then degrade to what the session
    /// row itself says (`stale`, ask, lifecycle) rather than inventing
    /// an axis.
    public static func plan(for session: CoreSession,
                            axes: CoreSessionAxes? = nil,
                            now: Date) -> FishPlan {
        let activity = SessionActivity.reduce(session)
        let overlay = self.overlay(for: session, axes: axes, activity: activity)
        let action = self.action(for: session, axes: axes, activity: activity, now: now)
        let markers = parallelMarkers(for: session, activity: activity)
        let evidence = evidenceLine(for: session, axes: axes, action: action)
        return FishPlan(state: state(for: activity, action: action),
                        action: action, overlay: overlay,
                        parallelMarkers: markers, evidence: evidence)
    }

    /// AQ13 — parallel work markers: a working main session's schooling
    /// workers draw as markers around it. Idle/done workers don't add
    /// markers — the count is live evidence, not a decoration budget.
    static func parallelMarkers(for session: CoreSession,
                                activity: SessionActivity) -> Int {
        guard activity == .working, session.kind == "main",
              session.workers > 1 else { return 0 }
        return min(session.workers, 6)
    }

    /// Overlay precedence: a live failure outranks a permission buoy
    /// (the run is over, the buoy would be a stale ask); a permission
    /// ask outranks a plain question; an unreviewed completion outranks
    /// a stale marker — the review axis is fresher evidence than the
    /// freshness axis's doubt.
    static func overlay(for session: CoreSession, axes: CoreSessionAxes?,
                        activity: SessionActivity) -> FishOverlay? {
        if activity == .failed { return .warningBuoy }
        if let ask = session.ask {
            return ask.kind == "permission" ? .attentionBuoy : .questionBubble
        }
        if activity == .waiting { return .questionBubble }
        if activity == .done, axes?.review != "reviewed" {
            return .pearl
        }
        if session.stale || (axes?.freshness != nil
                             && axes?.freshness != "live") {
            return .staleMarker
        }
        return nil
    }

    /// The semantic action. Order matters: terminal states first
    /// (AQ24/AQ20/AQ21), attention next (AQ17/AQ16), then the tool
    /// detail (AQ05–AQ12) only while the observation is live, then the
    /// base swim (AQ02–AQ04) and finally the first-observed entry
    /// (AQ01, when nothing else has spoken yet).
    static func action(for session: CoreSession, axes: CoreSessionAxes?,
                       activity: SessionActivity, now: Date) -> FishAction {
        // A delegation event wins over everything else live — AQ15 is
        /// an exchange, not a state, and only a real event names it.
        if let event = session.event?.lowercased(),
           event == "delegation" || event == "handoff" || event == "subagent_stop" {
            return .tokenPass
        }
        switch activity {
        case .ended:
            return .inactiveDrift        // AQ24
        case .failed:
            return .warningBuoy          // AQ20
        case .done:
            // AQ22's return-to-normal is the same drift either way;
            // the *pearl* is the overlay, not a different swim.
            return axes?.review == "reviewed" ? .returnNormal : .pearlDeposit
        case .waiting:
            // AQ17 vs AQ16 by the ask's kind, not its text.
            return session.ask?.kind == "permission" ? .attentionBuoy : .surfaceQuestion
        case .idle:
            return .idleRest             // AQ02
        case .working:
            break                        // tool detail below
        }

        // AQ23 — a stale observation claims no precise activity even
        // when the session still reads "working".
        if session.stale || (axes?.freshness != nil
                             && axes?.freshness != "live") {
            return .uncertainDrift
        }

        // AQ05–AQ12 — a live tool event names a station; an old or
        // missing one leaves the base swim.
        if let toolAction = toolAction(for: session, now: now) {
            return toolAction
        }
        // AQ11 — a test/build tool that just finished: `PostToolUse` on
        // a known test/build tool while `tool_running` has ended is
        // the result arriving — a brief result marker, not a station.
        if let result = resultAction(for: session, now: now) {
            return result
        }
        let mode = session.mode?.lowercased() ?? ""
        if mode == "long_task_progress" || mode == "thinking" {
            return .attentiveHover       // AQ04
        }
        return .patrol                   // AQ03
    }

    /// AQ05–AQ12: map the observed tool name to a station. Only the
    /// *current* tool counts — `updatedAt` past `toolEventLife` means
    /// the event is history, and a tool the table doesn't know falls
    /// back to the generic station rather than guessing.
    static func toolAction(for session: CoreSession, now: Date) -> FishAction? {
        guard session.mode?.lowercased() == "tool_running",
              let tool = session.tool?.lowercased() else { return nil }
        if let updated = session.updatedAt,
           now.timeIntervalSince1970 - updated > toolEventLife {
            return nil
        }
        switch tool {
        case "read", "glob", "notebookread":
            return .forage               // AQ06
        case "grep", "websearch", "webfetch", "browser":
            return .explore              // AQ07
        case "edit", "write", "notebookedit", "multiedit", "patch":
            return .tendStones           // AQ08
        case "bash", "shell", "exec":
            return .currentWork          // AQ09
        case "test", "pytest", "swiftbuild", "swifttest", "build":
            return .inspectStructure     // AQ10
        case "mcp", "mcp_call_tool":
            return .serviceVisit         // AQ12
        default:
            if tool.hasPrefix("mcp__") || tool.hasPrefix("mcp.") {
                return .serviceVisit     // AQ12 — server-prefixed calls
            }
            return .feedStation          // AQ05 — generic tool
        }
    }

    /// AQ11: a `PostToolUse` on a test/build tool, recent and no longer
    /// `tool_running` — the result arrived. `nil` for anything else:
    /// a running test is AQ10, a non-test result isn't distinguished.
    static func resultAction(for session: CoreSession, now: Date) -> FishAction? {
        guard session.event?.lowercased() == "posttooluse",
              let tool = session.tool?.lowercased(),
              ["test", "pytest", "swiftbuild", "swifttest", "build"].contains(tool),
              session.mode?.lowercased() != "tool_running",
              let updated = session.updatedAt,
              now.timeIntervalSince1970 - updated <= toolEventLife
        else { return nil }
        return .resultBubble
    }

    /// The `FishState` a plan implies — attention actions still
    /// surface, warnings still sink; the action adds detail *within*
    /// the swim the panel already agreed on. AQ24's unconfirmed end
    /// shares the sink with failure — the *plan's action* is what keeps
    /// "inactive/history" distinct from "failed": the same motion, a
    /// different cited fact.
    static func state(for activity: SessionActivity, action: FishAction) -> FishState {
        switch action {
        case .warningBuoy, .inactiveDrift:
            return .sinking
        case .pearlDeposit, .returnNormal:
            return .leaving
        case .surfaceQuestion, .attentionBuoy:
            return .surfacing
        case .idleRest, .uncertainDrift:
            // AQ23's neutral marker drifts like an idle fish — still
            // moving, claiming nothing precise.
            return .idling
        default:
            return .swimming
        }
    }

    /// The one-line evidence the plan read — what the inspector and a
    /// fixture both cite (T54's "evidence matches the animation").
    static func evidenceLine(for session: CoreSession, axes: CoreSessionAxes?,
                             action: FishAction) -> String {
        var parts: [String] = []
        if let mode = session.mode { parts.append("mode=\(mode)") }
        if let lifecycle = session.lifecycle { parts.append("lifecycle=\(lifecycle)") }
        if let tool = session.tool { parts.append("tool=\(tool)") }
        if let event = session.event { parts.append("event=\(event)") }
        if session.ask != nil { parts.append("ask=\(session.ask?.kind ?? "open")") }
        if let review = axes?.review { parts.append("review=\(review)") }
        if let freshness = axes?.freshness { parts.append("freshness=\(freshness)") }
        if session.stale { parts.append("stale") }
        if parts.isEmpty { parts.append("no-detail") }
        return "\(action.rawValue) ← \(parts.joined(separator: " "))"
    }
}
