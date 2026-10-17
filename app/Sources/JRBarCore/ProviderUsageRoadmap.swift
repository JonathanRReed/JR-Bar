import Foundation

// Provider catalog derived from steipete/CodexBar, MIT, pinned at 6480977b47f6e4ffd5dcaae1cb0c7fdf34ee449e.
public struct ProviderRoadmapEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let registeredProviderID: String
}

public enum ProviderUsageRoadmap {
    public static let entries: [ProviderRoadmapEntry] = [
        ProviderRoadmapEntry(id: "abacus", name: "Abacus AI", registeredProviderID: "abacus"),
        ProviderRoadmapEntry(id: "aerostack", name: "Aerostack", registeredProviderID: "aerostack"),
        ProviderRoadmapEntry(id: "aiand", name: "ai&", registeredProviderID: "aiand"),
        ProviderRoadmapEntry(id: "aixy", name: "Aixy", registeredProviderID: "aixy"),
        ProviderRoadmapEntry(id: "alibaba", name: "Alibaba Coding Plan", registeredProviderID: "alibaba"),
        ProviderRoadmapEntry(
            id: "alibabatokenplan", name: "Alibaba Token Plan", registeredProviderID: "alibabatokenplan"),
        ProviderRoadmapEntry(id: "amp", name: "Amp", registeredProviderID: "amp"),
        ProviderRoadmapEntry(id: "antigravity", name: "Antigravity", registeredProviderID: "antigravity"),
        ProviderRoadmapEntry(id: "atlascloud", name: "Atlas Cloud", registeredProviderID: "atlascloud"),
        ProviderRoadmapEntry(id: "augment", name: "Augment", registeredProviderID: "augment"),
        ProviderRoadmapEntry(id: "bedrock", name: "AWS Bedrock", registeredProviderID: "bedrock"),
        ProviderRoadmapEntry(id: "azureopenai", name: "Azure OpenAI", registeredProviderID: "azureopenai"),
        ProviderRoadmapEntry(id: "bifrost", name: "Bifrost", registeredProviderID: "bifrost"),
        ProviderRoadmapEntry(id: "hyper", name: "Charm Hyper", registeredProviderID: "hyper"),
        ProviderRoadmapEntry(id: "chutes", name: "Chutes", registeredProviderID: "chutes"),
        ProviderRoadmapEntry(id: "claude", name: "Claude", registeredProviderID: "claude"),
        ProviderRoadmapEntry(id: "claudeplatform", name: "Claude Platform", registeredProviderID: "claudeplatform"),
        ProviderRoadmapEntry(id: "clawrouter", name: "ClawRouter", registeredProviderID: "clawrouter"),
        ProviderRoadmapEntry(id: "clinepass", name: "ClinePass", registeredProviderID: "clinepass"),
        ProviderRoadmapEntry(id: "codebuff", name: "Codebuff", registeredProviderID: "codebuff"),
        ProviderRoadmapEntry(id: "coderabbit", name: "CodeRabbit", registeredProviderID: "coderabbit"),
        ProviderRoadmapEntry(id: "codex", name: "Codex", registeredProviderID: "codex"),
        ProviderRoadmapEntry(id: "commandcode", name: "Command Code", registeredProviderID: "commandcode"),
        ProviderRoadmapEntry(id: "copilot", name: "Copilot", registeredProviderID: "copilot"),
        ProviderRoadmapEntry(id: "cosmic", name: "Cosmic AI", registeredProviderID: "cosmic"),
        ProviderRoadmapEntry(id: "cursor", name: "Cursor", registeredProviderID: "cursor"),
        ProviderRoadmapEntry(id: "deepgram", name: "Deepgram", registeredProviderID: "deepgram"),
        ProviderRoadmapEntry(id: "deepinfra", name: "DeepInfra", registeredProviderID: "deepinfra"),
        ProviderRoadmapEntry(id: "deepseek", name: "DeepSeek", registeredProviderID: "deepseek"),
        ProviderRoadmapEntry(id: "devin", name: "Devin", registeredProviderID: "devin"),
        ProviderRoadmapEntry(id: "devpass", name: "DevPass", registeredProviderID: "devpass"),
        ProviderRoadmapEntry(id: "doubao", name: "Doubao", registeredProviderID: "doubao"),
        ProviderRoadmapEntry(id: "factory", name: "Droid", registeredProviderID: "factory"),
        ProviderRoadmapEntry(id: "elevenlabs", name: "ElevenLabs", registeredProviderID: "elevenlabs"),
        ProviderRoadmapEntry(id: "exa", name: "Exa", registeredProviderID: "exa"),
        ProviderRoadmapEntry(id: "fal", name: "fal", registeredProviderID: "fal"),
        ProviderRoadmapEntry(id: "fireworks", name: "Fireworks", registeredProviderID: "fireworks"),
        ProviderRoadmapEntry(id: "flora", name: "FLORA", registeredProviderID: "flora"),
        ProviderRoadmapEntry(id: "futureagi", name: "Future AGI", registeredProviderID: "futureagi"),
        ProviderRoadmapEntry(id: "gemini", name: "Gemini", registeredProviderID: "gemini"),
        ProviderRoadmapEntry(id: "gitkraken", name: "GitKraken AI", registeredProviderID: "gitkraken"),
        ProviderRoadmapEntry(id: "grok", name: "Grok", registeredProviderID: "grok"),
        ProviderRoadmapEntry(id: "groq", name: "Groq", registeredProviderID: "groq"),
        ProviderRoadmapEntry(id: "helmcode", name: "Helmcode", registeredProviderID: "helmcode"),
        ProviderRoadmapEntry(id: "huggingface", name: "Hugging Face", registeredProviderID: "huggingface"),
        ProviderRoadmapEntry(id: "ibmbob", name: "IBM Bob", registeredProviderID: "ibmbob"),
        ProviderRoadmapEntry(id: "jetbrains", name: "JetBrains AI", registeredProviderID: "jetbrains"),
        ProviderRoadmapEntry(id: "kilo", name: "Kilo", registeredProviderID: "kilo"),
        ProviderRoadmapEntry(id: "kimi", name: "Kimi", registeredProviderID: "kimi"),
        ProviderRoadmapEntry(id: "kiro", name: "Kiro", registeredProviderID: "kiro"),
        ProviderRoadmapEntry(id: "langdock", name: "Langdock", registeredProviderID: "langdock"),
        ProviderRoadmapEntry(id: "linkup", name: "Linkup", registeredProviderID: "linkup"),
        ProviderRoadmapEntry(id: "litellm", name: "LiteLLM", registeredProviderID: "litellm"),
        ProviderRoadmapEntry(id: "lithosai", name: "LithosAI", registeredProviderID: "lithosai"),
        ProviderRoadmapEntry(id: "llmproxy", name: "LLM Proxy", registeredProviderID: "llmproxy"),
        ProviderRoadmapEntry(id: "llmman", name: "llmman", registeredProviderID: "llmman"),
        ProviderRoadmapEntry(id: "longcat", name: "LongCat", registeredProviderID: "longcat"),
        ProviderRoadmapEntry(id: "manus", name: "Manus", registeredProviderID: "manus"),
        ProviderRoadmapEntry(id: "minimax", name: "MiniMax", registeredProviderID: "minimax"),
        ProviderRoadmapEntry(id: "mistral", name: "Mistral", registeredProviderID: "mistral"),
        ProviderRoadmapEntry(id: "moonshot", name: "Moonshot", registeredProviderID: "moonshot"),
        ProviderRoadmapEntry(id: "munito", name: "Munito", registeredProviderID: "munito"),
        ProviderRoadmapEntry(id: "museai", name: "Muse (muse.ai)", registeredProviderID: "museai"),
        ProviderRoadmapEntry(id: "muse", name: "Muse Code", registeredProviderID: "muse"),
        ProviderRoadmapEntry(id: "neuralwatt", name: "Neuralwatt", registeredProviderID: "neuralwatt"),
        ProviderRoadmapEntry(id: "notion", name: "Notion AI", registeredProviderID: "notion"),
        ProviderRoadmapEntry(id: "nous", name: "Nous Portal", registeredProviderID: "nous"),
        ProviderRoadmapEntry(id: "ollama", name: "Ollama", registeredProviderID: "ollama"),
        ProviderRoadmapEntry(id: "openai", name: "OpenAI", registeredProviderID: "openai-api"),
        ProviderRoadmapEntry(id: "opencode", name: "OpenCode", registeredProviderID: "opencode"),
        ProviderRoadmapEntry(id: "opencodego", name: "OpenCode Go", registeredProviderID: "opencode"),
        ProviderRoadmapEntry(id: "openrouter", name: "OpenRouter", registeredProviderID: "openrouter"),
        ProviderRoadmapEntry(id: "parallel", name: "Parallel", registeredProviderID: "parallel"),
        ProviderRoadmapEntry(id: "perplexity", name: "Perplexity", registeredProviderID: "perplexity"),
        ProviderRoadmapEntry(id: "pi", name: "Pi", registeredProviderID: "pi"),
        ProviderRoadmapEntry(id: "poe", name: "Poe", registeredProviderID: "poe"),
        ProviderRoadmapEntry(id: "qoder", name: "Qoder", registeredProviderID: "qoder"),
        ProviderRoadmapEntry(id: "qwencloud", name: "Qwen Cloud", registeredProviderID: "qwencloud"),
        ProviderRoadmapEntry(id: "raycast", name: "Raycast", registeredProviderID: "raycast"),
        ProviderRoadmapEntry(id: "replicate", name: "Replicate", registeredProviderID: "replicate"),
        ProviderRoadmapEntry(id: "sailresearch", name: "Sail Research", registeredProviderID: "sailresearch"),
        ProviderRoadmapEntry(id: "sakana", name: "Sakana AI", registeredProviderID: "sakana"),
        ProviderRoadmapEntry(id: "sofya", name: "Sofya", registeredProviderID: "sofya"),
        ProviderRoadmapEntry(id: "stepfun", name: "StepFun", registeredProviderID: "stepfun"),
        ProviderRoadmapEntry(id: "sub2api", name: "sub2api", registeredProviderID: "sub2api"),
        ProviderRoadmapEntry(id: "synthetic", name: "Synthetic", registeredProviderID: "synthetic"),
        ProviderRoadmapEntry(id: "t3chat", name: "T3 Chat", registeredProviderID: "t3chat"),
        ProviderRoadmapEntry(id: "tavily", name: "Tavily", registeredProviderID: "tavily"),
        ProviderRoadmapEntry(id: "tinyapi", name: "TinyApi", registeredProviderID: "tinyapi"),
        ProviderRoadmapEntry(id: "typesafe", name: "TypeSafe", registeredProviderID: "typesafe"),
        ProviderRoadmapEntry(id: "v0", name: "v0", registeredProviderID: "v0"),
        ProviderRoadmapEntry(id: "venice", name: "Venice", registeredProviderID: "venice"),
        ProviderRoadmapEntry(id: "vercel", name: "Vercel AI Gateway", registeredProviderID: "vercel"),
        ProviderRoadmapEntry(id: "vertexai", name: "Vertex AI", registeredProviderID: "vertexai"),
        ProviderRoadmapEntry(id: "warp", name: "Warp", registeredProviderID: "warp"),
        ProviderRoadmapEntry(id: "wayfinder", name: "Wayfinder", registeredProviderID: "wayfinder"),
        ProviderRoadmapEntry(id: "windsurf", name: "Windsurf", registeredProviderID: "windsurf"),
        ProviderRoadmapEntry(id: "workbuddy", name: "WorkBuddy", registeredProviderID: "workbuddy"),
        ProviderRoadmapEntry(id: "xapi", name: "X API", registeredProviderID: "xapi"),
        ProviderRoadmapEntry(id: "xai", name: "xAI", registeredProviderID: "xai"),
        ProviderRoadmapEntry(id: "mimo", name: "Xiaomi MiMo", registeredProviderID: "mimo"),
        ProviderRoadmapEntry(id: "xkiro", name: "xKiro", registeredProviderID: "xkiro"),
        ProviderRoadmapEntry(id: "zai", name: "z.ai", registeredProviderID: "zai"),
        ProviderRoadmapEntry(id: "zed", name: "Zed", registeredProviderID: "zed"),
        ProviderRoadmapEntry(id: "zenmux", name: "ZenMux", registeredProviderID: "zenmux"),
        ProviderRoadmapEntry(id: "zoommate", name: "ZoomMate", registeredProviderID: "zoommate"),
    ]

    public static func upcoming(
        availableProviderIDs: Set<String>,
        query: String = "") -> [ProviderRoadmapEntry]
    {
        guard !availableProviderIDs.isEmpty else { return [] }

        let search = searchKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return entries
            .filter { entry in
                guard !availableProviderIDs.contains(entry.registeredProviderID) else { return false }
                guard !search.isEmpty else { return true }
                return searchKey(entry.name).contains(search) || searchKey(entry.id).contains(search)
            }
            .sorted { left, right in
                let leftName = searchKey(left.name)
                let rightName = searchKey(right.name)
                if leftName != rightName { return leftName < rightName }
                return left.id < right.id
            }
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }
}
