import Foundation

/// A bundle of URLs the LLM should consider when answering.
/// The service reads each URL's contents (truncated to a budget)
/// and prepends them to the prompt as context.
///
/// Empty URLs means "no context" — the service should send
/// the user's query unchanged.
public struct LLMContext: Equatable, Sendable {
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }

    public static let empty = LLMContext(urls: [])

    /// Build a context from URLs, ignoring any that don't exist
    /// or that we can't read.
    public static func from(urls: [URL]) async -> LLMContext {
        var ok: [URL] = []
        for url in urls {
            if FileManager.default.fileExists(atPath: url.path),
               (try? Data(contentsOf: url, options: [.mappedIfSafe])) != nil {
                ok.append(url)
            }
        }
        return LLMContext(urls: ok)
    }
}

public protocol AIProvider: Sendable {
    var name: String { get }
    /// Phase 1: classify a user query into an Intent. Fast path
    /// (no LLM call) for providers that can; slow path (LLM call)
    /// for ones that can't.
    func classify(_ query: String) async throws -> Intent
    /// Phase 4.1: ask the LLM a question, optionally grounded in
    /// `context`. Returns the LLM's reply as a plain String.
    /// Default implementation throws "not supported" so existing
    /// providers don't need to implement this until they're
    /// updated.
    func ask(query: String, context: LLMContext) async throws -> String
    /// Phase 4.1.6: streaming variant. Returns the LLM's reply
    /// as a stream of String chunks (one per `delta.content` from
    /// the SSE response). Most providers can implement this
    /// cheaply by returning `AsyncThrowingStream { continuation in
    /// let reply = try await ask(...); continuation.yield(reply); continuation.finish() }`
    /// until true streaming is implemented. Default impl does
    /// exactly that — so adding `askStreaming` is a 1-line change
    /// in AppState, not a refactor.
    func askStreaming(query: String, context: LLMContext) -> AsyncThrowingStream<String, Error>
}

public extension AIProvider {
    /// Default implementation: providers that don't yet support
    /// real LLM conversation throw here. LLMConversationService
    /// checks via the protocol conformance at runtime.
    func ask(query: String, context: LLMContext) async throws -> String {
        throw AIProviderError.notSupportedYet(self.name)
    }

    /// Default streaming impl: collect the full reply and yield
    /// it as a single chunk. Override only when the underlying
    /// provider can do true delta-by-delta streaming.
    func askStreaming(query: String, context: LLMContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let reply = try await self.ask(query: query, context: context)
                    if !reply.isEmpty { continuation.yield(reply) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public enum AIProviderError: Error, LocalizedError {
    case missingAPIKey
    case badResponse(Int)
    case decodeFailure(String)
    case notSupportedYet(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing API key in Keychain"
        case .badResponse(let code): return "HTTP \(code)"
        case .decodeFailure(let body): return "Could not decode response: \(body.prefix(200))"
        case .notSupportedYet(let name): return "\(name) provider does not yet support LLM conversation"
        }
    }
}
