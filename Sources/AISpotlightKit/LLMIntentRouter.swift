import Foundation

/// LLM-backed intent router. Classifies a raw user query into
/// one of a few intents plus structured parameters, by asking a
/// small LLM to return a JSON object. This is the same approach
/// Apple Siri / Microsoft Copilot / Notion AI use, vs our
/// rule-based `QueryParser` (which has been patched 5+ times
/// to handle edge cases like "shower" containing "show").
///
/// **Why an LLM and not more rules?**
/// - Rule parsers have to enumerate every Chinese AND English
///   verb pattern, every file type synonym, every date
///   expression. Each new feature is a new patch.
/// - A small local model (Ollama gemma2:2b) handles the
///   classification in 1-2 seconds with ~200 tokens of context.
///   That's acceptable for a search-bar debounce.
/// - We can tune the system prompt to make the LLM
///   output stable JSON. Failures fall back to the rule parser.
///
/// **Failure modes (designed for, not bugs):**
/// - LLM not running: `route()` throws; caller falls back to
///   `QueryParser` immediately.
/// - LLM returns malformed JSON: `route()` returns
///   `RoutedIntent(kind: .unknown, confidence: 0)` so the
///   caller can fall back to `QueryParser` instead of doing
///   the wrong thing.
/// - LLM returns an unknown intent kind: same as malformed
///   JSON — `RoutedIntent(kind: .unknown)`.
public final class LLMIntentRouter: @unchecked Sendable {
    private let provider: AIProvider

    /// Threshold below which the router returns `.ambiguous` so
    /// the UI can ask the user to clarify ("are you looking for
    /// a file, or asking a question?"). 0.6 matches what Apple
    /// Siri uses for low-confidence disambiguation in practice.
    public let ambiguityThreshold: Double

    public init(provider: AIProvider, ambiguityThreshold: Double = 0.6) {
        self.provider = provider
        self.ambiguityThreshold = ambiguityThreshold
    }

    /// Route a raw user query. Throws if the LLM call fails
    /// (caller can fall back to `QueryParser`). Returns a
    /// `RoutedIntent` with `kind: .unknown` if the LLM's reply
    /// is unparseable — that way the failure is recoverable.
    public func route(query: String) async throws -> RoutedIntent {
        let prompt = Self.routingPrompt(userQuery: query)
        let raw = try await provider.ask(query: prompt, context: .empty)
        let parsed = Self.parseReply(raw, userQuery: query)
        // Three cases:
        // 1. .unknown (parse failure) — return as-is so the
        //    caller can fall back to QueryParser.
        // 2. .ambiguous (low confidence) — return as-is so the
        //    UI can ask the user to clarify.
        // 3. normal — return as-is.
        return RoutedIntent(
            kind: parsed.kind,
            confidence: parsed.confidence,
            keywords: parsed.keywords,
            fileTypes: parsed.fileTypes,
            dateRange: parsed.dateRange,
            appName: parsed.appName,
            rawQuery: query
        )
    }

    // MARK: - Prompt

    /// The system-style prompt we send to the LLM. Stable,
    /// short, with explicit JSON output requirements. We
    /// deliberately do NOT include a long preamble — small
    /// models (gemma2:2b, 2K context) get confused by verbose
    /// instructions and may produce partial JSON.
    private static func routingPrompt(userQuery: String) -> String {
        """
        You are a query router for a macOS search app called AI Spotlight. Classify the user's query and return ONLY a JSON object. No prose, no markdown, no explanation.

        Choose ONE intent kind from:
        - "search": user is looking for a file, document, note, or project on their Mac
        - "ask": user is asking a general-knowledge question for the LLM to answer
        - "openApp": user wants to open or launch a specific macOS app

        JSON shape:
        {"kind":"search|ask|openApp","confidence":0.0-1.0,"keywords":["..."],"fileTypes":["md","pdf","swift","code","image","document","text","any"],"dateRange":"today|yesterday|lastWeek|lastMonth|null","appName":"..."}

        Examples:
        Q: "find my polyester notes"
        A: {"kind":"search","confidence":0.96,"keywords":["polyester"],"fileTypes":["md","text"],"dateRange":null,"appName":null}

        Q: "what is polyester?"
        A: {"kind":"ask","confidence":0.97,"keywords":[],"fileTypes":[],"dateRange":null,"appName":null}

        Q: "Safari"
        A: {"kind":"openApp","confidence":0.99,"keywords":[],"fileTypes":[],"dateRange":null,"appName":"Safari"}

        Q: "open the PDF I downloaded yesterday"
        A: {"kind":"search","confidence":0.94,"keywords":[],"fileTypes":["pdf"],"dateRange":"yesterday","appName":null}

        Q: "tell me about polyester"
        A: {"kind":"ask","confidence":0.92,"keywords":[],"fileTypes":[],"dateRange":null,"appName":null}

        Q: \(userQuery)
        A:
        """
    }

