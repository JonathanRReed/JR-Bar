import Testing
@testable import JRBarApp

@Suite("History event rows")
struct EventLogRowTests {
    @Test func theKindColumnShowsOnlyWhenTheHeadlineDoesNotSayIt() {
        #expect(EventLogRow.kindColumn(kind: "device_connected", headline: "Device connected · Test light") == nil)
        #expect(EventLogRow.kindColumn(kind: "deck_receipt", headline: "Opened History") != nil)
    }
}
