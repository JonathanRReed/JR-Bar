import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Disabled setting reasons")
@MainActor
struct DisabledSettingReasonTests {
    @Test func everyDisabledAvailabilityStateHasAReason() {
        #expect(Provided<Text>.reason(live: false, hasDocument: true, provided: true)
                == "Reconnect to change this setting.")
        #expect(Provided<Text>.reason(live: true, hasDocument: false, provided: false)
                == "Waiting for settings.")
        #expect(Provided<Text>.reason(live: true, hasDocument: true, provided: false)
                == "Not in this version")
        #expect(Provided<Text>.reason(live: true, hasDocument: true, provided: true) == nil)
    }
}
