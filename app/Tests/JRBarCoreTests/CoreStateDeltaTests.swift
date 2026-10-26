import Foundation
import Observation
import Testing
@testable import JRBarCore

@Suite("State slices on the wire")
@MainActor
struct CoreStateDeltaTests {
    @Test("roster fields and nested health edits preserve other facts")
    func edits() throws {
        let core = CoreModel()
        core.apply(.state(CoreState(generation: 1, sessions: [
            CoreSession(id: "a", provider: "claude", mode: "working"),
            CoreSession(id: "b", provider: "codex", mode: "working"),
        ], health: .object(["source": .object(["fresh": .bool(true), "detail": .string("kept")])]))))
        core.apply(try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":2,"base_generation":1,"slices":{
          "sessions":{"generation":1,"changes":{"b":{"mode":"idle"}},"removed":[],"order":["b","a"]},
          "health":{"generation":1,"patch":[{"path":["source","fresh"],"value":false}]}
        }}
        """))
        #expect(core.allSessions.map(\.id) == ["b", "a"])
        #expect(core.allSessions[0].mode == "idle")
        #expect(core.allSessions[1].mode == "working")
        #expect(core.health == .object(["source": .object(["fresh": .bool(false), "detail": .string("kept")])]))
    }
    @Test("a delta changes its slice and leaves unrelated observation armed")
    func observation() throws {
        let model = CoreModel()
        model.handle(.connected)
        model.apply(.state(CoreState(generation: 1, sessions: [CoreSession(id: "fixture", provider: "claude")])))
        let flag = CoreModelObservationTests.Tripped()
        withObservationTracking { _ = model.allSessions } onChange: { flag.fired = true }
        let frame = try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":2,"base_generation":1,"now":100,"slices":{"hidden_count":{"generation":1,"value":3}}}
        """)
        model.apply(frame)
        #expect(model.hiddenCount == 3)
        #expect(model.state?.hiddenCount == 3)
        #expect(model.state?.generation == 2)
        #expect(model.allSessions.map(\.id) == ["fixture"])
        #expect(!flag.fired)
        #expect(model.isLive)
    }

    @Test("skipped, reordered and missing baselines reject the entire delta until a full state")
    func missedBaseline() throws {
        for baseline in ["2", "4", "null"] {
            let model = CoreModel()
            model.handle(.connected)
            model.apply(.state(CoreState(generation: 3, health: .object(["left": .number(2), "right": .number(0)]),
                                        hiddenCount: 7)))
            model.apply(try CoreCodec.decode(line: """
            {"t":"state_delta","v":1,"generation":5,"base_generation":\(baseline),"slices":{
              "hidden_count":{"generation":3,"value":9},
              "health":{"generation":3,"patch":[{"path":["right"],"value":3}]}
            }}
            """))
            #expect(model.state?.generation == 3)
            #expect(model.hiddenCount == 7)
            #expect(model.health == .object(["left": .number(2), "right": .number(0)]))
            #expect(model.stateRejected != nil)
            #expect(!model.isLive)
            // A later delta cannot clear rejection. Only a full snapshot can.
            model.apply(try CoreCodec.decode(line: """
            {"t":"state_delta","v":1,"generation":6,"base_generation":3,"slices":{}}
            """))
            #expect(model.state?.generation == 3)
            model.apply(.state(CoreState(generation: 6, hiddenCount: 9)))
            #expect(model.isLive)
            #expect(model.hiddenCount == 9)
        }
    }

    @Test("coalesced generation jumps apply when based on the current transmitted state")
    func coalescedBaseline() throws {
        let model = CoreModel()
        model.apply(.state(CoreState(generation: 2, hiddenCount: 0)))
        let frame = try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":5,"base_generation":2,"slices":{"hidden_count":{"generation":2,"value":3}}}
        """)
        model.apply(frame)
        #expect(model.hiddenCount == 3)
        model.apply(frame) // Repeated or reordered old frames do not regress it.
        #expect(model.state?.generation == 5)
        #expect(model.stateRejected == nil)
    }

    @Test("generations, nullable fields and reconnects preserve the snapshot boundary")
    func boundaries() throws {
        let model = CoreModel()
        let delta = try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":3,"base_generation":2,"slices":{"hidden_count":{"generation":2,"value":4}}}
        """)
        model.apply(delta)
        #expect(model.state == nil)
        model.apply(.state(CoreState(generation: 2)))
        model.apply(delta)
        #expect(model.hiddenCount == 4)
        model.apply(try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":4,"base_generation":3,"slices":{"hidden_count":{"generation":1,"value":8}}}
        """))
        #expect(model.hiddenCount == 4)
        model.apply(try CoreCodec.decode(line: """
        {"t":"state_delta","v":1,"generation":5,"base_generation":4,"slices":{"hidden_count":{"generation":3,"value":null}}}
        """))
        #expect(model.hiddenCount == nil)
        model.handle(.disconnected(reason: "fixture"))
        model.apply(delta)
        #expect(model.state == nil)
        model.apply(.state(CoreState(generation: 1)))
        model.apply(delta)
        #expect(model.hiddenCount == nil)
        #expect(model.stateRejected != nil)
    }
}
