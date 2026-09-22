import Testing
@testable import JRBarApp

@MainActor
@Suite struct SettingsReadoutTests {
    @Test func pointReadoutsPreserveFractionalSettings() {
        #expect(SettingsStore.points(8) == "8 pt")
        #expect(SettingsStore.points(12.5) == "12.5 pt")
        #expect(SettingsStore.points(1200) == "1200 pt")
    }
}
