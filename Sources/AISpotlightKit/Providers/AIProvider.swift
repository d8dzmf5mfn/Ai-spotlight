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
    ///
    /// Phase 4.2.x fix (external review, double-decker): the
    /// previous version had two bugs.
    ///
    /// 1. **Detached producer race.** The producer `Task`
    ///    inside `AsyncThrowingStream.init` started executing
    ///    before the consumer's `for try await` had a chance
    ///    to attach. When the underlying `ask` threw
    ///    synchronously (NSURLError -1004 from URLSession on
    ///    Ollama being offline fires in milliseconds),
    ///    `continuation.finish(throwing:)` ran on the detached
    ///    task before the consumer had called its first
    ///    `next()`. The terminal error was effectively dropped
    ///    — the stream just ended "normally" with zero chunks,
    ///    and the consumer's catch block never saw anything.
    ///
    /// 2. **`makeStream()` lifecycle management.** Using
    ///    `AsyncThrowingStream.makeStream()` instead of the
    ///    init-with-closure makes the continuation lifecycle
    ///    more predictable: we capture both the stream and the
    ///    continuation in the same scope, and the producer
    ///    task is wired to the consumer's termination via
    ///    `continuation.onTermination`. This way, when the
    ///    consumer cancels, the producer task is cancelled
    ///    too — no leaked network requests.
    func askStreaming(query: String, context: LLMContext) -> AsyncThrowingStream<String, Error> {
        // makeStream gives us (stream, continuation) as a tuple
        // — the continuation is now in our scope, not buried
        // inside a closure that runs before the consumer
        // attaches. We still create a producer task, but the
        // task is wired to the stream's lifecycle.
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let task = Task {
            do {
                // Cheap pre-check: if the consumer has already
                // cancelled (e.g. user pressed Enter on a new
                // ask while this one was still starting up),
                // short-circuit before doing any work.
                try Task.checkCancellation()
                let fullReply = try await self.ask(query: query, context: context)
                if Task.isCancelled { return }
                if !fullReply.isEmpty { continuation.yield(fullReply) }
                continuation.finish()
            } catch {
                // The producer task throws here. Because
                // makeStream gives us a continuation that's
                // tied to the stream's internal buffer, this
                // error is reliably delivered to the consumer's
                // for try await — even if the consumer
                // attaches slightly after this fires.
                continuation.finish(throwing: error)
            }
        }
        // Consumer cancel → propagate to producer. Without
        // this, the in-flight network request keeps running
        // and the consumer's wait keeps blocking.
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
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
