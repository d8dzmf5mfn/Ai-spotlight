import Foundation

/// Phase 5-B: fetches the list of available models for a
/// provider and caches the result for a TTL.
///
/// **Why an actor**: cache writes happen from the UI
/// when the user clicks "Refresh models" or on first
/// Picker show. Cache reads happen on every chat
/// completion to know which models are valid. We
/// want both to be safe under concurrent UI use
/// (e.g. user clicks Refresh twice quickly, and
/// the chat pipeline reads at the same time).
///
/// **Why a TTL cache**: most providers expose a list
/// endpoint but the lists change slowly. Re-fetching
/// on every chat completion would waste API quota.
/// We cache for 24h by default — long enough that
/// the user rarely re-fetches, short enough that a
/// new model release shows up within a day of use.
///
/// **Why not UserDefaults for the cache**: a UserDefaults
/// key per provider would let us preload the cache
/// on next launch, but the user can also clear the
/// cache from Settings ("Refresh models" button).
/// For now the cache is in-memory; we revisit
/// persistence in Phase 5-D if the user complains
/// about the picker re-fetching on every cold start.
public actor ModelDiscoveryService {
    /// Default cache TTL. OpenRouter adds new models
    /// multiple times per day; the other providers
    /// rarely change. 24h is the right default for
    /// both cases.
    public static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// 5-second timeout for discovery calls. The user
    /// expects the picker to appear within a second or
    /// two. If a provider is down, we don't want the UI
    /// to hang.
    public static let requestTimeout: TimeInterval = 5

    private struct CacheEntry {
        let models: [String]
        let fetchedAt: Date
        let source: Source

        enum Source: String {
            /// Fetched from the provider's HTTP list endpoint.
            case live
            /// Loaded from the descriptor's staticCatalog.
            case staticCatalog
            /// User typed the model name manually.
            case manual
        }

        var isStale: Bool {
            Date().timeIntervalSince(fetchedAt) > ModelDiscoveryService.defaultTTL
        }
    }

    /// Cache key is the provider id (e.g. "openai",
    /// "deepseek", "ollama"). The baseURL and apiKey
    /// are passed per-call because the user may
    /// override the descriptor's defaults.
    private var cache: [String: CacheEntry] = [:]

    /// For tests: allow injecting a custom URLSession
    /// and a custom clock. Production uses
    /// `URLSession.shared` and `Date()`.
    private let session: URLSession
    private let clock: () -> Date

    public init(session: URLSession = .shared, clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.clock = clock
    }

    /// Discover models for a provider. The cache
    /// takes precedence; if it's stale, we re-fetch
    /// and update the cache.
    ///
    /// `apiKey` is required for any provider that has
    /// an auth style (bearer / apiKeyHeader). For
    /// `.none` auth (local Ollama / LM Studio) it
    /// is ignored.
    public func models(
        for descriptor: ProviderDescriptor,
        baseURL: String,
        apiKey: String
    ) async throws -> [String] {
        if let entry = cache[descriptor.id], !entry.isStale {
            return entry.models
        }
        let models = try await fetch(
            descriptor: descriptor,
            baseURL: baseURL,
            apiKey: apiKey
        )
        cache[descriptor.id] = CacheEntry(
            models: models,
            fetchedAt: clock(),
            source: .live
        )
        return models
    }

    /// Force a refresh of the cache, even if it's
    /// fresh. Used by the "Refresh models" button in
    /// Settings.
    public func refresh(
        descriptor: ProviderDescriptor,
        baseURL: String,
        apiKey: String
    ) async throws -> [String] {
        let models = try await fetch(
            descriptor: descriptor,
            baseURL: baseURL,
            apiKey: apiKey
        )
        cache[descriptor.id] = CacheEntry(
            models: models,
            fetchedAt: clock(),
            source: .live
        )
        return models
    }

    /// Return the cached models WITHOUT making a network
    /// call. The UI uses this to populate the Picker
    /// immediately on first show, then refresh in the
    /// background. If no cache entry exists, returns
    /// `descriptor.discovery`'s staticCatalog (if any)
    /// as a fallback.
    public func cachedModels(for descriptor: ProviderDescriptor) -> [String] {
        if let entry = cache[descriptor.id] {
            return entry.models
        }
        if case .staticCatalog(let list) = descriptor.discovery {
            return list
        }
        return []
    }

    /// Clear the cache. Used by Settings → "Clear cache"
    /// (future) or when the user switches providers.
    public func clear() {
        cache.removeAll()
    }

    /// Clear the cache for a specific provider.
    public func clearCache(for providerId: String) {
        cache.removeValue(forKey: providerId)
    }

    // MARK: - Strategy-specific fetchers

    /// Dispatch on the descriptor's discovery strategy.
    /// The strategies are described in ProviderDescriptor.
    private func fetch(
        descriptor: ProviderDescriptor,
        baseURL: String,
        apiKey: String
    ) async throws -> [String] {
        switch descriptor.discovery {
        case .openAIListModels:
            return try await fetchOpenAIListModels(
                baseURL: baseURL,
                auth: descriptor.auth,
                apiKey: apiKey
            )
        case .ollamaTags:
            return try await fetchOllamaTags(baseURL: baseURL)
        case .staticCatalog(let list):
            return list
        case .none:
            return []
        }
    }

    /// OpenAI-style: GET {baseURL}/models, returns
    /// `{"data": [{"id": "..."}, ...]}`. Used by OpenAI,
    /// DeepSeek, Groq, OpenRouter, Moonshot, DashScope,
    /// Doubao, Hunyuan, SiliconFlow, Zhipu, and Custom.
    private func fetchOpenAIListModels(
        baseURL: String,
        auth: AuthStyle,
        apiKey: String
    ) async throws -> [String] {
        guard let url = URL(string: baseURL) else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        // The standard OpenAI path is /v1/models, but the
        // baseURL we receive from the user is already
        // ".../v1" (the chat URL). So we append "models"
        // to whatever the user gave us. If the user gave
        // us a URL without the trailing /v1, we still
        // append "models" — most providers accept both.
        let modelsURL = url.appendingPathComponent("models")
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = ModelDiscoveryService.requestTimeout
        for (k, v) in auth.headers(apiKey: apiKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ModelDiscoveryError.notHTTPResponse
            }
            if http.statusCode == 401 {
                throw ModelDiscoveryError.unauthorized
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ModelDiscoveryError.httpError(http.statusCode, body.prefix(200).description)
            }
            // Parse {"data": [{"id": "..."}, ...]}
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                throw ModelDiscoveryError.unexpectedFormat
            }
            return dataArr.compactMap { $0["id"] as? String }
        } catch let e as URLError {
            throw ModelDiscoveryError.networkError(e.localizedDescription)
        } catch let de as ModelDiscoveryError {
            throw de
        } catch {
            throw ModelDiscoveryError.unknown(error.localizedDescription)
        }
    }

    /// Ollama-style: GET {baseURL}/api/tags, returns
    /// `{"models": [{"name": "..."}, ...]}`. The Ollama
    /// baseURL is "http://localhost:11434" (no /v1
    /// suffix); we append /api/tags directly.
    private func fetchOllamaTags(baseURL: String) async throws -> [String] {
        guard let url = URL(string: baseURL) else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        let tagsURL = url.appendingPathComponent("api/tags")
        var req = URLRequest(url: tagsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = ModelDiscoveryService.requestTimeout
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ModelDiscoveryError.notHTTPResponse
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ModelDiscoveryError.httpError(http.statusCode, body.prefix(200).description)
            }
            // Parse {"models": [{"name": "..."}, ...]}
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelsArr = json["models"] as? [[String: Any]] else {
                throw ModelDiscoveryError.unexpectedFormat
            }
            return modelsArr.compactMap { $0["name"] as? String }
        } catch let e as URLError {
            throw ModelDiscoveryError.networkError(e.localizedDescription)
        } catch let de as ModelDiscoveryError {
            throw de
        } catch {
            throw ModelDiscoveryError.unknown(error.localizedDescription)
        }
    }
}

/// Errors that ModelDiscoveryService can throw. These
/// are mapped to user-facing messages in the UI; we keep
/// the enum small so the UI doesn't have to handle 50
/// cases.
public enum ModelDiscoveryError: Error, LocalizedError {
    case invalidURL(String)
    case notHTTPResponse
    case unauthorized                              // HTTP 401
    case httpError(Int, String)
    case unexpectedFormat                          // JSON didn't match what we expected
    case networkError(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .notHTTPResponse: return "Not an HTTP response"
        case .unauthorized: return "API key is wrong or missing (HTTP 401)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .unexpectedFormat: return "Response format didn't match what we expected"
        case .networkError(let s): return "Network error: \(s)"
        case .unknown(let s): return "Error: \(s)"
        }
    }
}
