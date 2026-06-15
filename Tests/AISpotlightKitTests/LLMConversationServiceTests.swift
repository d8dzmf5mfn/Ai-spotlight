import XCTest
@testable import AISpotlightKit

/// Tests for the LLM-backed conversation service. Phase 4.1
/// MVP: synchronous ask (no streaming yet), uses the
/// `OpenAICompatibleProvider` to talk to a local Ollama
/// instance (or any OpenAI-compatible endpoint).
///
/// The unit tests use a mock provider (a `FakeAIProvider`) so
/// they don't need a real Ollama running. The test that
/// talks to a real Ollama lives in App-target integration
/// testing (Phase 4.1.5).
final class LLMConversationServiceTests: XCTestCase {

    // MARK: - Fake provider (mock for unit tests)

    /// A mock that returns the canned reply for the canned
    /// prompt. Stand-in for `OpenAICompatibleProvider` so the
    /// tests don't need a real LLM running.
    final class FakeAIProvider: AIProvider, @unchecked Sendable {
        let name: String
        let replyToAsk: String
        let capturedPrompts: NSMutableArray

        init(name: String = "Fake", replyToAsk: String = "fake reply") {
            self.name = name
            self.replyToAsk = replyToAsk
            self.capturedPrompts = NSMutableArray()
        }

        // classify() isn't exercised by these tests but the
        // protocol still requires it. We provide a no-op.
        func classify(_ query: String) async throws -> Intent {
            return .unknown(raw: query)
        }

        func ask(query: String, context: LLMContext) async throws -> String {
            capturedPrompts.add(query)
            return replyToAsk
        }
    }

    // MARK: - Basic ask

    func testAskReturnsReply() async throws {
        let fake = FakeAIProvider(replyToAsk: "polyester is a polymer")
        let service = LLMConversationService(provider: fake)
        let reply = try await service.ask(query: "what is polyester?")
        XCTAssertEqual(reply, "polyester is a polymer")
    }

    func testAskForwardsQueryToProvider() async throws {
        let fake = FakeAIProvider()
        let service = LLMConversationService(provider: fake)
        _ = try? await service.ask(query: "explain photosynthesis")
        XCTAssertEqual(fake.capturedPrompts.count, 1)
        XCTAssertEqual(fake.capturedPrompts[0] as? String, "explain photosynthesis")
    }

    // MARK: - Context

    func testAskWithContextForwardsContext() async throws {
        let fake = FakeAIProvider(replyToAsk: "ok")
        let service = LLMConversationService(provider: fake)

        // Build a temporary file with known content
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-\(UUID().uuidString).md")
        try "polyester chemistry notes".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let context = LLMContext(urls: [tmp])
        _ = try? await service.ask(query: "what's in this file?", context: context)

        // The prompt that reached the provider should mention the
        // file's content. We can't assert the exact prompt (the
        // service is free to format it any way), but the captured
        // query must NOT just be the user's question.
        let prompt = fake.capturedPrompts[0] as? String ?? ""
        XCTAssertNotEqual(prompt, "what's in this file?",
            "Service must enrich the prompt with context, not forward it raw.")
    }

    func testAskWithEmptyContextWorksLikeAsk() async throws {
        let fake = FakeAIProvider(replyToAsk: "42")
        let service = LLMConversationService(provider: fake)
        let reply = try await service.ask(query: "the answer?", context: LLMContext.empty)
        XCTAssertEqual(reply, "42")
    }

    // MARK: - Error handling

    func testAskPropagatesError() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let fake = BoomProvider()
        let service = LLMConversationService(provider: fake)
        do {
            _ = try await service.ask(query: "q")
            XCTFail("Expected error to propagate")
        } catch {
            // OK
        }
    }

    // MARK: - Conversation history (Phase 4.1.7)

    func testAskWithHistoryIncludesHistoryInPrompt() async throws {
        let fake = FakeAIProvider(replyToAsk: "ok")
        let service = LLMConversationService(provider: fake)

        let history: [LLMConversationService.HistoryEntry] = [
            .init(role: .user, text: "What is polyester?"),
            .init(role: .assistant, text: "Polyester is a polymer."),
        ]
        _ = try? await service.askWithHistory(query: "And what about nylon?",
                                             history: history)
        let prompt = fake.capturedPrompts[0] as? String ?? ""
        XCTAssertTrue(prompt.contains("What is polyester?"),
                      "Prompt should include prior user turn. Got: \(prompt)")
        XCTAssertTrue(prompt.contains("Polyester is a polymer."),
                      "Prompt should include prior assistant turn. Got: \(prompt)")
        XCTAssertTrue(prompt.contains("And what about nylon?"),
                      "Prompt should include the new question. Got: \(prompt)")
    }

    func testAskWithEmptyHistoryBehavesLikeAsk() async throws {
        let fake = FakeAIProvider(replyToAsk: "hi")
        let service = LLMConversationService(provider: fake)
        let reply = try await service.askWithHistory(query: "hello?")
        XCTAssertEqual(reply, "hi")
    }

    // MARK: - Streaming (Phase 4.1.6)

    func testAskStreamingYieldsReply() async throws {
        let fake = FakeAIProvider(replyToAsk: "streamed reply")
        let service = LLMConversationService(provider: fake)
        let stream = service.askStreaming(query: "hello")
        var collected = ""
        for try await chunk in stream {
            collected += chunk
        }
        XCTAssertEqual(collected, "streamed reply")
    }

    func testAskStreamingPropagatesError() async {
        let fake = BoomProvider()
        let service = LLMConversationService(provider: fake)
        let stream = service.askStreaming(query: "hello")
        do {
            for try await _ in stream { XCTFail("Expected no chunks") }
            XCTFail("Expected error to propagate")
        } catch {
            // OK
        }
    }

    /// Test-only provider that throws on every call.
    final class BoomProvider: AIProvider, @unchecked Sendable {
        let name = "Boom"
        func classify(_ query: String) async throws -> Intent {
            return .unknown(raw: query)
        }
        func ask(query: String, context: LLMContext) async throws -> String {
            throw Boom()
        }
    }
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }
}
