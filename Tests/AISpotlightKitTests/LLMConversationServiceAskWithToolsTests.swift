import XCTest
@testable import AISpotlightKit

/// Tests for the askWithTools loop using a fake AIProvider
/// that returns canned tool-call JSON. This is the wire-up
/// test: it proves the parser, registry, and handler chain
/// all work together end-to-end.
///
/// **No real Ollama in this test**: a real LLM is too
/// non-deterministic for a unit test. The fake returns the
/// exact JSON we want, then the loop runs the tool, feeds
/// back the result, and the fake returns a final text
/// answer. We then assert: the tool was called, the loop
/// terminated after the expected number of turns, and the
/// final answer is what we expected.
final class LLMConversationServiceAskWithToolsTests: XCTestCase {

    /// Fake AIProvider. Each call to `ask` pops the next
    /// canned reply from a queue. When the queue is empty,
    /// it just returns the last reply.
    private final class FakeProvider: AIProvider, @unchecked Sendable {
        let name = "Fake"
        var canned: [String]
        var callCount = 0
        init(canned: [String]) { self.canned = canned }
        func classify(_ query: String) async throws -> Intent {
            return .unknown(raw: query)
        }
        func ask(query: String, context: LLMContext) async throws -> String {
            callCount += 1
            if canned.isEmpty { return "" }
            let reply = canned.removeFirst()
            return reply
        }
        func askStreaming(query: String, context: LLMContext) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { _ in }
        }
    }

    func testPlainTextAnswerPassesThrough() async throws {
        let provider = FakeProvider(canned: ["I don't need any tools to answer that. The answer is 42."])
        let service = LLMConversationService(provider: provider)
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())

        let result = try await service.askWithTools(
            query: "What is the meaning of life?",
            registry: registry
        )
        XCTAssertEqual(result.finalAnswer, "I don't need any tools to answer that. The answer is 42.")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testToolCallExecutesAndFeedsBack() async throws {
        let provider = FakeProvider(canned: [
            // Turn 1: LLM emits a tool call.
            #"{"tool": "search_files", "args": {"query": "polyester", "kind": "content", "limit": 5}}"#,
            // Turn 2: LLM sees the tool result and gives the final answer.
            "I found some files for you. The first one is in your chemistry notes.",
        ])
        let service = LLMConversationService(provider: provider)
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())

        let result = try await service.askWithTools(
            query: "Find my polyester notes",
            registry: registry
        )
        XCTAssertEqual(result.toolCalls.count, 1, "Expected exactly one tool call")
        XCTAssertEqual(result.toolCalls.first?.tool, "search_files")
        XCTAssertFalse(result.toolCalls.first?.summary.isEmpty ?? true,
                      "Tool call summary should not be empty")
        XCTAssertEqual(result.finalAnswer, "I found some files for you. The first one is in your chemistry notes.")
        // Provider was called twice: turn 1 (with tool) and turn 2 (final answer).
        XCTAssertEqual(provider.callCount, 2)
    }

    func testToolErrorFeedsBackAsErrorMessage() async throws {
        let provider = FakeProvider(canned: [
            // Turn 1: LLM emits a tool call with bad args.
            #"{"tool": "search_files", "args": {}}"#,
            // Turn 2: LLM gives up after seeing the error.
            "Sorry, I can't search without knowing what to look for.",
        ])
        let service = LLMConversationService(provider: provider)
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())

        let result = try await service.askWithTools(
            query: "Find me stuff",
            registry: registry
        )
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.toolCalls.first?.summary.contains("FAILED") ?? false,
                      "Expected FAILED in summary, got: \(result.toolCalls.first?.summary ?? "")")
    }

    func testMaxToolTurnsEnforcesLimit() async throws {
        // The fake provider keeps emitting tool calls forever.
        // After maxToolTurns, the loop should give up.
        let provider = FakeProvider(canned: [
            #"{"tool": "list_apps", "args": {}}"#,
            #"{"tool": "list_apps", "args": {}}"#,
            #"{"tool": "list_apps", "args": {}}"#,
            #"{"tool": "list_apps", "args": {}}"#,  // never reached
        ])
        let service = LLMConversationService(provider: provider)
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.listApps())

        let result = try await service.askWithTools(
            query: "List apps",
            registry: registry,
            maxToolTurns: 2
        )
        XCTAssertEqual(result.toolCalls.count, 2, "Expected exactly maxToolTurns=2 tool calls")
        XCTAssertTrue(result.finalAnswer.contains("Reached tool-call limit"))
    }

    func testUnknownToolFallsBackToPlainText() async throws {
        // LLM emits a tool call for a tool that's not in the
        // registry. The parser returns it, but registry.get()
        // returns nil, so we treat the LLM reply as plain text.
        let provider = FakeProvider(canned: [
            #"{"tool": "delete_everything", "args": {}}"#,
        ])
        let service = LLMConversationService(provider: provider)
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())

        let result = try await service.askWithTools(
            query: "Be evil",
            registry: registry
        )
        XCTAssertEqual(result.toolCalls.count, 0, "Unknown tool should not be recorded as executed")
        XCTAssertTrue(result.finalAnswer.contains("delete_everything"),
                      "The LLM's original reply should be returned as the final answer")
    }
}
