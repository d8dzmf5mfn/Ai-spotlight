import Foundation

/// Phase 4.3: a tool the LLM can call to retrieve or manipulate
/// local state. This is the "function calling" surface — the LLM
/// sees a JSON schema for the tool, decides to call it, and we
/// parse the LLM's reply for a tool-use JSON block.
///
/// **Why we don't use MCP/JSON-RPC/LangChain here**: those
/// frameworks solve the cross-process / cross-language tool
/// broker problem. AI Spotlight is a single-process macOS app
/// with a known set of local tools. We don't need the protocol.
/// We inline the tool schema in the system prompt and parse
/// the LLM reply directly. This is 200 lines of Swift vs.
/// pulling in 10MB of framework dependencies.
///
/// **Security model**: every tool has a `requiresConsent` flag.
/// The AppState's tool-call loop checks this flag and presents
/// a confirm dialog before executing. Destructive tools (open,
/// delete) require consent; pure-read tools (search, list)
/// don't. The user can disable consent per-tool in Settings.
public struct LLMTool: Sendable {
    /// Machine name (used in the JSON the LLM returns, e.g.
    /// `{"tool": "search_files", ...}`). Lowercase_snake_case.
    public let name: String

    /// Human-readable description the LLM sees in its system
    /// prompt. Should be 1-2 sentences explaining when to use
    /// the tool. Example: "Search for files whose CONTENT
    /// matches the query. Returns up to N file paths."
    public let description: String

    /// JSON-schema-like description of the parameters. We don't
    /// use full JSON Schema because the LLM is small (gemma2:2b
    /// at 2K context). A plain text description is enough:
    ///   - `query` (string, required): the search terms
    ///   - `limit` (integer, optional): max results, default 5
    public let parametersDescription: String

    /// True if the user should confirm before the tool runs.
    /// Read-only tools (search, list) set this to false.
    /// Side-effect tools (open, delete) set this to true.
    public let requiresConsent: Bool

    /// The actual implementation. Receives the JSON args from
    /// the LLM (already validated as a [String: Any] dict) and
    /// returns a JSON-encodable result. Errors throw — the
    /// outer loop catches and feeds the error message back to
    /// the LLM for retry.
    public let handler: @Sendable ([String: Any]) async throws -> LLMToolResult

    public init(
        name: String,
        description: String,
        parametersDescription: String,
        requiresConsent: Bool,
        handler: @escaping @Sendable ([String: Any]) async throws -> LLMToolResult
    ) {
        self.name = name
        self.description = description
        self.parametersDescription = parametersDescription
        self.requiresConsent = requiresConsent
        self.handler = handler
    }
}

/// The result of running a tool. Always JSON-encodable so we
/// can stuff it into the LLM's next prompt as "Tool result: ...".
/// The `LLMToolResult.payload` is the JSON-friendly form; the
/// `summary` is a one-line human-readable version for the UI
/// log.
public struct LLMToolResult: Sendable, Codable {
    public let summary: String
    /// The structured payload. Should be Codable so the LLM
    /// can parse it from the next prompt. Examples:
    /// - `["paths": ["/a/b/c.md", "/a/b/d.pdf"]]`
    /// - `["ok": true]`
    public let payload: [String: LLMToolValue]

    public init(summary: String, payload: [String: LLMToolValue]) {
        self.summary = summary
        self.payload = payload
    }
}

/// A Codable value type for the payload. We don't use `Any`
/// because that breaks Codable conformance. Instead we wrap
/// everything in this enum that can be string, int, double,
/// bool, array, or nested dict.
public enum LLMToolValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LLMToolValue])
    case dict([String: LLMToolValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([LLMToolValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: LLMToolValue].self) { self = .dict(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "LLMToolValue: unrecognized JSON"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .dict(let v): try c.encode(v)
        }
    }
}
