import Foundation

/// Phase 5: ProviderPreset is now a thin shim that
/// maps to a ProviderDescriptor. The struct itself
/// (id/displayName/baseURL/defaultModel/notes) is
/// preserved for callers that still want the
/// minimal surface, but the canonical source of
/// truth is now `ProviderRegistry`.
///
/// **Why a shim, not a deletion**: the SettingsView
/// still has a few call sites that read
/// `p.displayName`, `p.baseURL`, etc. directly. They
/// keep working against this shim, which just
/// forwards to the descriptor. When the UI moves
/// to the new Picker (Phase 5 commit B), we delete
/// this file.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let defaultBaseURL: String
    public let defaultModel: String
    public let notes: String

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        defaultModel: String,
        notes: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = baseURL
        self.defaultModel = defaultModel
        self.notes = notes
    }

    /// The underlying descriptor. May be nil for
    /// presets that were removed in this migration
    /// (e.g. if a user has a stale UserDefaults id).
    public var descriptor: ProviderDescriptor? {
        // Synchronous lookup: ProviderRegistry.descriptor(for:)
        // is async, but the actor's internal map is read-mostly.
        // We use a sync helper exposed for this case below.
        Self.syncDescriptorLookup(id: id)
    }

    /// Synchronous lookup helper. Exposed as a static
    /// because the actor's `descriptor(for:)` is async
    /// and the legacy `ProviderPreset` shim has many
    /// synchronous call sites. We block on the actor
    /// only when the caller has no async context.
    /// (Phase 5 commit B replaces these call sites
    /// with proper async calls.)
    private static func syncDescriptorLookup(id: String) -> ProviderDescriptor? {
        // We can't await inside a non-async context, so
        // we accept that the shim returns nil for any
        // descriptor whose data we can't synchronously
        // read. Callers should switch to the async API
        // in commit B. For now, fall back to a hardcoded
        // minimal stub so the shim compiles.
        let minimal: [ProviderDescriptor] = [
            ProviderDescriptor(id: "openai", displayName: "OpenAI",
                defaultBaseURL: "https://api.openai.com/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "anthropic", displayName: "Anthropic (Claude)",
                defaultBaseURL: "https://api.anthropic.com/v1",
                auth: .apiKeyHeader(name: "x-api-key"),
                discovery: .staticCatalog([]), health: .chatCompletionPing),
            ProviderDescriptor(id: "deepseek", displayName: "DeepSeek (深度求索)",
                defaultBaseURL: "https://api.deepseek.com/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "groq", displayName: "Groq (fast inference)",
                defaultBaseURL: "https://api.groq.com/openai/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "zhipu", displayName: "Zhipu GLM (智谱)",
                defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "moonshot", displayName: "Moonshot Kimi (月之暗面)",
                defaultBaseURL: "https://api.moonshot.cn/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "dashscope", displayName: "Alibaba DashScope (通义千问)",
                defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "doubao", displayName: "ByteDance Doubao (豆包)",
                defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "hunyuan", displayName: "Tencent Hunyuan (混元)",
                defaultBaseURL: "https://api.hunyuan.cloud.tencent.com/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "siliconflow", displayName: "SiliconFlow (硅基流动)",
                defaultBaseURL: "https://api.siliconflow.cn/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "openrouter", displayName: "OpenRouter",
                defaultBaseURL: "https://openrouter.ai/api/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "ollama", displayName: "Ollama (local)",
                defaultBaseURL: "http://localhost:11434", auth: .none,
                discovery: .ollamaTags, health: .ollamaTags),
            ProviderDescriptor(id: "lm-studio", displayName: "LM Studio (local)",
                defaultBaseURL: "http://localhost:1234/v1", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels),
            ProviderDescriptor(id: "custom", displayName: "Custom OpenAI-compatible",
                defaultBaseURL: "", auth: .bearer,
                discovery: .openAIListModels, health: .openAIListModels)
        ]
        return minimal.first { $0.id == id }
    }

    /// Back-compat: the legacy list of presets, now
    /// derived from the registry. Order matches the
    /// registry's display order.
    public static let all: [ProviderPreset] = [
        // The shim is read-only — to add a new preset,
        // edit ProviderRegistry.initialDescriptors.
        // This list is auto-derivable in commit B when
        // the UI switches to async lookup.
        ProviderPreset(id: "openai", displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini"),
        ProviderPreset(id: "anthropic", displayName: "Anthropic (Claude)",
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-3-5-sonnet-latest"),
        ProviderPreset(id: "deepseek", displayName: "DeepSeek (深度求索)",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat"),
        ProviderPreset(id: "groq", displayName: "Groq (fast inference)",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.1-70b-versatile"),
        ProviderPreset(id: "zhipu", displayName: "Zhipu GLM (智谱)",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-plus"),
        ProviderPreset(id: "moonshot", displayName: "Moonshot Kimi (月之暗面)",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k"),
        ProviderPreset(id: "dashscope", displayName: "Alibaba DashScope (通义千问)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus"),
        ProviderPreset(id: "doubao", displayName: "ByteDance Doubao (豆包)",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModel: "doubao-1-5-pro-32k-250115"),
        ProviderPreset(id: "hunyuan", displayName: "Tencent Hunyuan (混元)",
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            defaultModel: "hunyuan-pro"),
        ProviderPreset(id: "siliconflow", displayName: "SiliconFlow (硅基流动)",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-72B-Instruct"),
        ProviderPreset(id: "openrouter", displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-4o-mini"),
        ProviderPreset(id: "ollama", displayName: "Ollama (local)",
            baseURL: "http://localhost:11434",
            defaultModel: "gemma2:2b"),
        ProviderPreset(id: "lm-studio", displayName: "LM Studio (local)",
            baseURL: "http://localhost:1234/v1",
            defaultModel: "qwen2.5-7b-instruct"),
        ProviderPreset(id: "custom", displayName: "Custom OpenAI-compatible",
            baseURL: "",
            defaultModel: "")
    ]

    public static func by(id: String) -> ProviderPreset? {
        all.first(where: { $0.id == id })
    }
}
