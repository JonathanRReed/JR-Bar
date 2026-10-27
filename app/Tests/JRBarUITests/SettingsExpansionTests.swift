import JRBarUI
import SwiftUI
import Testing

@Suite("Settings expansion")
@MainActor
struct SettingsExpansionTests {
    @Test func detailsAreBuiltOnlyWhenExpanded() {
        var built = 0
        let closed = SettingsExpansionRow("Details", isExpanded: .constant(false)) {
            built += 1
            return Text("Details")
        }
        _ = closed.body
        #expect(built == 0)
        let open = SettingsExpansionRow("Details", isExpanded: .constant(true)) {
            built += 1
            return Text("Details")
        }
        #expect(built == 0)
        _ = open.body
        #expect(built == 1)
    }
}
