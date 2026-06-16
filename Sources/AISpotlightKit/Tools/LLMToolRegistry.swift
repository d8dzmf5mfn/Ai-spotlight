import Foundation

/// Phase 4.3: the registry of tools the LLM can call. Each
/// tool has a unique name (matches the JSON `tool` field the
/// LLM returns) and a handler. The LLM sees a system prompt
/// listing all registered tools; its reply is parsed for a
/// `{"tool": "...", "args": {...}}` block.
///
/// **Why a registry and not a static array**: future tool
/// packs (Phase 4.3.1+) can be enabled/disabled per user
/// preference. A registry also makes it easy to inject test
/// tools in unit tests.
public actor LLMToolRegistry {
    private var tools: [String: LLMTool] = [:]

    public init() {}

    public func register(_ tool: LLMTool) {
        tools[tool.name] = tool
    }

    public func unregister(_ name: String) {
        tools.removeValue(forKey: name)
    }

    public func get(_ name: String) -> LLMTool? {
        tools[name]
    }

    public func allTools() -> [LLMTool] {
        Array(tools.values).sorted { $0.name < $1.name }
    }

    /// Build the system-prompt text that lists all registered
    /// tools for the LLM. The format is plain text because
    /// small local models (gemma2:2b at 2K context) handle
    /// text better than JSON-schema strings. Example:
    ///   "You have access to these tools:
    ///    1. search_files: Search for files whose content
    ///       matches the query. Params: query (string, required),
    ///       limit (int, optional). Returns: list of paths.
    ///    ...
    ///    To call a tool, reply with JSON:
    ///    {"tool": "tool_name", "args": {...}}"
    public func toolsForPrompt() -> String {
        let list = allTools()
        guard !list.isEmpty else { return "" }
        var out = "You have access to these tools. To use one, reply with a single JSON object of the form:\n"
        out += "{\"tool\": \"<name>\", \"args\": {<params>}}\n\n"
        for (i, tool) in list.enumerated() {
            out += "\(i + 1). \(tool.name): \(tool.description)\n"
            out += "   Parameters: \(tool.parametersDescription)\n"
        }
        out += "\nIf you don't need a tool to answer, just answer in plain text. "
        out += "If a tool result is not useful, try a different tool or answer from your own knowledge.\n"
        return out
    }
}
