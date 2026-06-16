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

    // MARK: - Tool calling (Phase 4.3.1)

    /// Ask the LLM with tool access. The loop is:
    ///   1. Inject the tool list into the system prompt.
    ///   2. Call the LLM.
    ///   3. If the LLM reply contains a tool call JSON block,
    ///      execute the tool and feed the result back to the
    ///      LLM as a "User" turn. Repeat up to `maxToolTurns`.
    ///   4. If the LLM replies with plain text (no tool call),
    ///      return that as the final answer.
    ///
    /// **Why 3 turns max**: a small local model (gemma2:2b at
    /// 2K context) gets confused after 2-3 tool-use rounds. We
    /// cap at 3 to keep the prompt short and the user from
    /// waiting too long.
    public func askWithTools(query: String,
                              history: [HistoryEntry] = [],
                              context: LLMContext = .empty,
                              registry: LLMToolRegistry,
                              maxToolTurns: Int = 2,
                              onToolStart: (@Sendable (String) async -> Void)? = nil) async throws -> AskWithToolsResult {
        var turns = history
        turns.append(HistoryEntry(role: .user, text: query))
        var toolCalls: [ExecutedToolCall] = []
        let userQuestion = query
        for _ in 0..<maxToolTurns {
            // Phase 4.3.4: split tool schema into a real
            // system role (per OpenAI function-calling
            // guidance) and keep history + question in the
            // user role. The provider detects the
            // "<<TOOL_SYSTEM>>" prefix and routes the
            // before-newline content as a system message.
            let systemBlock = await buildToolSystemBlock(registry: registry, context: context)
            let userBlock = buildUserBlock(turns: turns)
            let prompt = "<<TOOL_SYSTEM>>\n" + systemBlock + "\n<<END_SYSTEM>>\n\n" + userBlock
            let reply = try await provider.ask(query: prompt, context: context)
            turns.append(HistoryEntry(role: .assistant, text: reply))
            // Look for a tool call.
            guard let call = ToolCallParser.parse(reply),
                  let tool = await registry.get(call.tool) else {
                // Plain text answer. Done.
                return AskWithToolsResult(
                    finalAnswer: reply,
                    toolCalls: toolCalls,
                    originalQuestion: userQuestion
                )
            }
            // Phase 4.4: notify caller about to start a tool.
            // The AppState uses this to show "🔧 using
            // search_files..." progress while the tool runs.
            if let cb = onToolStart {
                await cb(call.tool)
            }
            // Execute the tool.
            do {
                let result = try await tool.handler(call.args)
                let recorded = ExecutedToolCall(
                    tool: call.tool,
                    args: call.args,
                    summary: result.summary
                )
                toolCalls.append(recorded)
                // Feed the result back as a User turn so the
                // LLM can incorporate it. We include both the
                // summary (one line, easy to scan) and the JSON
                // payload (structured, parseable).
                let payload = encodeResultAsJSON(result.payload)
                let feedback = "Tool [\(call.tool)] returned: \(result.summary)\nResult: \(payload)"
                turns.append(HistoryEntry(role: .user, text: feedback))
            } catch {
                // Tool threw. Tell the LLM so it can try a
                // different argument or give up.
                let errMsg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                let feedback = "Tool [\(call.tool)] failed: \(errMsg)"
                turns.append(HistoryEntry(role: .user, text: feedback))
                toolCalls.append(ExecutedToolCall(
                    tool: call.tool,
                    args: call.args,
                    summary: "FAILED: \(errMsg)"
                ))
            }
        }
        // Hit maxToolTurns without a final text answer.
        // Return the last assistant turn as the answer and
        // mark it as truncated.
        let last = turns.last(where: { $0.role == .assistant })?.text ?? ""
        return AskWithToolsResult(
            finalAnswer: last + "\n\n[Reached tool-call limit]",
            toolCalls: toolCalls,
            originalQuestion: userQuestion
        )
    }

    /// Build a prompt that includes the prior conversation, the
    /// context files, the new question, AND the tool schema.
    /// The tool schema is rendered as plain text because small
    /// local models handle text better than JSON Schema strings.
    /// Phase 4.3.4: build the system-role content for the
    /// tool-aware ask. The provider splits this from the
    /// user-role content via the "<<TOOL_SYSTEM>>" marker.
    ///
    /// We follow OpenAI's function-calling guidance: the
    /// system role is where tool definitions and behavioral
    /// rules belong. Small local models (gemma2:2b, qwen2.5:3b)
    /// are much more likely to call tools when the schema
    /// lives in the system role, with a few-shot example,
    /// and with an explicit "ALWAYS reply with JSON" rule.
    private func buildToolSystemBlock(registry: LLMToolRegistry,
                                       context: LLMContext) async -> String {
        let toolsPrompt = await registry.toolsForPrompt()
        var out = "You are AI Spotlight, a local macOS search and assistant tool.\n"
        out += "You can call tools to find files, open apps, and answer questions grounded in the user's real data.\n"
        if !toolsPrompt.isEmpty {
            out += "\n" + toolsPrompt + "\n"
        }
        out += """
        \nDecision rules — follow these IN ORDER:

        1. Read the user's question. Classify it:
           - GREETING or small talk ("hi", "hello", "thanks",
             "how are you", "ok") → reply in PLAIN TEXT, do
             not call any tool. Be brief and friendly.
           - GENERAL KNOWLEDGE question ("what is polyester",
             "explain chemistry", "tell me about X") →
             reply in PLAIN TEXT using your own knowledge.
             Do not call any tool.
           - FILE / DATA question ("find my X", "search for
             X in my files", "open the Y file", "what's in
             my Z folder") → use a tool. Reply with JSON.

        2. When a tool is needed, reply with EXACTLY one
           JSON object: {"tool": "<name>", "args": {<params>}}
           - Do NOT add any explanation or prose before or
             after the JSON.
           - Do NOT ask the user a clarifying question
             first — just call the tool with the most
             obvious parameters.

        3. STOP AFTER 1 TOOL CALL:
           - After you receive a tool result, FORM A FINAL
             ANSWER in plain text and STOP.
           - Do NOT call another tool unless the user
             explicitly asked for more.
           - Calling tools in a loop is a bug. Avoid it.

        Examples:

        User: hi
        Assistant: Hello! How can I help you find something today?

        User: what is polyester
        Assistant: Polyester is a category of polymers that
        contain the ester functional group in their main
        chain. It is commonly used in clothing and packaging.

        User: find my chemistry notes about polyester
        Assistant: {"tool": "search_files", "args": {"query": "polyester", "kind": "content"}}
        """
        // Phase 4.3.4: if context files were provided, list
        // their paths in the system block too so the LLM
        // knows the files exist. We DON'T inline contents
        // here — that's done in the user block.
        if !context.urls.isEmpty {
            let names = context.urls.map { $0.lastPathComponent }.joined(separator: ", ")
            out += "\nFiles the user has selected: \(names)"
        }
        return out
    }

    /// Build the user-role content: history + context file
    /// snippets + the latest question.
    private func buildUserBlock(turns: [HistoryEntry]) -> String {
        let history = Array(turns.dropLast())
        var out = ""
        if !history.isEmpty {
            out += "Previous conversation:\n"
            for entry in history.suffix(6) {
                let role = entry.role == .user ? "User" : "Assistant"
                out += "\n\(role): \(entry.text)\n"
            }
            out += "\n"
        }
        // The most recent turn carries the latest user
        // question, but we already kept the prior 6 turns
        // above. Pull just the question here.
        if let lastUser = turns.last(where: { $0.role == .user })?.text {
            out += "Question: \(lastUser)\n"
        }
        return out
    }

    /// Encode an LLMToolValue payload as a JSON string for
    /// the LLM's next prompt. We use the `description` field
    /// of the enum's cases (since LLMToolValue has a custom
    /// encode) but it's simpler to round-trip via JSONEncoder.
    private func encodeResultAsJSON(_ payload: [String: LLMToolValue]) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let s = String(data: data, encoding: .utf8) else {
            return "{...}"
        }
        return s
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

    // MARK: - Tool calling result types

    /// The result of an `askWithTools` call. Includes the
    /// final answer (plain text from the LLM) AND the list
    /// of tool calls the LLM made along the way. The
    /// AppState can display this in the UI as a transcript.
    public struct AskWithToolsResult: Sendable {
        public let finalAnswer: String
        public let toolCalls: [ExecutedToolCall]
        public let originalQuestion: String

        public init(finalAnswer: String,
                    toolCalls: [ExecutedToolCall],
                    originalQuestion: String) {
            self.finalAnswer = finalAnswer
            self.toolCalls = toolCalls
            self.originalQuestion = originalQuestion
        }
    }

    /// One tool call the LLM made during the ask. The
    /// AppState shows these in the UI as "Used search_files:
    /// Found 5 files matching 'polyester'" so the user knows
    /// what the AI did.
    public struct ExecutedToolCall: Sendable {
        public let tool: String
        public let args: [String: Any]
        public let summary: String

        public init(tool: String, args: [String: Any], summary: String) {
            self.tool = tool
            self.args = args
            self.summary = summary
        }
    }
