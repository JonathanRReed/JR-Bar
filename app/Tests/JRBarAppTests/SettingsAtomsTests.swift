import AppKit
import SwiftUI
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

/// The Settings window's shared shapes: the sidebar's runs, the page
/// headers, the card hues and the chip row's wrapping.
@MainActor
@Suite struct SettingsVisualSystemTests {
    @Test func everyPageSitsInExactlyOneSidebarRun() {
        let listed = SettingsStore.Page.sidebarGroups.flatMap { $0 }
        #expect(listed.count == SettingsStore.Page.allCases.count, "no page listed twice")
        #expect(Set(listed) == Set(SettingsStore.Page.allCases), "no page left out of the sidebar")
        #expect(listed.first == .general)
    }

    @Test func everyPageHeaderSaysWhatThePageIsFor() {
        let blurbs = SettingsStore.Page.allCases.map(\.blurb)
        #expect(blurbs.allSatisfy { !$0.isEmpty && $0.hasSuffix(".") })
        #expect(Set(blurbs).count == blurbs.count)
    }

    @Test func eachCardWearsItsOwnHueAndAnUnknownOneThePages() {
        let page = Color.pink
        let ids = ["menuBar", "notch", "dock", "agents", "data-hoarder", "fold", "aquarium", "notch-buddy",
                   "confetti"]
        let tints = ids.map { ToyCard.tint(for: $0, page: page).description }
        #expect(Set(tints).count == ids.count, "no two named cards share a hue")
        #expect(ToyCard.tint(for: "a-toy-yet-to-come", page: page) == page)
    }

    @Test func aChordReadsAsTheKeysAPersonPresses() {
        #expect(ShortcutRecorderLogic.keycaps("⌃⌥J") == ["⌃", "⌥", "J"])
        #expect(ShortcutRecorderLogic.keycaps("⌥⇧⌘F12") == ["⌥", "⇧", "⌘", "F12"])
        #expect(ShortcutRecorderLogic.keycaps("⌃⌥⌘→") == ["⌃", "⌥", "⌘", "→"])
        #expect(ShortcutRecorderLogic.keycaps("Space") == ["Space"])
        #expect(ShortcutRecorderLogic.keycaps("").isEmpty)
    }

    @Test func chipsWrapOntoANewLineWhenTheRowIsFull() {
        func height(width: CGFloat) -> CGFloat {
            let row = FlowLayout(spacing: 8, lineSpacing: 6) {
                ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: 60, height: 20) }
            }
            .frame(width: width)
            return NSHostingView(rootView: row).fittingSize.height
        }
        let wide = height(width: 400)
        let narrow = height(width: 140)
        let threeLines: CGFloat = 20 * 3 + 6 * 2
        #expect(wide == 20, "five 60 pt chips fit one 400 pt line")
        #expect(narrow == threeLines, "two to a 140 pt line: three lines")
    }
}
