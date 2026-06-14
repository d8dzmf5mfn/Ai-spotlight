import Foundation

public actor OpenAIProvider: AIProvider {
    public nonisolated let name = "OpenAI"
    private let keychain: KeychainStoring
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(keychain: KeychainStoring, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    public func classify(_ query: String) async throws -> Intent {
        guard let key = try keychain.get("openai_api_key") else { throw AIProviderError.missingAPIKey }
        let body = makeRequestBody(query: query)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIProviderError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.badResponse(http.statusCode) }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        return try parseIntentJSON(content, fallback: .unknown(raw: query))
    }
}

// MARK: - Request/response (Task 9 will move prompt + parsing here, currently inline)
private struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct ChatRequest: Codable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let response_format: [String: String]
}

private struct ChatResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

private let systemPrompt = """
You are a query classifier for a macOS search app.
Given user input, output JSON: {"kind": "findFile"|"openApp"|"unknown", "name": string|null, "dateFilter": "today"|"yesterday"|"lastWeek"|"lastMonth"|null, "fileKind": "pdf"|"image"|"document"|"code"|"archive"|"any"|null}
Output ONLY the JSON. No prose.
"""

private extension OpenAIProvider {
    func makeRequestBody(query: String) -> ChatRequest {
        ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: query),
            ],
            response_format: ["type": "json_object"]
        )
    }

    func parseIntentJSON(_ json: String, fallback: Intent) throws -> Intent {
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
