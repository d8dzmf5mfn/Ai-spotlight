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
