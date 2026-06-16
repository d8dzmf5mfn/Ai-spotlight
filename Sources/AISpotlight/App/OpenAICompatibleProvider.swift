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

    // MARK: - ask (Phase 4.1) — non-streaming

    /// Phase 4.3.4: LLMConversationService prefixes tool-aware
    /// prompts with `<<TOOL_SYSTEM>>` and embeds the system
    /// content after that marker. We split on the marker, send
    /// the prefix as a system message and the rest as the user
    /// message. This honors OpenAI's function-calling guidance
    /// that tool schemas go in the system role.
    static let toolSystemMarker = "<<TOOL_SYSTEM>>"

    private static func splitToolSystem(_ query: String) -> (system: String, user: String)? {
        guard query.hasPrefix(toolSystemMarker) else { return nil }
        // After the marker, find the next newline (end of system block).
        let after = query.dropFirst(toolSystemMarker.count)
        guard let nl = after.firstIndex(of: "\n") else { return nil }
        let sys = String(after[..<nl])
        // The user content starts after the newline + any leading
        // newline we want to skip.
        let userStart = after.index(after: nl)
        let user = String(after[userStart...])
        return (sys, user)
    }

    public func ask(query: String, context: LLMContext) async throws -> String {
        // The prompt has already been enriched with context by
        // `LLMConversationService` — we just send it as the user
        // message and return the assistant's reply as-is. No
        // json_mode: we want a free-form String back, not a JSON
        // object. Phase 4.3.4: if the query is tool-aware, split
        // the system portion into a real system role.
        let (userContent, system) = Self.splitToolSystem(query)
            .map { ($0.user, $0.system) }
            ?? (query, nil)
        let body = try Self.encodeAskBody(
            model: config.model,
            query: userContent,
            stream: false,
            systemPrompt: system
        )
        Log.write("[OpenAICompatibleProvider.ask] POSTing to \(config.baseURL) model=\(config.model) queryLen=\(query.count)")
        do {
            let reply = try await sendChat(body: body, jsonMode: false)
            Log.write("[OpenAICompatibleProvider.ask] reply received, length=\(reply.count)")
            return reply
        } catch {
            Log.write("[OpenAICompatibleProvider.ask] ERROR: \(error)")
            throw error
        }
    }

    // MARK: - askStreaming (Phase 4.2.x, external review)

    /// Real SSE streaming. The previous default impl in
    /// `AIProvider.swift` wrapped the non-streaming `ask` call in
    /// a detached `Task` inside the `AsyncThrowingStream` init
    /// closure. When the underlying `ask` threw synchronously
    /// (URLSession's NSURLError -1004 for Ollama being offline
    /// fires in milliseconds), `continuation.finish(throwing:)`
    /// ran BEFORE the consumer's `for try await` was even
    /// attached, and the error was silently dropped — the
    /// stream just terminated "normally" with zero chunks.
    ///
    /// The fix: drop the wrapper, talk to `URLSession.bytes(for:)`
    /// directly. `URLSession.bytes` is itself an `AsyncBytes`
    /// that throws errors on the consumer's iteration context
    /// (not on a detached task), so the catch block in
    /// `AppState` is guaranteed to fire when Ollama is offline.
    /// This is the industry-standard pattern for SSE
    /// consumption on macOS 14+ / iOS 17+.
    public func askStreaming(query: String, context: LLMContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Build the streaming request. We use `stream: true`
            // in the body so the server (Ollama, OpenAI,
            // Together, etc.) emits SSE-format chunks. Phase
            // 4.3.4: split any tool-system prefix into a
            // proper system role.
            let (userContent2, system2) = Self.splitToolSystem(query)
                .map { ($0.user, $0.system) }
                ?? (query, nil)
            let body: Data
            do {
                body = try Self.encodeAskBody(
                    model: config.model,
                    query: userContent2,
                    stream: true,
                    systemPrompt: system2
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let url = config.baseURL.appendingPathComponent("chat/completions")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = config.apiKey, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = body

            Log.write("[OpenAICompatibleProvider.askStreaming] POSTing to \(url) stream=true model=\(config.model) queryLen=\(query.count)")
            // The producer task captures the network
            // request. The consumer (AppState's for try await
            // loop) attaches to the continuation concurrently
            // with this task spawning — but the difference is
            // that errors here propagate through `for try await
            // line in bytes.lines`, which is the consumer's
            // iteration context. No detached continuation
            // races.
            let producerTask = Task {
                do {
                    // URLSession.bytes throws when the
                    // connection fails. The error happens on
                    // the consumer's await of the first byte,
                    // not on a detached task — so the
                    // catch block in AppState WILL see it.
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.badResponse(-1)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw AIProviderError.decodeFailure("HTTP \(http.statusCode)")
                    }

                    // Parse SSE line-by-line. The OpenAI /
                    // Ollama streaming format is:
                    //   data: {"choices": [{"delta": {"content": "..."}}]}
                    //   data: {"choices": [{"delta": {}, "finish_reason": "stop"}]}
                    //   data: [DONE]
                    // Each line is a separate CRLF-terminated
                    // event. `bytes.lines` splits on \n, \r\n,
                    // or \r and strips the terminator.
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let chunk = Self.parseSSELine(line) else { continue }
                        if chunk.isEmpty { continue }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    // Critical: this error now reaches the
                    // AppState catch block, which sets
                    // `llmError` and clears `isLLMBusy`.
                    // The user sees the error in the panel
                    // immediately, instead of a frozen
                    // "Thinking…" state.
                    Log.write("[OpenAICompatibleProvider.askStreaming] ERROR: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            // Consumer cancel → propagate to producer
            // (URLSession.bytes will be torn down).
            continuation.onTermination = { @Sendable _ in
                producerTask.cancel()
            }
        }
    }

    /// Parse a single SSE line. Returns the content delta or
    /// nil for non-data lines / keep-alives / the [DONE]
    /// sentinel / empty payloads.
    ///
    /// **Phase 4.2.5 fix (external review):** Ollama 0.5+ uses
    /// a different streaming shape than OpenAI. OpenAI:
    ///   `data: {"choices": [{"delta": {"content": "..."}}]}`
    /// Ollama:
    ///   `data: {"response": "...", "done": false}`
    /// We now support BOTH so the same code path works
    /// against both endpoints.
    private static func parseSSELine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return nil }
        let json = String(trimmed.dropFirst("data: ".count))
        if json == "[DONE]" { return "" }  // terminator; no content
        guard let data = json.data(using: .utf8) else { return nil }

        // Single struct that supports BOTH OpenAI's
        // choices[0].delta.content AND Ollama's response.
        // Both fields are optional, so a JSON object with
        // either one is fine.
        struct WireChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                }
                let delta: Delta?
            }
            let choices: [Choice]?
            // Ollama streaming shape: {"response": "...",
            // "done": false, "model": "gemma4:12b", ...}
            let response: String?
            let done: Bool?
        }
        guard let wire = try? JSONDecoder().decode(WireChunk.self, from: data) else {
            return nil
        }
        // Prefer OpenAI shape, fall back to Ollama shape.
        if let content = wire.choices?.first?.delta?.content, !content.isEmpty {
            return content
        }
        if let response = wire.response, !response.isEmpty {
            return response
        }
        return nil
    }

    // MARK: - Wire format

    private struct Message: Codable { let role: String; let content: String }
    private struct Body: Codable {
        let model: String
        let messages: [Message]
        let response_format: [String: String]?
        /// `stream: true` switches the server into SSE mode.
        /// `false` (or absent) returns the full reply in one
        /// JSON object (used by classify and ask).
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, messages
            case response_format = "response_format"
            case stream
        }
    }

    /// Classify body: uses json_object response format + the
    /// JSON-output system prompt. Non-streaming.
    private static func encodeClassifyBody(model: String, query: String) throws -> Data {
        return try bodyEncoder.encode(Body(
            model: model,
            messages: [
                Message(role: "system", content: Self.systemPrompt),
                Message(role: "user", content: query),
            ],
            response_format: ["type": "json_object"],
            stream: false
        ))
    }

    /// Ask body: free-form reply, no json_mode. `stream` is
    /// set by the caller (ask uses false, askStreaming uses
    /// true).
    /// Phase 4.3.4: support an optional system prompt. When
    /// non-nil, the system message is sent FIRST (so the
    /// LLM sees it before any user message), per OpenAI's
    /// function-calling guidance. When nil, the body
    /// contains a single user message (legacy behavior).
    private static func encodeAskBody(model: String,
                                       query: String,
                                       stream: Bool,
                                       systemPrompt: String? = nil) throws -> Data {
        var messages: [Message] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append(Message(role: "system", content: sys))
        }
        messages.append(Message(role: "user", content: query))
        return try bodyEncoder.encode(Body(
            model: model,
            messages: messages,
            response_format: nil,
            stream: stream
        ))
    }

    private static let systemPrompt = """
    You are a query classifier for a macOS search app called AI Spotlight.
    Given user input, output JSON: {"kind": "findFile"|"openApp"|"unknown", "name": string|null, "dateFilter": "today"|"yesterday"|"lastWeek"|"lastMonth"|null, "fileKind": "pdf"|"image"|"document"|"code"|"archive"|"any"|null}
    Output ONLY the JSON. No prose.
    """

    // MARK: - HTTP (non-streaming path)

    /// POST the body to chat/completions and return the assistant's
    /// reply text. `jsonMode = true` is used by classify; `false` is
    /// used by ask. (askStreaming uses `URLSession.bytes` directly
    /// and bypasses this helper.)
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
