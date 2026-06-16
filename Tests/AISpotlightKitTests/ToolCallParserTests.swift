import XCTest
@testable import AISpotlightKit

/// Tests for the tool-call JSON parser. The parser extracts
/// `{"tool": "...", "args": {...}}` blocks from LLM replies.
/// The LLM is small (gemma2:2b at 2K context) and might not
/// produce perfectly-formatted JSON, so the parser needs
/// to be lenient.
final class ToolCallParserTests: XCTestCase {

    func testParsePlainJSON() {
        let json = #"{"tool": "search_files", "args": {"query": "polyester"}}"#
        let call = ToolCallParser.parse(json)
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.tool, "search_files")
        XCTAssertEqual(call?.args["query"] as? String, "polyester")
    }

    func testParseJSONWithSurroundingProse() {
        // The LLM sometimes wraps the JSON in prose like
        // "I'll search for that. {\"tool\": ...} Let me know."
        let json = "Let me search. {\"tool\": \"search_files\", \"args\": {\"query\": \"polyester\"}} Done."
        let call = ToolCallParser.parse(json)
        XCTAssertNotNil(call, "Should find the JSON block even with prose around it")
        XCTAssertEqual(call?.tool, "search_files")
    }

    func testParseJSONNoToolKey() {
        // Valid JSON but not a tool call (e.g. just an object
        // that happens to match).
        let json = #"{"result": "ok", "count": 5}"#
        let call = ToolCallParser.parse(json)
        XCTAssertNil(call, "Should reject JSON without a 'tool' key")
    }

    func testParseMalformedJSON() {
        let json = "{\"tool\": \"search_files\", \"args\": {"
        let call = ToolCallParser.parse(json)
        XCTAssertNil(call, "Should reject malformed JSON")
    }

    func testParseEmptyString() {
        let call = ToolCallParser.parse("")
        XCTAssertNil(call)
    }

    func testParseNonStringArgs() {
        // args must be a dict. If LLM returns args as a
        // string or array, we treat as a non-tool-call.
        let json = #"{"tool": "search_files", "args": "polyester"}"#
        let call = ToolCallParser.parse(json)
        XCTAssertNil(call)
    }

    func testParseArgsAsInt() {
        // Some LLM might send args as the value directly.
        // We reject this — args must always be a dict.
        let json = #"{"tool": "search_files", "args": 42}"#
        let call = ToolCallParser.parse(json)
        XCTAssertNil(call)
    }

    func testParseMultipleJSONBlocks() {
        // The LLM might emit two tool-call JSON blocks
        // (one for search, one for open). We take the
        // FIRST one — the loop in askWithTools will
        // re-prompt for the second one.
        let json = #"{"tool": "search_files", "args": {"query": "a"}} and then {"tool": "open_file", "args": {"path": "/a"}}"#
        let call = ToolCallParser.parse(json)
        XCTAssertEqual(call?.tool, "search_files")
    }
}
