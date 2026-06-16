import XCTest
@testable import AISpotlightKit

/// Test double: counts classify() calls and returns a canned Intent.
actor CountingAIProvider: AIProvider {
    nonisolated let name = "CountingAI"
    private(set) var callCount = 0
    let canned: Intent

    init(canned: Intent) { self.canned = canned }

    func classify(_ query: String) async throws -> Intent {
        callCount += 1
        return canned
    }
}

final class QueryInterpreterTests: XCTestCase {
    func testRulePathDoesNotCallAI() async {
        let ai = CountingAIProvider(canned: .openApp(name: "should-not-be-used"))
        let interp = QueryInterpreter(aiProvider: ai)
        // "find yesterday PDF" — rule parser handles this
        let intent = await interp.interpret("find yesterday PDF")
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: .yesterday, kind: .pdf))
        let calls = await ai.callCount
        XCTAssertEqual(calls, 0, "AI must not be called when rules succeed")
    }

    func testAIFallbackWhenRulesReturnUnknown() async {
        let ai = CountingAIProvider(canned: .findFile(name: "report", dateFilter: nil, kind: .pdf))
        let interp = QueryInterpreter(aiProvider: ai)
        // "asdf qwerty" — gibberish, no verb/kind/date, rules return unknown
        // Phase 4.2.5: the LLMIntentRouter is disabled by default
        // (every keystroke was firing a separate LLM call). The
        // rule parser now returns .ask for unknown queries, and
        // the LLM is invoked later via the askWithTools path, not
        // here in interpret(). This test now asserts that the
        // rule path returns .ask (not a parsed intent) and the
        // AI is not called during interpret() at all.
        let intent = await interp.interpret("asdf qwerty")
        XCTAssertEqual(intent, .ask(query: "asdf qwerty", contextURLs: []),
                       "Unknown queries fall through to .ask for the LLM askWithTools path")
        let calls = await ai.callCount
        XCTAssertEqual(calls, 0, "AI router is disabled; interpretation never calls AI")
    }

    func testCacheHitsAvoidRecomputation() async {
        let ai = CountingAIProvider(canned: .openApp(name: "X"))
        let interp = QueryInterpreter(aiProvider: ai)
        // With the AI router disabled, the rule parser returns
        // .ask deterministically for gibberish. Calling interpret
        // 3 times should produce identical results and never
        // call the AI provider. (The "cache" property of the
        // old LLMIntentRouter is no longer relevant — the new
        // design moves the LLM call out of interpret() and
        // into a separate askWithTools path.)
        let intent1 = await interp.interpret("asdf qwerty")
        let intent2 = await interp.interpret("asdf qwerty")
        let intent3 = await interp.interpret("asdf qwerty")
        XCTAssertEqual(intent1, intent2)
        XCTAssertEqual(intent2, intent3)
        XCTAssertEqual(intent1, .ask(query: "asdf qwerty", contextURLs: []))
        let calls = await ai.callCount
        XCTAssertEqual(calls, 0, "AI is not called during interpret() — moved to askWithTools")
    }

    func testNilAIFallsBackToRules() async {
        let interp = QueryInterpreter(aiProvider: nil)
        // Rule path: "find yesterday PDF" → findFile intent
        let intent = await interp.interpret("find yesterday PDF")
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: .yesterday, kind: .pdf))
    }

    func testEmptyInputReturnsUnknownEmpty() async {
        let interp = QueryInterpreter(aiProvider: nil)
        let intent = await interp.interpret("   ")
        XCTAssertEqual(intent, .unknown(raw: ""))
    }
}
