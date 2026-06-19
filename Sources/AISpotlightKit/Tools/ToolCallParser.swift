import Foundation

/// Phase 4.3: extracts a tool-call JSON block from an LLM
/// reply. Small local models (gemma2:2b at 2K context) might
/// not produce perfectly-formatted JSON — they often wrap
/// the JSON in prose ("I'll search for that. {...} Let me
/// know.") or emit multiple blocks. The parser is intentionally
/// lenient: it scans for the first `{...}` block that has a
/// "tool" string key and an "args" dict.
///
/// **Why not a generic JSON parser**: Foundation's
/// `JSONSerialization` and `Codable` work, but they don't
/// help us find a JSON block embedded in prose. We use
/// `JSONSerialization` on the substring that looks like JSON,
/// so we can pass in `"I'll search. {\"tool\": ...}"` and get
/// out the parsed tool call.
public enum ToolCallParser {

    /// A parsed tool call from the LLM.
    public struct ToolCall: @unchecked Sendable {
        public let tool: String
        public let args: [String: Any]
    }

    /// Parse the LLM's reply. Returns nil if the reply
    /// doesn't contain a recognizable tool call.
    public static func parse(_ llmReply: String) -> ToolCall? {
        // Strip leading/trailing whitespace.
        let trimmed = llmReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Fast path: the entire reply IS a JSON object.
        if let call = parseSingle(trimmed) {
            return call
        }

        // Slow path: scan for a JSON object embedded in prose.
        // The LLM might emit "{ ... {nested} ... }" where the
        // first '}' we find is the inner one's. We count
        // braces: every '{' increments depth, every '}'
        // decrements, and we close when depth returns to 0.
        // That gives us the matching close brace for each
        // open brace, regardless of how deeply nested the
        // object is.
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            // Find the next '{' from index i onward.
            guard let openIdx = chars[i...].firstIndex(of: "{") else { return nil }
            // Walk forward from openIdx, tracking brace depth.
            var depth = 0
            var endIdx = openIdx
            var inString = false
            var escapeNext = false
            for j in openIdx..<chars.count {
                let c = chars[j]
                if escapeNext {
                    escapeNext = false
                    continue
                }
                if c == "\\" {
                    escapeNext = true
                    continue
                }
                if c == "\"" {
                    inString.toggle()
                    continue
                }
                if inString { continue }
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIdx = j
                        break
                    }
                }
            }
            // If we never closed the brace, no valid JSON in
            // this string. Bail.
            if depth != 0 { return nil }
            // Try to parse the substring from openIdx to endIdx.
            let candidate = String(chars[openIdx...endIdx])
            if let call = parseSingle(candidate) {
                return call
            }
            // Not a tool call. Try the next '{' after endIdx.
            i = endIdx + 1
        }
        return nil
    }

    /// Try to parse a single JSON substring as a tool call.
    /// Returns nil if the substring isn't a JSON object with
    /// a "tool" key and an "args" dict.
    private static func parseSingle(_ json: String) -> ToolCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Must have a "tool" key (string) and an "args" key (dict).
        guard let tool = obj["tool"] as? String, !tool.isEmpty,
              let args = obj["args"] as? [String: Any] else {
            return nil
        }
        return ToolCall(tool: tool, args: args)
    }
}