    // MARK: - Reply parsing

    /// Decoded representation of the LLM's JSON reply. Also
    /// tracks `rawQuery` so the caller can fall back.
    private struct ParsedReply {
        var kind: RoutedIntent.Kind
        var confidence: Double
        var keywords: [String]
        var fileTypes: [String]
        var dateRange: String?
        var appName: String?
    }

    /// Parse the LLM's raw string reply. If anything goes wrong
    /// (JSON parse, missing field, unknown kind), return
    /// `.unknown` with confidence 0. We never throw here — the
    /// caller should always be able to fall back to
    /// `QueryParser`.
    private static func parseReply(_ raw: String, userQuery: String) -> ParsedReply {
        // Strip markdown fences if the model added them
        // (some small models wrap JSON in ```json ... ```).
        let trimmed = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first {...} block. The LLM sometimes adds a
        // trailing newline + something. We grab the first valid
        // JSON object.
        guard let data = extractJSONObject(trimmed)?.data(using: .utf8) else {
            return unknownReply()
        }

        struct Wire: Decodable {
            let kind: String?
            let confidence: Double?
            let keywords: [String]?
            let fileTypes: [String]?
            let dateRange: String?
            let appName: String?
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return unknownReply()
        }

        let kind: RoutedIntent.Kind
        switch wire.kind {
        case "search": kind = .search
        case "ask":    kind = .ask
        case "openApp": kind = .openApp
        default:       kind = .unknown
        }
        let confidence = wire.confidence ?? 0.0
        return ParsedReply(
            kind: kind,
            confidence: confidence,
            keywords: wire.keywords ?? [],
            fileTypes: wire.fileTypes ?? [],
            dateRange: wire.dateRange,
            appName: wire.appName
        )
    }

    private static func unknownReply() -> ParsedReply {
        ParsedReply(kind: .unknown, confidence: 0, keywords: [], fileTypes: [], dateRange: nil, appName: nil)
    }

    /// Extract the first {...} block from a string. Returns nil
    /// if no balanced braces are found.
    private static func extractJSONObject(_ s: String) -> String? {
        guard let openIdx = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        for i in s.indices[s.index(after: openIdx)... ] {
            let c = s[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                if depth == 0 {
                    return String(s[openIdx...i])
                }
                depth -= 1
            }
        }
        // Unbalanced — return the open brace to end. Decoder
        // will fail, caller falls back to .unknown.
        return String(s[openIdx...])
    }
}

/// The routed intent returned by `LLMIntentRouter.route(...)`.
public struct RoutedIntent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The user wants to find a file/document on disk.
        case search
        /// The user wants a free-form LLM answer.
        case ask
        /// The user wants to launch an app.
        case openApp
        /// The LLM's confidence is below the ambiguity threshold
        /// — the UI should ask the user to clarify.
        case ambiguous
        /// The LLM's reply was unparseable; the caller should
        /// fall back to the rule parser.
        case unknown
    }

    public let kind: Kind
    /// 0.0–1.0. Below the router's `ambiguityThreshold`, the
    /// kind flips to `.ambiguous`.
    public let confidence: Double
    /// Search keywords extracted by the LLM.
    public let keywords: [String]
    /// Search file types extracted by the LLM (e.g. "pdf", "md").
    public let fileTypes: [String]
    /// Date range filter extracted by the LLM.
    public let dateRange: String?
    /// App name when `kind == .openApp`.
    public let appName: String?
    /// Original user query, for fallback / logging.
    public let rawQuery: String

    public init(kind: Kind, confidence: Double, keywords: [String],
                fileTypes: [String], dateRange: String?, appName: String?,
                rawQuery: String) {
        self.kind = kind
        self.confidence = confidence
        self.keywords = keywords
        self.fileTypes = fileTypes
        self.dateRange = dateRange
        self.appName = appName
        self.rawQuery = rawQuery
    }
}
