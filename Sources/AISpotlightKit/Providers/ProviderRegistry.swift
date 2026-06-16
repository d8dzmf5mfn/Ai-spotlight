import Foundation

/// Phase 5: the source of truth for which providers
/// exist. Code-side, not config-side. To add a new
/// provider you add a `ProviderDescriptor` to
/// `ProviderRegistry.descriptors` — no UI changes,
/// no Settings changes, no caller changes.
///
/// **Why an actor**: future versions may lazy-load
/// descriptors from a remote catalog (e.g. a CDN
/// that lists all OpenAI-compatible providers with
/// their defaultBaseURL). For now we ship a static
/// list; the actor wrapper keeps that door open
/// without breaking the synchronous lookup API.
public actor ProviderRegistry {
    /// The static, code-defined list of providers we
    /// support. Order = display order in the picker.
    public static let shared = ProviderRegistry()

    private let descriptors: [ProviderDescriptor]

    public init() {
        self.descriptors = Self.initialDescriptors
    }

    /// All descriptors, sorted by display name. We sort
    /// so the picker is in a consistent order across
    /// launches and platforms (UserDefaults doesn't
    /// dictate display order).
    public func all() -> [ProviderDescriptor] {
        descriptors.sorted { $0.displayName < $1.displayName }
    }

    /// Lookup by id. Returns nil for unknown ids (which
    /// happens when the user's UserDefaults has a stale
    /// id from a previous version).
    public func descriptor(for id: String) -> ProviderDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Initial descriptors. The list is the result of
    /// the 4.6.3 self-critique: 10 providers, each
    /// described by the shape of its API rather than by
    /// a hardcoded model list. New providers go here.
    private static let initialDescriptors: [ProviderDescriptor] = [
        // OpenAI family — Bearer auth, /v1/models for discovery.
        ProviderDescriptor(
            id: "openai",
            displayName: "OpenAI",
            defaultBaseURL: "https://api.openai.com/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "deepseek",
            displayName: "DeepSeek (深度求索)",
            defaultBaseURL: "https://api.deepseek.com/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "groq",
            displayName: "Groq (fast inference)",
            defaultBaseURL: "https://api.groq.com/openai/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "zhipu",
            displayName: "Zhipu GLM (智谱)",
            defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "moonshot",
            displayName: "Moonshot Kimi (月之暗面)",
            defaultBaseURL: "https://api.moonshot.cn/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "dashscope",
            displayName: "Alibaba DashScope (通义千问)",
            defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "doubao",
            displayName: "ByteDance Doubao (豆包)",
            defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "hunyuan",
            displayName: "Tencent Hunyuan (混元)",
            defaultBaseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "siliconflow",
            displayName: "SiliconFlow (硅基流动)",
            defaultBaseURL: "https://api.siliconflow.cn/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        ProviderDescriptor(
            id: "openrouter",
            displayName: "OpenRouter",
            defaultBaseURL: "https://openrouter.ai/api/v1",
            auth: .bearer,
            // OpenRouter follows the OpenAI /v1/models
            // spec — it returns the full 1000+ model list.
            // We don't ship a hardcoded list because new
            // models appear on OpenRouter daily.
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        // Local providers — no auth, different endpoints.
        ProviderDescriptor(
            id: "ollama",
            displayName: "Ollama (local)",
            defaultBaseURL: "http://localhost:11434",
            auth: .none,
            discovery: .ollamaTags,
            health: .ollamaTags
        ),
        ProviderDescriptor(
            id: "lm-studio",
            displayName: "LM Studio (local)",
            defaultBaseURL: "http://localhost:1234/v1",
            // LM Studio accepts any string as a key by
            // default. The Bearer auth flow is still what
            // the OpenAI-compatible endpoint expects.
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        ),
        // Anthropic — DIFFERENT auth header, no /v1/models.
        // We ship a static catalog of the most popular
        // Claude models. When the user wants a model not
        // in the list, the UI has a "Type manually..."
        // fallback row in the picker.
        ProviderDescriptor(
            id: "anthropic",
            displayName: "Anthropic (Claude)",
            defaultBaseURL: "https://api.anthropic.com/v1",
            auth: .apiKeyHeader(name: "x-api-key"),
            discovery: .staticCatalog([
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest",
                "claude-opus-4-0",
                "claude-sonnet-4-0",
                "claude-haiku-4-0"
            ]),
            health: .chatCompletionPing
        ),
        // Custom — for the user with their own proxy or
        // a self-hosted OpenAI-compatible service.
        // They configure everything themselves.
        ProviderDescriptor(
            id: "custom",
            displayName: "Custom OpenAI-compatible",
            defaultBaseURL: "",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        )
    ]
}
