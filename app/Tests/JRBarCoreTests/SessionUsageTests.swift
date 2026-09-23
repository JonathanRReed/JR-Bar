import Foundation
import Testing
@testable import JRBarCore

@Suite("Session usage")
struct SessionUsageTests {
    static let wire = """
    {"schema": 1,
     "sessions": {"claude:1": {
        "provider": "claude", "model": "claude-opus-4-5-20251101",
        "models": {"claude-opus-4-5-20251101": 2340},
        "tokens": {"input": 20, "cached_input": 2000, "cache_creation": 200, "output": 120},
        "turns": 2, "estimated_cost_usd": 3.1, "cost_estimated": false, "unpriced_models": [],
        "context_tokens": 124000, "context_window": 200000, "context_window_source": "inferred",
        "first_at": 1788900000, "last_at": 1788900600, "partial": false, "tokens_since": 900}},
     "gaps": {"remote:studio:claude:x": "remote", "grok:2": "unsupported_provider"},
     "since": 1788890000,
     "pricing": {"as_of": "2026-09-20", "table_version": "jrbar-rates-v3", "semantics": "api_equivalent_estimate"}}
    """

    @Test("the wire document decodes every field, and ids land in sessions or gaps")
    func decodes() throws {
        let document = try JSONDecoder().decode(SessionUsageDocument.self, from: Data(Self.wire.utf8))
        let usage = try #require(document.sessions["claude:1"])
        #expect(usage.model == "claude-opus-4-5-20251101")
        #expect(usage.tokens.total == 2340)
        #expect(usage.turns == 2)
        #expect(usage.tokensSince == 900)
        #expect(usage.contextWindowSource == "inferred")
        #expect(document.gaps["remote:studio:claude:x"] == "remote")
        #expect(document.since == 1_788_890_000)
    }

    @Test("a sparse row still decodes: missing fields are absent, not zero-filled lies")
    func sparse() throws {
        let usage = try JSONDecoder().decode(SessionUsage.self, from: Data(#"{"provider":"codex"}"#.utf8))
        #expect(usage.model == nil)
        #expect(usage.estimatedCostUSD == nil)
        #expect(usage.contextFraction == nil)
        #expect(usage.costText == nil)
        #expect(usage.summary == "No usage recorded yet")
    }

    @Test("context, cost and the summary line say what is known and mark the inferred")
    func summary() throws {
        let document = try JSONDecoder().decode(SessionUsageDocument.self, from: Data(Self.wire.utf8))
        let usage = try #require(document.sessions["claude:1"])
        #expect(usage.contextFraction == 0.62)
        #expect(usage.contextText == "62% of ~200k")
        #expect(usage.costText == "≈ $3.10")
        #expect(usage.tokens.cacheShare.map { ($0 * 100).rounded() } == 90)
        #expect(usage.summary == "Opus 4.5 · 2.3k tokens (90% cached) · ≈ $3.10 · context 62% of ~200k")
    }

    @Test("a stated window drops the tilde; a stand-in price says so")
    func reportedWindow() {
        let usage = SessionUsage(model: "gpt-5.6-sol", tokens: SessionUsageTokens(input: 500, output: 90),
                                 estimatedCostUSD: 0.01, costEstimated: true,
                                 contextTokens: 129_200, contextWindow: 258_400, contextWindowSource: "reported")
        #expect(usage.contextText == "50% of 258k")
        #expect(usage.summary.contains("(stand-in rate)"))
    }

    @Test("model ids read the way a person says them", arguments: [
        ("claude-opus-4-5-20251101", "Opus 4.5"),
        ("claude-sonnet-4-20250514", "Sonnet 4"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-4-1[1m]", "Opus 4.1"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gemini-3.1-pro", "Gemini 3.1 Pro"),
        ("codex", "Codex"),
        ("some-local-model", "some-local-model"),
    ])
    func modelNames(raw: String, expected: String) {
        #expect(ModelName.display(raw) == expected)
    }

    @Test("placeholders are not models")
    func placeholders() {
        #expect(ModelName.display("<synthetic>") == nil)
        #expect(ModelName.display("  ") == nil)
        #expect(ModelName.display(nil) == nil)
    }

    @Test("gap words are plain")
    func gapWords() {
        #expect(SessionUsageDocument.gapText("remote") == "The transcript is on the peer Mac")
        #expect(SessionUsageDocument.gapText("some_new_gap") == "some new gap")
        #expect(SessionUsageDocument.gapText("reading") == "Still reading the transcript")
    }
}
