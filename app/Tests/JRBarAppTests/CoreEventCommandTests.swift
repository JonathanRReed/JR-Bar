import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// A Creator Micro key's window and ask requests reach the app as daemon
/// events and run as the commands a `jrbar://` link would.
@Suite struct CoreEventCommandTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decoded(_ json: String) throws -> CoreEvent {
        let frame = Data(#"{"t":"event","v":1,"# .utf8) + Data(json.utf8) + Data("}".utf8)
        guard case .event(let event) = try CoreCodec.decode(frame: frame) else {
            Issue.record("not an event frame")
            return CoreEvent(id: "", kind: "")
        }
        return event
    }

    @Test func aWindowRequestDecodesAndOpensThatWindow() throws {
        let event = try decoded(#""id":"ev-1","kind":"open_window","window":"control-center","at":1800000000"#)
        #expect(event.kind == CoreEvent.openWindowKind)
        #expect(event.window == "control-center")
        #expect(AppCommand.requested(by: event, now: now) == .window(.controlCenter))
        for window in ["overview", "usage"] {
            let request = CoreEvent(id: "w", kind: CoreEvent.openWindowKind, at: now.timeIntervalSince1970, window: window)
            #expect(AppCommand.requested(by: request, now: now) == .window(AppCommand.AppWindow(rawValue: window)!))
        }
    }

    @Test func theAskKeyRevealsTheAskAndNeverAnswersIt() throws {
        let event = try decoded(#""id":"ev-2","kind":"reveal_ask","at":1800000000"#)
        #expect(AppCommand.requested(by: event, now: now) == .revealAsk)
    }

    @Test func anythingElseIsRefusedWhole() {
        let at = now.timeIntervalSince1970
        let unknown = CoreEvent(id: "a", kind: CoreEvent.openWindowKind, at: at, window: "nowhere")
        let missing = CoreEvent(id: "b", kind: CoreEvent.openWindowKind, at: at)
        let other = CoreEvent(id: "c", kind: "completed", at: at, window: "overview")
        #expect(AppCommand.requested(by: unknown, now: now) == nil)
        #expect(AppCommand.requested(by: missing, now: now) == nil)
        #expect(AppCommand.requested(by: other, now: now) == nil)
    }

    @Test func aRequestReplayedLateOpensNothing() {
        let stale = now.timeIntervalSince1970 - AppCommand.coreRequestMaximumAge - 1
        let window = CoreEvent(id: "d", kind: CoreEvent.openWindowKind, at: stale, window: "overview")
        let ask = CoreEvent(id: "e", kind: CoreEvent.revealAskKind, at: stale)
        #expect(AppCommand.requested(by: window, now: now) == nil)
        #expect(AppCommand.requested(by: ask, now: now) == nil)
    }
}
