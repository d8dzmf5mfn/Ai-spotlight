import Foundation

/// Phase 4.6: cloud-model presets. Each preset knows the
/// base URL and a recommended default model for a
/// specific OpenAI-compatible provider. The user can
/// still override the URL or model after picking a
/// preset — these are starting points, not locks.
///
/// **Why a list, not user-typed URLs**: the user said
/// "云端模型 (比如deepseek和minimax)" — they want
/// convenience. Typing a URL is fine for power users;
/// the rest of the world wants a dropdown. We give
/// them both: a preset picker that pre-fills the
/// fields, and the existing freeform fields stay
/// editable.
///
/// **Why include both Chinese and international
/// providers**: macOS Spotlight is global infrastructure;
/// the LLM behind AI Spotlight is a free choice. A
/// user in Beijing might prefer DeepSeek (faster
/// from China, cheaper tokens) while a user in
/// California picks OpenAI. The presets live in code,
/// not in a server call, so we can ship the full list
/// without an API round-trip.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let defaultModel: String
    public let notes: String

    public init(id: String, displayName: String, baseURL: String, defaultModel: String, notes: String = "") {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.notes = notes
    }

    /// All presets, in display order. Add new ones here.
    public static let all: [ProviderPreset] = [
        // International providers.
        ProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            notes: "Best tool-calling accuracy among cloud providers."
        ),
        ProviderPreset(
            id: "anthropic",
            displayName: "Anthropic (Claude)",
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-3-5-sonnet-latest",
            notes: "Use Anthropic's own SDK or a proxy; the public API is Anthropic-native, not OpenAI-compatible. The preset is here for users with a proxy."
        ),
        ProviderPreset(
            id: "groq",
            displayName: "Groq (fast inference)",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.1-70b-versatile",
            notes: "Very fast inference. Free tier available."
        ),
        // Chinese providers. All OpenAI-compatible.
        ProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek (深度求索)",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            notes: "Strong reasoning + tool calling. Cheap tokens, fast from China."
        ),
        ProviderPreset(
            id: "zhipu",
            displayName: "Zhipu GLM (智谱)",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-plus",
            notes: "GLM-4 series. OpenAI-compatible since 2024."
        ),
        ProviderPreset(
            id: "moonshot",
            displayName: "Moonshot Kimi (月之暗面)",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            notes: "Long-context (8k-128k). Good for chat."
        ),
        ProviderPreset(
            id: "dashscope",
            displayName: "Alibaba DashScope (通义千问)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            notes: "Qwen series via OpenAI-compatible mode. Wide model range."
        ),
        ProviderPreset(
            id: "doubao",
            displayName: "ByteDance Doubao (豆包)",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModel: "doubao-1-5-pro-32k-250115",
            notes: "ByteDance's flagship. Use the model ID they give you, not the human-readable name."
        ),
        ProviderPreset(
            id: "hunyuan",
            displayName: "Tencent Hunyuan (混元)",
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            defaultModel: "hunyuan-pro",
            notes: "Tencent's flagship. OpenAI-compatible."
        ),
        // Catch-all for users who want a different provider
        // without picking from our list. Selecting this just
        // clears the auto-filled fields so the user can type
        // their own URL and model.
        ProviderPreset(
            id: "custom",
            displayName: "Other (type URL manually)",
            baseURL: "",
            defaultModel: "",
            notes: "Select this to enter your own base URL and model name."
        )
    ]

    public static func by(id: String) -> ProviderPreset? {
        all.first(where: { $0.id == id })
    }
}
