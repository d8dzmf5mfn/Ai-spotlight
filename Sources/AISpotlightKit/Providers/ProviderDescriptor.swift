import Foundation

/// Phase 5: Provider descriptor — the SHAPE of how to talk
/// to a provider, NOT a specific model or endpoint instance.
///
/// **Why this exists (4.6.3 self-critique)**: the old
/// `ProviderPreset` struct conflated four independent
/// concerns: which provider (URL template), how to
/// authenticate, how to discover models, how to check
/// health. Different providers differ on all four axes:
///
/// | Provider   | Auth              | Discovery        | Health check    |
/// |------------|-------------------|------------------|-----------------|
/// | OpenAI     | Bearer            | GET /v1/models   | GET /v1/models   |
/// | Anthropic  | x-api-key header  | (no /v1/models)  | POST messages   |
/// | Ollama     | none              | GET /api/tags    | GET /api/tags    |
/// | OpenRouter | Bearer            | GET /v1/models   | GET /v1/models   |
///
/// Hard-coding these per-provider is exactly what the
/// user pushed back on. This struct lets us treat each
/// axis independently — `AuthStyle` is its own enum,
/// `DiscoveryStrategy` is its own enum, etc.
///
/// **Two design rules**:
/// 1. `defaultBaseURL` is a *suggestion* — users can
///    override it (proxies, self-hosted). All the
///    other fields are not user-editable. If you need
///    to change how a provider authenticates, you add
///    a new enum case, not a flag.
/// 2. `staticCatalog` is a fallback for providers that
///    don't expose a list endpoint. We use it for
///    Anthropic, which doesn't have /v1/models. The
///    list should be the *5-10 most popular models*
///    at the time the descriptor ships, not a
///    full catalog (which would go stale).
public struct ProviderDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let defaultBaseURL: String
    public let auth: AuthStyle
    public let discovery: DiscoveryStrategy
    public let health: HealthCheckStrategy
    /// Whether `discovery` is a real HTTP call. Some
    /// providers (Anthropic native) have no /v1/models
    /// equivalent, so the UI shows the static catalog
    /// instead of trying to refresh.
    public var supportsModelsList: Bool {
        if case .openAIListModels = discovery { return true }
        if case .ollamaTags = discovery { return true }
        return false
    }

    public init(
        id: String,
        displayName: String,
        defaultBaseURL: String,
        auth: AuthStyle,
        discovery: DiscoveryStrategy,
        health: HealthCheckStrategy
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.auth = auth
        self.discovery = discovery
        self.health = health
    }
}

/// How to authenticate. The Discovery and Health
/// strategies look at this when building requests.
public enum AuthStyle: Equatable, Sendable {
    /// Standard OpenAI-style: `Authorization: Bearer <key>`.
    case bearer
    /// Anthropic-style: a custom header with the key as value.
    /// The name is usually `x-api-key` but providers may differ.
    case apiKeyHeader(name: String)
    /// No auth needed (local Ollama, LM Studio with auth disabled).
    case none

    /// Build the HTTP header dictionary for this auth style.
    /// `apiKey` is ignored for `.none`.
    public func headers(apiKey: String) -> [String: String] {
        switch self {
        case .bearer:
            return ["Authorization": "Bearer \(apiKey)"]
        case .apiKeyHeader(let name):
            return [name: apiKey]
        case .none:
            return [:]
        }
    }
}

/// How to fetch the list of available models. The
/// `staticCatalog` variant is for providers (Anthropic)
/// that don't expose a list endpoint.
public enum DiscoveryStrategy: Equatable, Sendable {
    /// GET {baseURL}/v1/models (or {baseURL}/models depending
    /// on the provider). Returns OpenAI-style JSON
    /// `{"data": [{"id": "..."}, ...]}`.
    case openAIListModels
    /// GET {baseURL}/api/tags. Returns Ollama-style JSON
    /// `{"models": [{"name": "..."}, ...]}`.
    case ollamaTags
    /// Hardcoded list of model IDs. Used for providers that
    /// don't expose a list endpoint (Anthropic).
    case staticCatalog([String])
    /// No discovery. The user types the model name manually.
    case none
}

/// How to verify the service is alive. Step 1 of the
/// 4-step connection diagnostic.
public enum HealthCheckStrategy: Equatable, Sendable {
    /// GET {baseURL}/v1/models. 200 = healthy. Used for
    /// OpenAI-compatible providers.
    case openAIListModels
    /// GET {baseURL}/api/tags. 200 = healthy. Used for Ollama.
    case ollamaTags
    /// POST a minimal /chat/completions with max_tokens=1.
    /// Used when the discovery endpoint doesn't exist
    /// (Anthropic). Expensive — use only as last resort.
    case chatCompletionPing
}
