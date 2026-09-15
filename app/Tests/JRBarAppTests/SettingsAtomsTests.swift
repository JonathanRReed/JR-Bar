import Testing
@testable import JRBarApp

/// `MultiSelectMenu.summary`: the button's one-line answer to "what is
/// selected" — "None", "All", or the first names and "+N" for the rest.
@Suite struct MultiSelectMenuSummaryTests {
    static let providers: [(value: String, label: String)] = [
        ("claude", "Claude"), ("codex", "Codex"), ("gemini", "Gemini"),
        ("pi", "Pi"), ("grok", "Grok"),
    ]

    @Test func nothingSelectedReadsNone() {
        #expect(MultiSelectMenu.summary(selected: [], options: Self.providers) == "None")
    }

    @Test func everythingSelectedReadsAll() {
        #expect(MultiSelectMenu.summary(selected: ["claude", "codex", "gemini", "pi", "grok"],
                                        options: Self.providers) == "All")
    }

    @Test func upToTwoNamesAreSpelledOut() {
        #expect(MultiSelectMenu.summary(selected: ["claude"], options: Self.providers) == "Claude")
        #expect(MultiSelectMenu.summary(selected: ["claude", "codex"], options: Self.providers) == "Claude, Codex")
    }

    @Test func theRemainderBecomesPlusN() {
        #expect(MultiSelectMenu.summary(selected: ["claude", "codex", "gemini", "pi"],
                                        options: Self.providers) == "Claude, Codex, +2")
        #expect(MultiSelectMenu.summary(selected: ["pi", "grok", "claude"],
                                        options: Self.providers) == "Claude, Pi, +1")
    }

    @Test func theOrderFollowsTheOptionsNotTheSelection() {
        // "codex" was selected first, but the option list leads.
        #expect(MultiSelectMenu.summary(selected: ["codex", "claude"],
                                        options: Self.providers) == "Claude, Codex")
    }

    @Test func unknownSelectedValuesAreNotNamed() {
        // A value with no option is still in the document; it just has no
        // label to say.
        #expect(MultiSelectMenu.summary(selected: ["claude", "mystery"],
                                        options: Self.providers) == "Claude")
        #expect(MultiSelectMenu.summary(selected: ["mystery"], options: Self.providers) == "None")
    }

    @Test func noOptionsReadsNoneNotAll() {
        #expect(MultiSelectMenu.summary(selected: [], options: []) == "None")
    }

    @Test func theNameBudgetIsAdjustable() {
        #expect(MultiSelectMenu.summary(selected: ["claude", "codex", "gemini"],
                                        options: Self.providers, maxNames: 3) == "Claude, Codex, Gemini")
        #expect(MultiSelectMenu.summary(selected: ["claude", "codex", "gemini"],
                                        options: Self.providers, maxNames: 1) == "Claude, +2")
    }
}
