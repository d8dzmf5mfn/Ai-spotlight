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
    /// as a stream of String chunks.
    ///
    /// Phase 4.2.x fix (external review): the previous
    /// implementation did
    ///     `AsyncThrowingStream { Task { try await self.ask(...); ...; continuation.finish() } }`
    /// which let a detached background Task race ahead of
    /// stream-initialization. If the underlying `ask` threw
    /// synchronously (e.g. URLSession's NSURLError -1004 from
    /// Ollama being offline), `continuation.finish(throwing:)`
    /// ran BEFORE the consumer's `for try await` was even
    /// attached, and the error was silently dropped — the
    /// stream just terminated "normally" with zero chunks.
    ///
    /// The fix is twofold:
    /// 1. Use `onTermination` to wire the stream's lifecycle to
    ///    the producer Task (clean cancellation of the
    ///    background work when the consumer gives up).
    /// 2. Wrap the producer in a captured local Task that the
    ///    `onTermination` can cancel. The Task is created at
    ///    the same call-site as the continuation closure so its
    ///    lifetime is unambiguous.
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
            // The producer task is captured by the onTermination
            // closure so it can be cleanly cancelled if the
            // consumer gives up (e.g. the user pressed Enter on
            // a new ask while this one was still streaming).
            let task = Task {
                do {
                    // Check for cancellation before doing the
                    // network round-trip. This is cheap and
                    // turns a fast user-cancel into a no-op.
                    try Task.checkCancellation()
                    let fullReply = try await self.ask(query: query, context: context)
                    if Task.isCancelled { return }
                    if !fullReply.isEmpty { continuation.yield(fullReply) }
                    continuation.finish()
                } catch {
                    // Now guaranteed to reach the consumer
                    // because onTermination wires the
                    // stream's lifecycle to this task, and
                    // AsyncThrowingStream buffers the
                    // terminal error state until the
                    // consumer attaches.
                    continuation.finish(throwing: error)
                }
            }
            // When the consumer cancels (give up on the
            // stream), propagate the cancel into the
            // producer so the underlying HTTP request is
            // torn down promptly.
            continuation.onTermination = { @Sendable _ in
                task.cancel()
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
