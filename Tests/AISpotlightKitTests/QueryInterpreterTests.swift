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
        let intent = await interp.interpret("asdf qwerty")
        XCTAssertEqual(intent, .findFile(name: "report", dateFilter: nil, kind: .pdf),
                       "AI classify result should win when rules return unknown")
        let calls = await ai.callCount
        XCTAssertEqual(calls, 1, "AI must be called exactly once")
    }

    func testCacheHitsAvoidRecomputation() async {
        let ai = CountingAIProvider(canned: .openApp(name: "X"))
        let interp = QueryInterpreter(aiProvider: ai)
        _ = await interp.interpret("asdf qwerty")
        _ = await interp.interpret("asdf qwerty")
        _ = await interp.interpret("asdf qwerty")
        let calls = await ai.callCount
        XCTAssertEqual(calls, 1, "Second+ third calls must hit cache, not AI")
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
