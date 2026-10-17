import Testing
@testable import JRBarCore

@Suite("Usage pool labels")
struct UsagePoolLabelTests {
    @Test("Argon stays separate from Gemini and shared Claude + GPT pools")
    func poolLabels() {
        #expect(UsageWindowLabel.short(id: "gemini-argon-weekly", name: "Gemini 4 Argon Weekly") == "Argon")
        #expect(UsageWindowLabel.short(id: "gemini-weekly", name: "Gemini Weekly") == "Gemini")
        #expect(UsageWindowLabel.short(id: "claude-gpt-five-hour", name: "Claude + GPT 5h") == "Claude+GPT")
        #expect(UsageWindowLabel.cadence(id: "gemini-argon-weekly", name: nil) == "7d")
        #expect(UsageWindowLabel.cadence(id: "gemini-five-hour", name: nil) == "5h")
        #expect(UsageWindowLabel.cadence(id: "claude-gpt-weekly", name: nil) == "7d")
        #expect(UsageWindowLabel.cadence(id: "unknown-pool", name: nil) == nil)
        #expect(UsageWindowLabel.short(id: nil, name: "Gemini4ArgonWeekly") == "Argon")
        #expect(UsageWindowLabel.short(id: "claude-gpt-weekly", name: "Claude + GPT Weekly") == "Claude+GPT")
        #expect(UsageWindowLabel.cadence(id: "gemini-argon-five-hour", name: nil) == "5h")
        #expect(UsageWindowLabel.cadence(id: "weekly", name: "Weekly") == nil)
        #expect(UsageWindowLabel.short(id: "weekly", name: "Weekly") == "7d")
        #expect(UsageWindowLabel.ringTitle(id: "weekly", name: "Weekly") == "7d")
        #expect(UsageWindowLabel.ringTitle(id: "gemini-argon-weekly", name: "Gemini 4 Argon Weekly") == "Argon")
        #expect(UsageWindowLabel.cadence(id: "standard-other", name: nil) == nil)
        #expect(UsageWindowLabel.ringTitle(id: "other", name: "Custom") == "Custom")
    }
}
