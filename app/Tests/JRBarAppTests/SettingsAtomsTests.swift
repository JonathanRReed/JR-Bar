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

/// Settings › Agents: the rows whose CLI the daemon did not find fold
/// under one "CLI not found (N)" disclosure; the rest keep their order.
@Suite struct AgentsPagePartitionTests {
    @Test func missingCLIsGroupAndUnknownsStay() {
        let detected: [String: Bool] = ["claude": true, "gemini": false, "pi": false]
        let split = AgentsPage.partition(["claude", "codex", "gemini", "grok", "pi"]) { detected[$0] }
        #expect(split.found == ["claude", "codex", "grok"], "a daemon that does not say keeps the row up top")
        #expect(split.missing == ["gemini", "pi"])
        let empty = AgentsPage.partition([]) { _ in false }
        #expect(empty.found.isEmpty && empty.missing.isEmpty)
    }
}

/// Settings › Lighting: close colour pairs sit under one line that says
/// how many there are.
@MainActor
@Suite struct ColorVisionNoteSummaryTests {
    @Test func theLineCountsThePairs() {
        #expect(ColorVisionNote.summary(1) == "Colour vision: 1 pair close — Review")
        #expect(ColorVisionNote.summary(4) == "Colour vision: 4 pairs close — Review")
    }
}
