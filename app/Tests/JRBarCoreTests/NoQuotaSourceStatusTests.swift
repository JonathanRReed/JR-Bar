import Testing
@testable import JRBarCore

/// A plan with no quota is an answer the daemon keeps neutral; the app
/// says "No quota source", never Unavailable or Stale.
@Suite("No quota source status")
struct NoQuotaSourceStatusTests {
    static func row(state: String, availability: String, quotaSource: Bool) -> CoreProviderUsage {
        var row = CoreProviderUsage(id: "gemini", windows: [], state: state, quotaSource: quotaSource)
        row.availability = availability
        return row
    }

    @Test(arguments: ["unsupported", "unavailable", "source_not_found", "stale"])
    func neutralWhateverTheState(_ state: String) {
        #expect(UsageStatus.provider(Self.row(state: state, availability: "available", quotaSource: false)) == .noQuotaSource)
    }

    @Test func aFailingSourceStillSaysSo() {
        #expect(UsageStatus.provider(Self.row(state: "unavailable", availability: "failing", quotaSource: true)) == .unavailable)
        #expect(UsageStatus.provider(Self.row(state: "needs_sign_in", availability: "available", quotaSource: false)) == .needsSignIn)
    }
}
