import JRBarUI
import Testing

@Suite("Status meaning")
struct StatusMeaningTests {
    @Test func quotaWarningsHaveNamedTones() {
        #expect(Tone.warning.color == JRBarTokens.Ink.attention)
        #expect(Tone.failure.color == JRBarTokens.Ink.failure)
        #expect(Tone.ask.color == JRBarTokens.Ink.attention)
        #expect(Tone.neutral.color == JRBarTokens.Ink.secondary)
    }
}
