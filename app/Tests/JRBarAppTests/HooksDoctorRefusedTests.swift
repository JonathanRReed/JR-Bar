import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Hooks doctor counts refused hook events")
struct HooksDoctorRefusedTests {
    static func report(sentence: String?) -> JSONValue {
        let rejected: JSONValue = sentence.map { .object(["today": .number(3), "sentence": .string($0)]) }
            ?? .object(["today": .number(0), "sentence": .null])
        return .object(["checked_at": .number(100), "providers": .array([]), "rejected": rejected])
    }

    @Test func todaysRefusalsGetTheirOwnLine() async {
        let doctor = HooksDoctorModel()
        let words = "3 hook events were refused today. The newest: the event arrived cut short."
        await doctor.refresh { CoreReply(id: "d", ok: true, result: Self.report(sentence: words)) }?.value
        #expect(doctor.refusedLine == words)
        await doctor.refresh { CoreReply(id: "d", ok: true, result: Self.report(sentence: nil)) }?.value
        #expect(doctor.refusedLine == nil)
    }
}
