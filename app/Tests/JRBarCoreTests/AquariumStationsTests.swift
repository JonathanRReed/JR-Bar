import Foundation
import Testing
import JRBarCore

/// Stations give the planner's tool-level actions somewhere to happen:
/// every tool action has a place, nothing else invents one, a finished
/// test's colour comes only from the hook's own event, and the moving
/// point a fish chases stays inside its station.
@Suite("Aquarium stations")
struct AquariumStationsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(mode: String? = "tool_running", tool: String? = nil,
                         event: String? = nil, age: Double = 2) -> CoreSession {
        CoreSession(id: "s", provider: "claude", mode: mode, lifecycle: "active",
                    updatedAt: now.timeIntervalSince1970 - age, event: event, tool: tool)
    }

    private func cue(_ s: CoreSession) -> FishCue? {
        let plan = AquariumPlanner.plan(for: s, now: now)
        return AquariumStations.cue(for: s, plan: plan, now: now)
    }

    @Test("every tool action has a station; swims and exchanges have none")
    func stationPerAction() {
        #expect(AquariumStations.station(for: .forage) == .kelp)
        #expect(AquariumStations.station(for: .explore) == .survey)
        #expect(AquariumStations.station(for: .tendStones) == .pebbles)
        #expect(AquariumStations.station(for: .currentWork) == .current)
        #expect(AquariumStations.station(for: .inspectStructure) == .wreck)
        #expect(AquariumStations.station(for: .resultBubble) == .wreck)
        #expect(AquariumStations.station(for: .serviceVisit) == .chest)
        #expect(AquariumStations.station(for: .feedStation) == .bench)
        for action: FishAction in [.enter, .idleRest, .patrol, .attentiveHover, .tokenPass,
                                   .surfaceQuestion, .attentionBuoy, .warningBuoy,
                                   .pearlDeposit, .returnNormal, .uncertainDrift, .inactiveDrift] {
            #expect(AquariumStations.station(for: action) == nil, "\(action) is not a place")
        }
    }

    @Test("an observed tool names the station the plan cites")
    func cuesFollowTheTool() {
        #expect(cue(session(tool: "Read"))?.station == .kelp)
        #expect(cue(session(tool: "Grep"))?.station == .survey)
        #expect(cue(session(tool: "Edit"))?.station == .pebbles)
        #expect(cue(session(tool: "Bash"))?.station == .current)
        #expect(cue(session(tool: "pytest"))?.station == .wreck)
        #expect(cue(session(tool: "mcp__github__search"))?.station == .chest)
        #expect(cue(session(tool: "TodoWrite"))?.station == .bench)
        #expect(cue(session(tool: "Read"))?.tone == nil)
    }

    @Test("no tool, a stale row or an old event claims no station")
    func noInventedStations() {
        #expect(cue(session(tool: nil)) == nil, "working with no detail is a patrol")
        var stale = session(tool: "Read")
        stale.stale = true
        #expect(cue(stale) == nil)
        #expect(cue(session(tool: "Read", age: AquariumPlanner.toolEventLife + 5)) == nil)
    }

    @Test("a finished test is green on PostToolUse and red on PostToolUseFailure")
    func resultTones() {
        let passed = cue(session(mode: "thinking", tool: "pytest", event: "PostToolUse"))
        #expect(passed == FishCue(station: .wreck, tone: .pass,
                                  observedAt: now.addingTimeInterval(-2)))
        let failed = cue(session(mode: "thinking", tool: "swifttest", event: "PostToolUseFailure"))
        #expect(failed?.station == .wreck)
        #expect(failed?.tone == .fail)
        #expect(cue(session(mode: "working", tool: "pytest", event: "PostToolUseFailure"))?.tone == .fail,
                "a patrolling fish gets its red bubble too")
        #expect(cue(session(mode: "thinking", tool: "Bash", event: "PostToolUseFailure")) == nil,
                "a failed shell command is not a test result")
        #expect(cue(session(mode: "thinking", tool: "pytest", event: "PostToolUseFailure",
                            age: AquariumPlanner.toolEventLife + 1)) == nil)
        #expect(cue(session(mode: "idle_ready", tool: "pytest", event: "PostToolUseFailure")) == nil,
                "an idle fish rests; it isn't at the wreck")
    }

    @Test("a cue stops claiming the work once its evidence is old")
    func freshness() {
        let cue = FishCue(station: .kelp, observedAt: now)
        #expect(cue.isFresh(at: now.addingTimeInterval(10)))
        #expect(cue.isFresh(at: now.addingTimeInterval(AquariumPlanner.toolEventLife)))
        #expect(!cue.isFresh(at: now.addingTimeInterval(AquariumPlanner.toolEventLife + 1)))
        #expect(FishCue(station: .kelp).isFresh(at: now), "no stamp follows the planner: current")
    }

    @Test("the fish model carries the cue, and residents never do")
    func modelCarriesCue() {
        let fish = AquariumModel.reduce(sessions: [session(tool: "Edit")], previous: [], now: now)
        #expect(fish.first?.cue?.station == .pebbles)
        let again = AquariumModel.reduce(sessions: [session(tool: "Read")], previous: fish, now: now)
        #expect(again.first?.cue?.station == .kelp, "the cue follows the newest document")
        let resident = AquariumResident(id: "gone", label: "Nemo", provider: "claude", stage: 1,
                                        lastNourishedAt: now.timeIntervalSince1970)
        let tank = AquariumModel.reduce(sessions: [], previous: again, now: now,
                                        residents: [resident])
        #expect(tank.allSatisfy { $0.cue == nil })
    }

    @Test("a station's point stays inside its span")
    func targetsStayNear() {
        let anchor = AquariumStations.Anchor(x: 0.5, y: 0.6, spanX: 0.05, spanY: 0.2,
                                             altX: 0.8, altY: 0.4)
        for station in TankStation.allCases {
            for step in 0..<200 {
                let t = Double(step) * 0.37
                let p = AquariumStations.target(for: station, anchor: anchor, t: t, seed: 0xBEEF)
                #expect(p.x.isFinite && p.y.isFinite)
                if station == .survey {
                    let nearA = abs(p.x - 0.5) <= 0.05 && abs(p.y - 0.6) <= 0.2
                    let nearB = abs(p.x - 0.8) <= 0.05 && abs(p.y - 0.4) <= 0.2
                    #expect(nearA || nearB)
                } else {
                    #expect(abs(p.x - 0.5) <= 0.05 + 1e-9, "\(station) strays across")
                    #expect(abs(p.y - 0.6) <= 0.2 + 1e-9, "\(station) strays up or down")
                }
            }
        }
    }

    @Test("a surveyor alternates between its two landmarks")
    func surveyAlternates() {
        let anchor = AquariumStations.Anchor(x: 0.2, y: 0.5, spanX: 0.01, spanY: 0.01,
                                             altX: 0.8, altY: 0.5)
        var legs = Set<Int>()
        for step in 0..<40 {
            let t = Double(step) * AquariumStations.surveyLeg / 2
            let p = AquariumStations.target(for: .survey, anchor: anchor, t: t, seed: 7)
            legs.insert(p.x < 0.5 ? 0 : 1)
        }
        #expect(legs == [0, 1])
    }

    @Test("an inspector laps the wreck all the way round")
    func wreckLaps() {
        let anchor = AquariumStations.Anchor(x: 0.5, y: 0.5, spanX: 0.1, spanY: 0.1)
        var quadrants = Set<Int>()
        for step in 0..<44 {
            let t = Double(step) * AquariumStations.wreckLap / 44
            let p = AquariumStations.target(for: .wreck, anchor: anchor, t: t, seed: 3)
            quadrants.insert((p.x >= 0.5 ? 1 : 0) + (p.y >= 0.5 ? 2 : 0))
        }
        #expect(quadrants.count == 4)
    }

    @Test("two fish at one station don't stack")
    func seedsSpread() {
        let anchor = AquariumStations.Anchor(x: 0.5, y: 0.5)
        let a = AquariumStations.target(for: .chest, anchor: anchor, t: 10, seed: 1)
        let b = AquariumStations.target(for: .chest, anchor: anchor, t: 10, seed: 1 << 17 | 0x8000)
        #expect(a.x != b.x || a.y != b.y)
    }

    @Test("holding stations ease off on arrival; ranging ones keep moving")
    func effortRamps() {
        #expect(AquariumStations.effort(for: .current, distance: 0.5) == 1)
        #expect(AquariumStations.effort(for: .current, distance: 0.0) == AquariumStations.holdEffort)
        let mid = AquariumStations.effort(for: .chest, distance: 0.075)
        #expect(mid > AquariumStations.holdEffort && mid < 1)
        #expect(AquariumStations.effort(for: .kelp, distance: 0) == AquariumStations.effort(for: .kelp, distance: 1))
    }

    @Test("every station and result has words for the inspector")
    func phrases() {
        for station in TankStation.allCases { #expect(!station.phrase.isEmpty) }
        #expect(FishCue(station: .wreck, tone: .pass).phrase != FishCue(station: .wreck, tone: .fail).phrase)
    }
}
