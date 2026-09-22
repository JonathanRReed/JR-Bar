import Foundation

// The `session_usage` command: `{ids[], since?}` → per-session model,
// tokens, cost and context, read incrementally from each session's own
// transcript (src/jrbar/session_usage.py). Every id comes back in exactly
// one of `sessions` or `gaps`, so "not read yet", "no transcript" and
// "this provider keeps none" are three different answers, never a zero.

public struct SessionUsageTokens: Codable, Hashable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var cacheCreation: Int
    public var output: Int

    public init(input: Int = 0, cachedInput: Int = 0, cacheCreation: Int = 0, output: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheCreation = cacheCreation
        self.output = output
    }

    public var total: Int { input + cachedInput + cacheCreation + output }

    /// Share of everything the run sent that came from the prompt cache.
    public var cacheShare: Double? {
        let sent = input + cachedInput + cacheCreation
        guard sent > 0 else { return nil }
        return Double(cachedInput) / Double(sent)
    }

    enum CodingKeys: String, CodingKey {
        case input, output
        case cachedInput = "cached_input"
        case cacheCreation = "cache_creation"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = (try? c.decodeIfPresent(Int.self, forKey: .input)) ?? 0
        cachedInput = (try? c.decodeIfPresent(Int.self, forKey: .cachedInput)) ?? 0
        cacheCreation = (try? c.decodeIfPresent(Int.self, forKey: .cacheCreation)) ?? 0
        output = (try? c.decodeIfPresent(Int.self, forKey: .output)) ?? 0
    }
}

/// One session's usage as the daemon read it from the transcript.
public struct SessionUsage: Codable, Hashable, Sendable {
    public var provider: String?
    /// The model the newest counted turn ran on, verbatim
    /// (`claude-opus-4-5-20251101`, `gpt-5.6-sol`).
    public var model: String?
    /// Tokens per model, for a run that switched models part way.
    public var models: [String: Int]
    public var tokens: SessionUsageTokens
    public var turns: Int
    /// The list-price estimate; nil when no model the run used has a price.
    public var estimatedCostUSD: Double?
    /// True when a stand-in rate priced any of it.
    public var costEstimated: Bool
    public var unpricedModels: [String]
    /// The newest main-chain turn's prompt, cache included.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// `reported` (the provider stated its window) or `inferred`.
    public var contextWindowSource: String?
    public var firstAt: Double?
    public var lastAt: Double?
    /// The transcript was too large and only its tail was read.
    public var partial: Bool
    /// Tokens from turns at or after the request's `since`.
    public var tokensSince: Int?

    public init(provider: String? = nil, model: String? = nil, models: [String: Int] = [:],
                tokens: SessionUsageTokens = SessionUsageTokens(), turns: Int = 0,
                estimatedCostUSD: Double? = nil, costEstimated: Bool = false, unpricedModels: [String] = [],
                contextTokens: Int? = nil, contextWindow: Int? = nil, contextWindowSource: String? = nil,
                firstAt: Double? = nil, lastAt: Double? = nil, partial: Bool = false, tokensSince: Int? = nil) {
        self.provider = provider
        self.model = model
        self.models = models
        self.tokens = tokens
        self.turns = turns
        self.estimatedCostUSD = estimatedCostUSD
        self.costEstimated = costEstimated
        self.unpricedModels = unpricedModels
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextWindowSource = contextWindowSource
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.partial = partial
        self.tokensSince = tokensSince
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, models, tokens, turns, partial
        case estimatedCostUSD = "estimated_cost_usd"
        case costEstimated = "cost_estimated"
        case unpricedModels = "unpriced_models"
        case contextTokens = "context_tokens"
        case contextWindow = "context_window"
        case contextWindowSource = "context_window_source"
        case firstAt = "first_at"
        case lastAt = "last_at"
        case tokensSince = "tokens_since"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        models = (try? c.decodeIfPresent([String: Int].self, forKey: .models)) ?? [:]
        tokens = (try? c.decodeIfPresent(SessionUsageTokens.self, forKey: .tokens)) ?? SessionUsageTokens()
        turns = (try? c.decodeIfPresent(Int.self, forKey: .turns)) ?? 0
        estimatedCostUSD = try? c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        costEstimated = (try? c.decodeIfPresent(Bool.self, forKey: .costEstimated)) ?? false
        unpricedModels = (try? c.decodeIfPresent([String].self, forKey: .unpricedModels)) ?? []
        contextTokens = try? c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try? c.decodeIfPresent(Int.self, forKey: .contextWindow)
        contextWindowSource = try? c.decodeIfPresent(String.self, forKey: .contextWindowSource)
        firstAt = try? c.decodeIfPresent(Double.self, forKey: .firstAt)
        lastAt = try? c.decodeIfPresent(Double.self, forKey: .lastAt)
        partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? false
        tokensSince = try? c.decodeIfPresent(Int.self, forKey: .tokensSince)
    }

    /// "Opus 4.5" — the model as a person says it.
    public var modelName: String? { ModelName.display(model) }

