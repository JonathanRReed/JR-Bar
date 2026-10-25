import Foundation
import Testing
@testable import JRBarCore

@MainActor @Suite("Event gap detection")
struct EventGapTests {
    @Test func overflowReportsGapWithoutInventingEvents() {
        let core = CoreModel()
        for i in 0..<40 { core.apply(.event(CoreEvent(id: "ev-\(i)", kind: "completed"))) }
        let read = core.readEvents(after: 0)
        #expect(read.hasGap && read.events.count == 32)
        #expect(read.events.first?.id == "ev-8")
        #expect(!core.readEvents(after: 8).hasGap)
        #expect(core.readEvents(after: 40).events.isEmpty)
    }

    @Test func reusedIDsInANewStreamAdvanceSequence() throws {
        let core = CoreModel()
        for stream in ["first", "second"] {
            let json = #"{"v":1,"core_version":"fixture","pid":1,"capabilities":[],"stream":"\#(stream)"}"#
            core.apply(.hello(try JSONDecoder().decode(CoreHello.self, from: Data(json.utf8))))
            core.apply(.event(CoreEvent(id: "ev-1", kind: "quota_reset")))
        }
        #expect(core.eventSequence == 2)
        #expect(core.events(after: 0).count == 2)
    }
}
