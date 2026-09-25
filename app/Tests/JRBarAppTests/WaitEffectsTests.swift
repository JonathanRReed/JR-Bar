import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The wait rule (nothing under 2 s, an orb from 2 s, a beam from 3 s),
/// the orb's activity vocabulary and the beam's motion flags — every
/// clock here is the test's own.
@Suite("Wait effects")
@MainActor
struct WaitEffectsTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: WaitPolicy

    @Test("the thresholds are two and three seconds")
    func thresholds() {
        #expect(WaitPolicy.orbAfter == 2)
        #expect(WaitPolicy.beamAfter == 3)
        #expect(WaitPolicy.orbAfter < WaitPolicy.beamAfter)
    }

    @Test("a wait is quiet under 2 s, an orb from 2 s, a beam from 3 s")
    func stages() {
        let cases: [(TimeInterval, WaitStage)] = [
            (0, .quiet), (0.5, .quiet), (1.999, .quiet), (2, .orb), (2.5, .orb), (2.999, .orb),
            (3, .beam), (3.5, .beam), (600, .beam),
        ]
        for (elapsed, expected) in cases {
            let stage = WaitPolicy.stage(since: Self.start, now: Self.start.addingTimeInterval(elapsed))
            #expect(stage == expected, "\(elapsed) s")
        }
    }

    @Test("no wait, or a clock read before the wait began, is quiet")
    func quietWithoutAWait() {
        #expect(WaitPolicy.stage(since: nil, now: Self.start) == .quiet)
        #expect(WaitPolicy.stage(since: Self.start, now: Self.start.addingTimeInterval(-10)) == .quiet)
    }

    @Test("each stage draws what the rule says, and only that")
    func stageDraws() {
        #expect(!WaitStage.quiet.showsOrb && !WaitStage.quiet.showsBeam)
        #expect(WaitStage.orb.showsOrb && !WaitStage.orb.showsBeam)
        #expect(WaitStage.beam.showsOrb && WaitStage.beam.showsBeam)
        #expect(WaitStage.allCases.sorted() == [.quiet, .orb, .beam])
    }

    @Test("a live wait schedules only its remaining thresholds, and a finished or absent one none")
    func boundaries() {
        let orbAt = Self.start.addingTimeInterval(2)
        let beamAt = Self.start.addingTimeInterval(3)
        #expect(WaitPolicy.boundaries(since: Self.start, after: Self.start) == [orbAt, beamAt])
        #expect(WaitPolicy.boundaries(since: Self.start, after: Self.start.addingTimeInterval(2.5)) == [beamAt])
        #expect(WaitPolicy.boundaries(since: Self.start, after: beamAt).isEmpty)
        #expect(WaitPolicy.boundaries(since: nil, after: Self.start).isEmpty)
        #expect(WaitPolicy.isLive(since: Self.start, now: Self.start.addingTimeInterval(1)))
        #expect(!WaitPolicy.isLive(since: Self.start, now: Self.start.addingTimeInterval(4)))
        #expect(!WaitPolicy.isLive(since: nil, now: Self.start))
    }

    @Test("a wait's timeline holds its start and both thresholds, so each render reads its own stage")
    func schedule() {
        let dates = WaitPolicy.schedule(since: Self.start)
        let moments = [Self.start, Self.start.addingTimeInterval(2), Self.start.addingTimeInterval(3)]
        let framed: [Date] = [Date.distantPast] + moments + [Date.distantFuture]
        #expect(dates == framed)
        #expect(moments.map { WaitPolicy.stage(since: Self.start, now: $0) } == [.quiet, .orb, .beam])
        #expect(WaitPolicy.stage(since: Self.start, now: .distantPast) == .quiet)
        #expect(WaitPolicy.schedule(since: nil).isEmpty)
    }

    @Test("an explicit timeline opens in the past and closes with a date that never comes")
    func explicitTimeline() {
        let later = Self.start.addingTimeInterval(45)
        #expect(ExplicitTimeline.moments([later, Self.start]) == [.distantPast, Self.start, later, .distantFuture])
        #expect(ExplicitTimeline.moments([]).isEmpty)
    }

    // MARK: AgentActivity

    /// Every provider's own spelling of its tools, as the hook reports
    /// them — Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Devin,
    /// Kiro, and the daemon's own tables (`mailbox._*_TOOLS`) — by the
    /// activity the orb makes of them.
    static let searchingNames: [String] = [
        "Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "mcp__github__search_code",
        "web_search", "view_image", "mcp__codex_apps__gmail__batch_read_email",
        "read_file", "read_many_files", "list_directory", "search_file_content", "glob", "google_web_search",
        "web_fetch", "read", "grep", "list", "webfetch", "codebase_search", "grep_search", "file_search",
        "list_dir", "view", "find", "fs_read", "open_file", "read_text_file", "readfile", "rg", "search_files",
        "search",
    ]
    static let writingNames: [String] = [
        "Edit", "Write", "MultiEdit", "NotebookEdit", "mcp__github__create_issue", "apply_patch", "write_file",
        "replace", "edit", "write", "patch", "multiedit", "edit_file", "search_replace", "delete_file",
        "str_replace", "fs_write",
    ]
    static let runningNames: [String] = [
        "Bash", "BashOutput", "KillShell", "shell", "exec_command", "local_shell", "unified_exec", "write_stdin",
        "exec", "run_shell_command", "bash", "run_terminal_cmd", "execute_bash", "powershell",
        "run_terminal_command", "terminal", "zsh",
    ]
    static let thinkingNames: [String] = [
        "Task", "Agent", "TodoWrite", "Skill", "SlashCommand", "update_plan", "todowrite", "task", "run_subagent",
        "sidekick", "think", "reason", "write_todos",
    ]
    /// A question about to be put to the person: until it lands as an
    /// ask, the row is working and the agent is thinking.
    static let askingNames: [String] = ["AskUserQuestion", "ExitPlanMode"]

    @Test("every provider's tool names map to the activity they are")
    func providerToolNames() {
        let table: [(AgentActivity, [String])] = [
            (.searching, Self.searchingNames), (.writing, Self.writingNames), (.running, Self.runningNames),
            (.thinking, Self.thinkingNames), (.thinking, Self.askingNames),
        ]
        for (expected, names) in table {
            for name in names {
                #expect(AgentActivity.from(event: "PreToolUse", tool: name) == expected, "\(name)")
            }
        }
    }

    @Test("every exact tool name maps, whatever its case or surrounding space")
    func exactTableIsCaseBlind() {
        for (name, expected) in AgentActivity.exactTools {
            #expect(AgentActivity.from(tool: name) == expected, "\(name)")
            #expect(AgentActivity.from(tool: name.uppercased()) == expected, "\(name) upper-cased")
            #expect(AgentActivity.from(tool: "  \(name)\n") == expected, "\(name) padded")
        }
    }

    @Test("no tool name is claimed by two activities")
    func toolListsAreDisjoint() {
        let lists = [AgentActivity.searchTools, AgentActivity.writeTools, AgentActivity.runTools,
                     AgentActivity.thinkTools, AgentActivity.askTools]
        let total = lists.reduce(0) { $0 + $1.count }
        #expect(Set(lists.flatMap { $0 }).count == total)
        #expect(AgentActivity.exactTools.count == total)
    }

    @Test("an unknown tool is read by its words, and nothing at all is thinking")
    func unknownToolsByTheirWords() {
        let cases: [(String, AgentActivity)] = [
            ("readSourceFile", .searching), ("fetch_url", .searching), ("github__list_pull_requests", .searching),
            ("createPullRequest", .writing), ("save_note", .writing), ("run_tests", .running),
            ("execute_python", .running), ("spawn_subagent", .thinking), ("plan_steps", .thinking),
            ("mystery", .thinking), ("functions.shell", .running), ("container.exec", .running),
        ]
        for (tool, expected) in cases {
            #expect(AgentActivity.from(tool: tool) == expected, "\(tool)")
        }
        #expect(AgentActivity.from(tool: "") == nil)
        #expect(AgentActivity.from(tool: "   ") == nil)
        #expect(AgentActivity.toolWords("readSourceFile") == ["read", "source", "file"])
        #expect(AgentActivity.strippedTool("mcp__github__search_code") == "search_code")
    }

    @Test("every canonical event the daemon sends has an activity, with and without a tool")
    func everyEvent() {
        let thinking = ["UserPromptSubmit", "SessionStart", "PreCompact", "PostCompact", "SubagentStart",
                        "SubagentStop", "Stop", "StopFailure", "SessionEnd", "Interrupt", "HermesTurnEnd",
                        "SessionFinalize", "ApiRequestError", "PostToolUse", "PostToolUseFailure",
                        "PermissionDenied", "ElicitationResult"]
        for event in thinking {
            #expect(AgentActivity.from(event: event, tool: nil) == .thinking, "\(event)")
            // A tool left over from an earlier event says nothing here.
            #expect(AgentActivity.from(event: event, tool: "Bash") == .thinking, "\(event) + Bash")
        }
        // On a working row a question was settled elsewhere, and a
        // notification never needed you: the agent is back to thinking,
        // never "listening" under a row that says Working.
        for event in ["PermissionRequest", "Elicitation", "Notification"] {
            #expect(AgentActivity.from(event: event, tool: nil) == .thinking, "\(event)")
            #expect(AgentActivity.from(event: event, tool: "Edit") == .thinking, "\(event) + Edit")
        }
        // A tool about to run says what it is; Cursor's shell pair names none.
        #expect(AgentActivity.from(event: "PreToolUse", tool: "Edit") == .writing)
        #expect(AgentActivity.from(event: "PreToolUse", tool: nil) == .running)
        #expect(AgentActivity.from(event: "PreToolUse", tool: "") == .running)
        // No event, or one this table does not know, still reads the tool.
        #expect(AgentActivity.from(event: nil, tool: "Grep") == .searching)
        #expect(AgentActivity.from(event: "SomethingNew", tool: "Bash") == .running)
        #expect(AgentActivity.from(event: nil, tool: nil) == .thinking)
        #expect(AgentActivity.from(event: " PreToolUse ", tool: "Read") == .searching)
    }

    @Test("every activity is reachable from a real hook")
    func everyActivityReachable() {
        let reached = Set([
            AgentActivity.from(event: "UserPromptSubmit", tool: nil),
            AgentActivity.from(event: "PreToolUse", tool: "Grep"),
            AgentActivity.from(event: "PreToolUse", tool: "apply_patch"),
            AgentActivity.from(event: "PreToolUse", tool: "shell"),
        ])
        #expect(reached == Set(AgentActivity.allCases))
    }

    @Test("only a live working row has an activity for its orb")
    func rowActivity() {
        func makeRow(_ mode: String, stale: Bool = false, event: String? = "PreToolUse", tool: String? = "Read") -> SessionRow {
            SessionRow(session: CoreSession(id: "claude:a", provider: "claude", mode: mode, stale: stale,
                                            event: event, tool: tool), pinnedAsk: nil)
        }
        #expect(makeRow("working").agentActivity == .searching)
        #expect(makeRow("working", tool: "Bash").agentActivity == .running)
        #expect(makeRow("working", event: "PostToolUse", tool: "Bash").agentActivity == .thinking)
        #expect(makeRow("working", event: "Notification", tool: nil).agentActivity == .thinking)
        #expect(makeRow("working", event: "PermissionRequest", tool: "Bash").agentActivity == .thinking)
        #expect(makeRow("working", stale: true).agentActivity == nil)
        #expect(makeRow("completed").agentActivity == nil)
        #expect(makeRow("idle").agentActivity == nil)
        #expect(makeRow("failed").agentActivity == nil)
        let ask = CoreAsk(session: "claude:a", summary: "Bash", answerable: true, request: "r")
        #expect(SessionRow(session: CoreSession(id: "claude:a", provider: "claude", mode: "waiting", ask: ask),
                           pinnedAsk: nil).agentActivity == nil)
        #expect(SessionRow(orphanAsk: ask).agentActivity == nil)
    }

    // MARK: ThinkingOrb

    @Test("under Reduce Motion every orb holds its still arrangement and runs no clock")
    func orbReduceMotion() {
        for activity in AgentActivity.allCases {
            for animating in [true, false] {
                let mode = OrbMotion.mode(activity: activity, animating: animating, reduced: true)
                #expect(mode == .still(OrbLayout.stillTime(activity)), "\(activity)")
                #expect(!mode.isAnimated)
            }
        }
    }

    @Test("an orb runs its clock only while its host animates it and motion is allowed")
    func orbAnimatesOnlyWhenAsked() {
        for activity in AgentActivity.allCases {
            #expect(OrbMotion.mode(activity: activity, animating: true, reduced: false) == .animated)
            #expect(!OrbMotion.mode(activity: activity, animating: false, reduced: false).isAnimated)
            #expect(OrbMotion.mode(activity: activity, animating: true, reduced: false, stillTime: 1.5) == .still(1.5))
        }
        #expect(OrbMotion.frameInterval == 1.0 / 30)
    }

    @Test("each activity's still arrangement is its own, and every dot stays inside the orb")
    func orbArrangements() {
        var seen: [[OrbDot]] = []
        for activity in AgentActivity.allCases {
            let still = OrbLayout.dots(activity, at: OrbLayout.stillTime(activity))
            #expect(!still.isEmpty)
            #expect(!seen.contains(still), "\(activity) looks like another activity")
            seen.append(still)
            for time in stride(from: 0.0, through: 6.0, by: 0.05) {
                for dot in OrbLayout.dots(activity, at: time) {
                    #expect(abs(dot.x) + dot.radius <= 1.001, "\(activity) at \(time)")
                    #expect(abs(dot.y) + dot.radius <= 1.001, "\(activity) at \(time)")
                    #expect(dot.radius > 0 && dot.opacity >= 0 && dot.opacity <= 1)
                }
            }
        }
    }

    /// Each activity's full loop: after this long every dot is back
    /// where it was.
    static func loopPeriod(_ activity: AgentActivity) -> TimeInterval {
        switch activity {
        case .thinking: return 240 // the breath's, the turn's and the looseness's common multiple
        case .searching: return OrbLayout.searchingSwing
        case .writing: return Double(OrbLayout.writingSlots + 1) * OrbLayout.writingStep
        case .running: return OrbLayout.runningLap
        }
    }

    static func sameDots(_ lhs: [OrbDot], _ rhs: [OrbDot]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { pair in
            let (a, b) = pair
            let apart = [a.x - b.x, a.y - b.y, a.radius - b.radius, a.opacity - b.opacity].map(abs).max() ?? 0
            return apart < 1e-6
        }
    }

    @Test("an animated orb actually moves, and loops")
    func orbMoves() {
        for activity in AgentActivity.allCases {
            #expect(OrbLayout.dots(activity, at: 0.2) != OrbLayout.dots(activity, at: 0.7), "\(activity)")
            let period = Self.loopPeriod(activity)
            for moment in [0.1, 0.45, 1.3] {
                let first = OrbLayout.dots(activity, at: moment)
                #expect(Self.sameDots(first, OrbLayout.dots(activity, at: moment + period)), "\(activity) at \(moment)")
                #expect(!Self.sameDots(first, OrbLayout.dots(activity, at: moment + period / 3)), "\(activity) mid-loop")
            }
        }
    }

    /// The ink's centre height: each dot weighed by its area and how
    /// dark it draws, in the orb's unit space.
    static func inkCentre(_ dots: [OrbDot]) -> Double {
        let floor = OrbLayout.opacityFloor(dark: false)
        let weights = dots.map { $0.radius * $0.radius * (floor + (1 - floor) * $0.opacity) }
        let total = weights.reduce(0, +)
        let moments = zip(dots, weights).map { $0.0.y * $0.1 }
        return moments.reduce(0, +) / total
    }

    /// Level: within 0.12 of the orb's reach, about 0.7 pt at the row's
    /// 14 pt — where the eye stops reading an orb as riding high or low.
    static let levelTolerance = 0.12

    @Test("every orb's ink sits level with the text beside it, still and over its loop")
    func orbInkIsCentred() {
        for activity in AgentActivity.allCases {
            let still = Self.inkCentre(OrbLayout.dots(activity, at: OrbLayout.stillTime(activity)))
            #expect(abs(still) < Self.levelTolerance, "\(activity) still: \(still)")
            let period = Self.loopPeriod(activity)
            let steps = 200
            let centres = (0..<steps).map { step in
                Self.inkCentre(OrbLayout.dots(activity, at: period * Double(step) / Double(steps)))
            }
            let mean = centres.reduce(0, +) / Double(steps)
            #expect(abs(mean) < Self.levelTolerance, "\(activity) over its loop: \(mean)")
        }
    }

    // MARK: BorderBeam

    @Test("an inactive beam draws nothing and runs no clock, reduced or not")
    func beamInactive() {
        for reduced in [false, true] {
            let mode = BeamMotion.mode(active: false, reduced: reduced)
            #expect(mode == .off)
            #expect(!mode.draws)
            #expect(!mode.isAnimating)
        }
    }

    @Test("under Reduce Motion an active beam is a still glow; otherwise it travels")
    func beamReduceMotion() {
        let glow = BeamMotion.mode(active: true, reduced: true)
        #expect(glow == .glow && glow.draws && !glow.isAnimating)
        let travel = BeamMotion.mode(active: true, reduced: false)
        #expect(travel == .travel && travel.draws && travel.isAnimating)
    }

    @Test("a beam in a window off screen draws where it stands and runs no clock")
    func beamOffScreen() {
        let held = BeamMotion.mode(active: true, reduced: false, onScreen: false)
        #expect(held == .held && held.draws && !held.isAnimating)
        #expect(BeamMotion.mode(active: false, reduced: false, onScreen: false) == .off)
        #expect(BeamMotion.mode(active: true, reduced: true, onScreen: false) == .glow)
        #expect(BeamGeometry.frameInterval == 1.0 / 60, "a capped clock, never the display's full rate")
    }

    @Test("the head glides at one speed on any border, a small one lapping no faster than the floor")
    func beamTiming() {
        #expect((120...150).contains(BeamGeometry.speed))
        #expect(BeamGeometry.fade == 0.25)
        let card: CGFloat = 840
        let cardLap = BeamGeometry.lap(forTrack: card)
        #expect(abs(cardLap - Double(card / BeamGeometry.speed)) < 1e-9)
        #expect(BeamGeometry.lap(forTrack: 100) == BeamGeometry.minimumLap)
        #expect(BeamGeometry.lap(forTrack: 0) == BeamGeometry.minimumLap)
        // The head covers the same points a second round a card and
        // along a field twice its length.
        let field = card * 2
        let cardGlide = card / CGFloat(BeamGeometry.lap(forTrack: card))
        let fieldGlide = field / CGFloat(BeamGeometry.lap(forTrack: field))
        #expect(abs(cardGlide - fieldGlide) < 1e-6)
        #expect(BeamGeometry.phase(at: 0, trackLength: card) == 0)
        #expect(abs(BeamGeometry.phase(at: cardLap / 2, trackLength: card) - 0.5) < 1e-9)
        #expect(abs(BeamGeometry.phase(at: cardLap * 7 + cardLap / 4, trackLength: card) - 0.25) < 1e-9)
        #expect(BeamGeometry.phase(at: -0.6, trackLength: card) >= 0)
    }

    @Test("the ring is concentric with the element's corners and its length is the border's")
    func beamGeometry() {
        let size = CGSize(width: 200 + 2 * BeamGeometry.bleed, height: 80 + 2 * BeamGeometry.bleed)
        let rect = BeamGeometry.ringRect(in: size)
        #expect(abs(rect.width - (200 - BeamGeometry.lineWidth)) < 1e-9)
        #expect(BeamGeometry.ringRadius(10, in: rect) == 10 - BeamGeometry.lineWidth / 2)
        #expect(BeamGeometry.ringRadius(0, in: rect) == 0)
        #expect(BeamGeometry.ringRadius(500, in: rect) == rect.height / 2)
        let square = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(BeamGeometry.perimeter(of: square, cornerRadius: 0) == 300)
        #expect(abs(BeamGeometry.perimeter(of: square, cornerRadius: 25) - (100 + 25 * 2 * .pi)) < 1e-9)
        let baseline = BeamGeometry.trackLength(.baseline, in: CGSize(width: 408, height: 60))
        #expect(baseline == 400 + BeamGeometry.visibleLength)
        #expect(BeamGeometry.visibleLength < 200, "a short arc, not a racing stripe")
        // A baseline stretch is clipped to the edge, and gone off either end.
        let bar = CGSize(width: 108, height: 60)
        let entering = BeamGeometry.baselineSpan(of: -10, length: 26, in: bar)
        #expect(entering.minX == BeamGeometry.bleed && entering.width == 16)
        let leaving = BeamGeometry.baselineSpan(of: 90, length: 26, in: bar)
        #expect(leaving.minX == BeamGeometry.bleed + 90 && leaving.width == 10)
        #expect(BeamGeometry.baselineSpan(of: -40, length: 26, in: bar).width == 0)
        #expect(BeamGeometry.baselineSpan(of: 120, length: 26, in: bar).width == 0)
    }

    @Test("a dash phase shows the pattern's one stretch where it is asked for")
    func beamDashPhase() {
        let period = BeamGeometry.period
        #expect(BeamGeometry.dashPhase(showingFrom: 0) == 0)
        #expect(BeamGeometry.dashPhase(showingFrom: 10) == period - 10)
        #expect(BeamGeometry.dashPhase(showingFrom: -5) == 5)
        #expect(BeamGeometry.dashPhase(showingFrom: period + 10) == period - 10)
        for dash in [BeamGeometry.headDash, BeamGeometry.trailDash, BeamGeometry.glowDash] {
            #expect(dash.count == 2 && dash.reduce(0, +) == period, "one stretch a period")
        }
        #expect(BeamGeometry.trailOpacity.count == BeamGeometry.trailSteps)
        #expect(BeamGeometry.trailOpacity == BeamGeometry.trailOpacity.sorted(by: >), "the trail only fades")
    }

    // MARK: The session row's slot

    @Test("the mark slot is one size whatever it draws, so the trailing column never moves")
    func rowSlotIsFixed() {
        var sizes: Set<CGFloat> = []
        for activity in SessionActivity.allCases {
            let doings: [AgentActivity?] = [nil] + AgentActivity.allCases.map { $0 }
            for doing in doings {
                let kind = SessionRowMark.kind(activity: activity, agentActivity: doing)
                let size = SessionRowMark.slotSize(for: kind)
                sizes.insert(size.width)
                sizes.insert(size.height)
            }
        }
        #expect(sizes == [SessionRowMark.slot])
        #expect(SessionRowView.markRoom == 5 + SessionRowMark.slot)
    }

    @Test("only a working row with an activity draws an orb")
    func rowSlotKinds() {
        #expect(SessionRowMark.kind(activity: .working, agentActivity: .writing) == .orb(.writing))
        #expect(SessionRowMark.kind(activity: .working, agentActivity: nil) == .mark(.working))
        for activity in SessionActivity.allCases where activity != .working {
            for doing in AgentActivity.allCases {
                #expect(SessionRowMark.kind(activity: activity, agentActivity: doing) == .mark(activity))
            }
        }
    }

    @Test("rows doing different things share one trailing width")
    func rowTrailingWidthIgnoresActivity() {
        let now = Self.start
        let tools = ["Read", "Edit", "Bash", "Task"]
        let rows = tools.enumerated().map { index, tool in
            SessionRow(session: CoreSession(id: "claude:\(index)", provider: "claude", mode: "working",
                                            since: now.timeIntervalSince1970 - 60, event: "PreToolUse", tool: tool),
                       pinnedAsk: nil)
        }
        let quietRows = tools.enumerated().map { index, _ in
            SessionRow(session: CoreSession(id: "claude:\(index)", provider: "claude", mode: "working",
                                            since: now.timeIntervalSince1970 - 60), pinnedAsk: nil)
        }
        #expect(Set(rows.compactMap(\.agentActivity)).count == 4)
        let column = SessionRowView.trailingWidth(rows: rows, now: now)
        #expect(column == SessionRowView.trailingWidth(rows: quietRows, now: now))
        #expect(column == SessionRowView.trailingWidth(rows: [rows[0]], now: now))
        let workingWord = SessionRowView.wordWidths[.working] ?? 0
        #expect(column >= workingWord + SessionRowView.markRoom, "the word and the orb fit")
    }

    // MARK: The clocks the placements read

    @Test("the desk keeps when each answer left, and forgets it when the answer lands")
    func deskPendingSince() async {
        let sent = Self.start.addingTimeInterval(42)
        let probe = WaitDeskProbe()
        let desk = AskAnswerDesk(send: { _, _, _ in CoreReply(id: "1", ok: true) })
        desk.clock = { sent }
        desk.send = { session, _, _ in
            probe.seen = probe.desk?.pendingSince(session)
            return CoreReply(id: "1", ok: true)
        }
        probe.desk = desk
        let ask = CoreAsk(session: "claude:a", summary: "Bash", answerable: true, request: "r")
        #expect(desk.pendingSince("claude:a") == nil)
        let outcome = await desk.answer(ask, .approve)
        #expect(outcome.ok)
        #expect(probe.seen == sent, "in flight, the card's clock reads when it left")
        #expect(desk.pendingSince("claude:a") == nil)
        #expect(desk.pendingSince(nil) == nil)
        #expect(!desk.isPending("claude:a"))
    }

    @Test("the palette times its search from when the sources start reading until they are done")
    func paletteSearchingSince() {
        let model = PaletteModel()
        let ticks = WaitTestClock(Self.start)
        model.clock = { ticks.now }
        model.load(items: [], usage: PaletteUsage(), now: Self.start)
        #expect(model.searchingSince == nil)
        model.query = "hid"
        model.noteSearching(true)
        #expect(model.searchingSince == Self.start)
        ticks.now = Self.start.addingTimeInterval(5)
        model.setSearchResults([], for: "hid", finished: false)
        #expect(model.searchingSince == Self.start, "a partial answer is the same wait")
        model.query = "hide"
        model.noteSearching(true)
        #expect(model.searchingSince == Self.start,
                "typing on while the sources read keeps the wait, so its orb and beam never drop out")
        model.setSearchResults([], for: "hide", finished: true)
        #expect(model.searchingSince == nil)
        ticks.now = Self.start.addingTimeInterval(9)
        model.query = "hidden"
        model.noteSearching(true)
        #expect(model.searchingSince == Self.start.addingTimeInterval(9), "a search after a finished one is a new wait")
        model.load(items: [], usage: PaletteUsage(), now: Self.start)
        #expect(model.searchingSince == nil)
    }

    @Test("the ask card's beam runs only while the panel is open, and its mark's clock always")
    func askBeamNeedsAnOpenPanel() async {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        let sent = Self.start.addingTimeInterval(7)
        let probe = WaitPanelProbe()
        probe.store = store
        store.askDesk.clock = { sent }
        let ask = CoreAsk(session: "claude:a", summary: "Bash", answerable: true, request: "r")
        probe.ask = ask
        store.askDesk.send = { _, _, _ in
            probe.look()
            return CoreReply(id: "1", ok: true)
        }
        store.isOpen = false
        let outcome = await store.askDesk.answer(ask, .approve)
        #expect(outcome.ok)
        #expect(probe.closedBeam == .some(nil), "a shut panel's card runs no beam")
        #expect(probe.closedMark == sent, "the mark still knows when the answer left")
        #expect(probe.openBeam == sent, "reopened mid-wait, the beam picks up the wait's own clock")
        #expect(store.askBeamSince(ask) == nil, "and the answer landing ends it")
    }

    // MARK: DelayedWait

    @Test("a spinner keeps the control sizes the call sites used before the rule")
    func spinnerSizes() {
        #expect(WaitIndicator.controlSize(for: 12) == .mini)
        #expect(WaitIndicator.controlSize(for: 14) == .small)
        #expect(WaitIndicator.controlSize(for: 18) == .small)
    }

    @Test("the stage's own change carries the fade, so nothing the stage shows cuts in")
    func stageFade() {
        #expect(WaitPolicy.fade == 0.2)
        #expect(WaitPolicy.fade < WaitPolicy.beamAfter - WaitPolicy.orbAfter)
    }

    @Test("the Rail's hold ring schedule is framed, so its deadline fires")
    func railTicksAreFramed() {
        let deadline = Self.start.addingTimeInterval(3)
        let ticks = RailHoldRing.ticks(from: Self.start, until: deadline, every: 1)
        let framed = ExplicitTimeline.moments(ticks)
        #expect(framed.first == .distantPast)
        #expect(framed.last == .distantFuture)
        #expect(framed.dropLast().last == deadline, "the deadline is no longer the date that never fires")
    }
}

/// A clock a test moves by hand.
@MainActor
final class WaitTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// What the desk looked like from inside its own send.
@MainActor
final class WaitDeskProbe {
    weak var desk: AskAnswerDesk?
    var seen: Date?
}

/// What the panel's ask card read from inside the desk's send: shut,
/// then open.
@MainActor
final class WaitPanelProbe {
    weak var store: PanelStore?
    var ask: CoreAsk?
    var closedBeam: Date??
    var closedMark: Date?
    var openBeam: Date?

    func look() {
        guard let store else { return }
        closedBeam = .some(store.askBeamSince(ask))
        closedMark = store.answerPendingSince(ask)
        store.isOpen = true
        openBeam = store.askBeamSince(ask)
    }
}
