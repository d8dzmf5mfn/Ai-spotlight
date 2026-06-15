import Foundation
import AISpotlightKit

/// Any provider that speaks the OpenAI Chat Completions API. Used for:
///   - OpenAI (https://api.openai.com/v1)
///   - Ollama (http://localhost:11434 — uses /v1/chat/completions since 0.5.0)
///   - Together, Groq, OpenRouter, LM Studio, etc. (any OpenAI-compatible API)
///
/// Configured via `AIConfig` (in SettingsStore). The endpoint URL, model
/// name, and API key all come from the user's settings; this class is
/// effectively a typed wrapper around `URLSession`.
public final class OpenAICompatibleProvider: AIProvider, @unchecked Sendable {
    public let name: String
    public let config: AIConfig
    private let session: URLSession
    /// Reused across requests — `JSONEncoder` is expensive to construct
    /// and we encode the same shape (system+user prompt) every call.
    private static let bodyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    public init(config: AIConfig, session: URLSession = .shared) {
        self.name = config.displayName
        self.config = config
        self.session = session
    }

    // MARK: - classify (Phase 1)

    public func classify(_ query: String) async throws -> Intent {
        let body = try Self.encodeClassifyBody(model: config.model, query: query)
        let content = try await sendChat(body: body, jsonMode: true)
        return try parseIntentJSON(content, fallback: .unknown(raw: query))
    }

    // MARK: - ask (Phase 4.1)

    public func ask(query: String, context: LLMContext) async throws -> String {
        // The prompt has already been enriched with context by
        // `LLMConversationService` — we just send it as the user
        // message and return the assistant's reply as-is. No
        // json_mode: we want a free-form String back, not a JSON
        // object.
        let body = try Self.encodeAskBody(model: config.model, query: query)
        return try await sendChat(body: body, jsonMode: false)
    }

    // MARK: - Wire format

    private struct Message: Codable { let role: String; let content: String }
    private struct Body: Codable {
        let model: String
        let messages: [Message]
        let response_format: [String: String]?

        enum CodingKeys: String, CodingKey {
            case model, messages
            case response_format = "response_format"
        }
    }

    /// Classify body: uses json_object response format + the
    /// JSON-output system prompt.
    private static func encodeClassifyBody(model: String, query: String) throws -> Data {
        return try bodyEncoder.encode(Body(
            model: model,
            messages: [
                Message(role: "system", content: Self.systemPrompt),
                Message(role: "user", content: query),
            ],
            response_format: ["type": "json_object"]
        ))
    }

    /// Ask body: free-form reply, no json_mode. No system prompt;
    /// `LLMConversationService` already built a context-rich user
    /// message for us.
    private static func encodeAskBody(model: String, query: String) throws -> Data {
        return try bodyEncoder.encode(Body(
            model: model,
            messages: [
                Message(role: "user", content: query),
            ],
            response_format: nil
        ))
    }

    private static let systemPrompt = """
    You are a query classifier for a macOS search app called AI Spotlight.
    Given user input, output JSON: {"kind": "findFile"|"openApp"|"unknown", "name": string|null, "dateFilter": "today"|"yesterday"|"lastWeek"|"lastMonth"|null, "fileKind": "pdf"|"image"|"document"|"code"|"archive"|"any"|null}
    Output ONLY the JSON. No prose.
    """

    // MARK: - HTTP

    /// POST the body to chat/completions and return the assistant's
    /// reply text. `jsonMode = true` is used by classify; `false` is
    /// used by ask.
    private func sendChat(body: Data, jsonMode: Bool) async throws -> String {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AIProviderError.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw AIProviderError.decodeFailure("HTTP \(http.statusCode) — \(body)")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    // MARK: - JSON contract (shared with the original OpenAIProvider)

    private struct ChatResponse: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Message: Decodable, Sendable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    private func parseIntentJSON(_ json: String, fallback: Intent) throws -> Intent {
        struct WireIntent: Decodable {
            let kind: String
            let name: String?
            let dateFilter: String?
            let fileKind: String?
        }
        guard let data = json.data(using: .utf8),
              let w = try? JSONDecoder().decode(WireIntent.self, from: data) else {
            return fallback
        }
        switch w.kind {
        case "findFile":
            return .findFile(
                name: w.name,
                dateFilter: w.dateFilter.flatMap(DateFilter.init(rawValue:)),
                kind: w.fileKind.flatMap(FileKind.init(rawValue:))
            )
        case "openApp":
            return .openApp(name: w.name ?? "")
        default:
            return fallback
        }
    }
}
