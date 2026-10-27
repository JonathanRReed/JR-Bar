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

    @Test func hookWordsAndTonesAgree() {
        #expect(HookStatus("stale").word == "Quiet")
        #expect(HookStatus("stale").tone == .neutral)
        #expect(HookStatus("ok").tone == .live)
        #expect(HookStatus(nil).word == "Not reported")
        #expect(UsageStatus.noReading.word == "No reading")
        #expect(UsageStatus.runsOut.tone == .warning)
        #expect(UsageStatus.usedUp.tone == .failure)
        #expect(UsageGaugeReading.CaptionTone.attention.tone == .warning)
        #expect(UsageGaugeReading.CaptionTone.failure.tone == .failure)
    }
}
