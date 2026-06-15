import Foundation

/// Phase 4.1 service that turns a user's natural-language question
/// (+ optional file context) into an LLM reply.
///
/// **Design:** thin wrapper around any `AIProvider` that implements
/// `ask(query:context:)`. The provider is responsible for the wire
/// protocol (Ollama OpenAI-compatible, raw Anthropic, etc). This
/// service is responsible for:
///   1. Loading the context files (up to a per-file byte budget)
///   2. Building the prompt
///   3. Calling the provider
///   4. Returning the reply (or throwing if the provider does)
///
/// **Streaming** is intentionally not in scope for Phase 4.1.0.
/// Add it in 4.1.x by adding an `AsyncThrowingStream` variant.
public final class LLMConversationService: @unchecked Sendable {
    private let provider: AIProvider
    private let maxContextBytesPerFile: Int

    /// - Parameters:
    ///   - provider: the LLM backend (Ollama, OpenAI, Anthropic...)
    ///   - maxContextBytesPerFile: how much of each context file to
    ///     inline. 16 KB is plenty for most LLM answers and
    ///     protects us from accidentally embedding a 5 MB PDF.
    public init(provider: AIProvider,
                maxContextBytesPerFile: Int = 16 * 1024) {
        self.provider = provider
        self.maxContextBytesPerFile = maxContextBytesPerFile
    }

    /// Ask the LLM. `context` is the set of file URLs the LLM
    /// should "see" when answering. Empty context means the LLM
    /// is just answering a general question.
    public func ask(query: String, context: LLMContext = .empty) async throws -> String {
        let prompt = buildPrompt(query: query, context: context)
        return try await provider.ask(query: prompt, context: context)
    }

    /// Phase 4.1.6: streaming ask. Yields the LLM's reply as a
    /// stream of String chunks. Most providers' default impl
    /// just yields the full reply as a single chunk — the SwiftUI
    /// view can already render it that way. When a provider adds
    /// true streaming (Phase 4.1.6.1), AppState doesn't change.
    public func askStreaming(query: String, context: LLMContext = .empty) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(query: query, context: context)
        return provider.askStreaming(query: prompt, context: context)
    }

    // MARK: - Conversation history (Phase 4.1.7)

    /// One turn of the conversation. Capped to the last 6 turns
    /// (12 messages: 6 user + 6 assistant) by `buildHistoryPrompt`
    /// to keep prompts short for small-context Ollama models.
    public struct HistoryEntry: Equatable, Sendable {
        public enum Role: String, Sendable { case user, assistant }
        public let role: Role
        public let text: String
        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// Ask with conversation history. The history is inlined into
    /// the prompt as a "Previous conversation:" block. The user's
    /// new question is appended at the end. `context` files
    /// (if any) come after the history, before the question.
    public func askWithHistory(query: String,
                              history: [HistoryEntry] = [],
                              context: LLMContext = .empty) async throws -> String {
        let prompt = buildHistoryPrompt(query: query, history: history, context: context)
        return try await provider.ask(query: prompt, context: context)
    }

    /// Phase 4.2.6: streaming ask with conversation history.
    /// Most providers' default `askStreaming` impl wraps `ask`
    /// in an AsyncThrowingStream that yields the full reply as
    /// a single chunk. So we delegate to the provider's
    /// streaming API; the provider-side `ask` will get the
    /// history-enriched prompt. This is what the AppState
    /// `runLLMAsk` calls so the user sees a streaming UI
    /// (single chunk, but still the streaming pipe) and the
    /// LLM gets the prior turns.
    public func askStreamingWithHistory(query: String,
                                       history: [HistoryEntry] = [],
                                       context: LLMContext = .empty) -> AsyncThrowingStream<String, Error> {
        let prompt = buildHistoryPrompt(query: query, history: history, context: context)
        return provider.askStreaming(query: prompt, context: context)
    }

    /// Build a prompt that includes the prior conversation, the
    /// context files, and the new question. The history is
    /// capped to the most recent 6 turns so we don't exceed the
    /// context window of small models (e.g. gemma2:2b at 2K
    /// tokens).
    private func buildHistoryPrompt(query: String,
                                    history: [HistoryEntry],
                                    context: LLMContext) -> String {
        var out = ""
        if !history.isEmpty {
            out += "Previous conversation:\n"
            // Keep the most recent 6 turns. Older ones get dropped.
            let recent = history.suffix(6)
            for entry in recent {
                let role = entry.role == .user ? "User" : "Assistant"
                out += "\n\(role): \(entry.text)\n"
            }
            out += "\n"
        }
        if !context.urls.isEmpty {
            out += "Context files:\n"
            for (i, url) in context.urls.enumerated() {
                let snippet = readSnippet(url: url)
                out += "\n[File \(i + 1): \(url.path)]\n\(snippet)\n[/File \(i + 1)]\n"
            }
            out += "\n"
        }
        out += "Question: \(query)\n"
        return out
    }

    // MARK: - Prompt building

    /// Format the prompt. We don't try to be clever here — the
    /// service layer just inlines file contents and asks the
    /// question. If we need to add few-shot examples or system
    /// prompts in the future, add them as additional parameters
    /// to this function (don't change the signature).
    private func buildPrompt(query: String, context: LLMContext) -> String {
        guard !context.urls.isEmpty else { return query }

        var out = "Question: \(query)\n\nContext files:\n"
        for (i, url) in context.urls.enumerated() {
            let snippet = readSnippet(url: url)
            out += "\n[File \(i + 1): \(url.path)]\n\(snippet)\n[/File \(i + 1)]\n"
        }
        out += "\nAnswer the question using the context above when relevant. "
        out += "If the context doesn't contain the answer, say so.\n"
        return out
    }

    /// Read up to `maxContextBytesPerFile` from a file. Returns a
    /// marker if the file can't be read.
    private func readSnippet(url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return "(could not read \(url.path))"
        }
        let budget = min(data.count, maxContextBytesPerFile)
        let slice = data.prefix(budget)
        if let s = String(data: slice, encoding: .utf8) {
            if data.count > budget {
                return s + "\n…(truncated, \(data.count - budget) more bytes)"
            }
            return s
        }
        return "(file is not UTF-8 text; \(data.count) bytes)"
    }
}