    /// How full the context window is, 0...1, when both sides are known.
    public var contextFraction: Double? {
        guard let used = contextTokens, let window = contextWindow, window > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(window)))
    }

    /// "≈ $1.24" — always the estimate's own mark: a list price is still
    /// not an invoice, and a subscription is not billed per token.
    public var costText: String? {
        guard let cost = estimatedCostUSD else { return nil }
        return "≈ " + UsageFormat.cost(cost)
    }

    /// "62% of 200k" / "62% of ~200k" — the tilde when the window was
    /// inferred rather than stated.
    public var contextText: String? {
        guard let fraction = contextFraction, let window = contextWindow else { return nil }
        let approx = contextWindowSource == "inferred" ? "~" : ""
        return "\(Int((fraction * 100).rounded()))% of \(approx)\(UsageFormat.tokens(window))"
    }

    /// The one-line summary a tooltip or inspector carries:
    /// "Opus 4.5 · 1.2M tokens (84% cached) · ≈ $3.10 · context 62% of ~200k".
    public var summary: String {
        var parts: [String] = []
        if let modelName { parts.append(modelName) }
        if tokens.total > 0 {
            var text = "\(UsageFormat.tokens(tokens.total)) tokens"
            if let share = tokens.cacheShare, share >= 0.01 { text += " (\(Int((share * 100).rounded()))% cached)" }
            parts.append(text)
        }
        if let costText { parts.append(costText + (costEstimated ? " (stand-in rate)" : "")) }
        if let contextText { parts.append("context \(contextText)") }
        if partial { parts.append("tail of a long transcript") }
        return parts.isEmpty ? "No usage recorded yet" : parts.joined(separator: " · ")
    }
}

public struct SessionUsageDocument: Decodable, Hashable, Sendable {
    public var sessions: [String: SessionUsage]
    public var gaps: [String: String]
    public var since: Double?

    public init(sessions: [String: SessionUsage] = [:], gaps: [String: String] = [:], since: Double? = nil) {
        self.sessions = sessions
        self.gaps = gaps
        self.since = since
    }

    enum CodingKeys: String, CodingKey { case sessions, gaps, since }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? c.decodeIfPresent([String: SessionUsage].self, forKey: .sessions)) ?? [:]
        gaps = (try? c.decodeIfPresent([String: String].self, forKey: .gaps)) ?? [:]
        since = try? c.decodeIfPresent(Double.self, forKey: .since)
    }

    /// The honest words for a gap, for a tooltip or an inspector fact.
    public static func gapText(_ gap: String) -> String {
        switch gap {
        case "remote": return "The transcript is on the peer Mac"
        case "unsupported_provider": return "This provider's transcript is not read for usage yet"
        case "transcript_not_found": return "No transcript found for this session"
        case "transcript_unreadable": return "The transcript could not be read"
        case "not_found": return "The monitor no longer holds this session"
        default: return gap.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Model ids as a person says them: `claude-opus-4-5-20251101` → "Opus
/// 4.5", `gpt-5.6-sol` → "GPT-5.6 Sol", `gemini-3.1-pro` → "Gemini 3.1
/// Pro". An id nothing here recognises passes through untouched — a raw
/// name beats a wrong one.
public enum ModelName {
    static let claudeFamilies: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]

    public static func display(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text == "<synthetic>" || text == "unknown" { return nil }
        if text.lowercased() == "codex" { return "Codex" }
        if let bracket = text.firstIndex(of: "[") { text = String(text[..<bracket]) }
        var parts = text.lowercased().split(separator: "-").map(String.init)
        // Drop the vendor prefix and a trailing snapshot date (8 digits).
        if parts.first == "claude" || parts.first == "anthropic" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        if parts.last == "latest" { parts.removeLast() }
        guard !parts.isEmpty else { return raw }

        if let familyIndex = parts.firstIndex(where: { claudeFamilies.contains($0) }) {
            let family = parts[familyIndex].capitalized
            let numbers = parts.enumerated().filter { $0.offset != familyIndex && $0.element.allSatisfy(\.isNumber) }.map(\.element)
            return numbers.isEmpty ? family : "\(family) \(numbers.joined(separator: "."))"
        }
        if parts[0] == "gpt", parts.count >= 2 {
            let rest = parts.dropFirst(2).map(word)
            return (["GPT-\(parts[1])"] + rest).joined(separator: " ")
        }
        if parts[0].hasPrefix("gpt"), parts[0].count > 3 {
            // `gpt5.6` spellings.
            let version = parts[0].dropFirst(3)
            return (["GPT-\(version)"] + parts.dropFirst().map(word)).joined(separator: " ")
        }
        if parts[0] == "gemini" {
            return (["Gemini"] + parts.dropFirst().map(word)).joined(separator: " ")
        }
        if parts[0] == "grok" {
            return (["Grok"] + parts.dropFirst().map(word)).joined(separator: " ")
        }
        return raw
    }

    /// A version stays as written ("5.6", "o3"); a word is capitalised.
    private static func word(_ part: String) -> String {
        if part.first?.isNumber == true { return part }
        return part.prefix(1).uppercased() + part.dropFirst()
    }
}

extension CoreModel {
    /// `session_usage {ids[], since?}` → per-session model, tokens, cost
    /// and context. `since` adds each session's `tokensSince`.
    public func sessionUsage(ids: [String], since: Double? = nil) async throws -> SessionUsageDocument {
        var args: [String: JSONValue] = ["ids": .array(ids.map(JSONValue.string))]
        if let since { args["since"] = .number(since) }
        return try await request("session_usage", args: args, as: SessionUsageDocument.self)
    }
}
