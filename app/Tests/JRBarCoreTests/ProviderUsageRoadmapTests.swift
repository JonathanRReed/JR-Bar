import Foundation
import Testing
@testable import JRBarCore

@Suite("Provider usage roadmap")
struct ProviderUsageRoadmapTests {
    private let currentProviderIDs: Set<String> = [
        "codex", "claude", "cursor", "devin", "grok", "gemini", "antigravity",
        "opencode", "factory", "openai-api", "kimi", "kilo", "kiro",
    ]

    @Test("catalog has 106 unique provider IDs")
    func catalogIsCompleteAndUnique() {
        let entries = ProviderUsageRoadmap.entries
        #expect(entries.count == 106)
        #expect(Set(entries.map(\.id)).count == 106)
    }

    @Test("maps related catalog products to their registered provider IDs")
    func registeredProviderAliases() throws {
        let entries = ProviderUsageRoadmap.entries
        let openAI = try #require(entries.first { $0.id == "openai" })
        let openCodeGo = try #require(entries.first { $0.id == "opencodego" })
        #expect(openAI.registeredProviderID == "openai-api")
        #expect(openCodeGo.registeredProviderID == "opencode")
    }

    @Test("excludes available providers and returns the expected planned count")
    func excludesCurrentProviders() {
        let upcoming = ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs)
        #expect(upcoming.count == 92)
        #expect(upcoming.allSatisfy { !currentProviderIDs.contains($0.registeredProviderID) })
        let normalizedNames = upcoming.map { Self.searchKey($0.name) }
        #expect(normalizedNames == normalizedNames.sorted())
    }

    @Test("search cannot bring an available provider back")
    func searchStillExcludesAvailableProviders() {
        let openAIMatches = ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs, query: "openai")
        #expect(openAIMatches.map(\.id) == ["azureopenai"])
        #expect(openAIMatches.allSatisfy { !currentProviderIDs.contains($0.registeredProviderID) })
        #expect(ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs, query: "OpenCode")
            .allSatisfy { $0.id != "opencode" && $0.id != "opencodego" })
    }

    @Test("search matches names and IDs without case or diacritic sensitivity")
    func searchMatchesNameAndID() {
        let byName = ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs, query: "cOpIlót")
        #expect(byName.map(\.id) == ["copilot"])
        let byID = ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs, query: "deepseek")
        #expect(byID.map(\.id) == ["deepseek"])
    }

    @Test("empty inventory and no-match queries return no roadmap rows")
    func emptyAndNoMatch() {
        #expect(ProviderUsageRoadmap.upcoming(availableProviderIDs: []).isEmpty)
        #expect(ProviderUsageRoadmap.upcoming(
            availableProviderIDs: currentProviderIDs,
            query: "no-such-provider").isEmpty)
    }

    @Test("whitespace-only search is treated as an empty query")
    func whitespaceQuery() {
        #expect(ProviderUsageRoadmap.upcoming(availableProviderIDs: currentProviderIDs, query: "  \n\t  ").count == 92)
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }
}
