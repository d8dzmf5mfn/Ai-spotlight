import XCTest
@testable import AISpotlightKit

/// Tests for the LLM-backed intent router. The router asks a
/// small LLM to classify the user's raw query into one of a
/// few intents (search, ask, openApp) plus structured
/// parameters. This is the same approach Apple Siri / Microsoft
/// Copilot / Notion AI use, vs our rule-based QueryParser
/// which has been patched 5+ times to handle edge cases like
/// "shower" containing "show" or multi-token app names.
///
/// The unit tests use a mock provider (FakeRouterProvider) so
/// they don't need a real LLM running. End-to-end tests live in
/// the .app target.
final class LLMIntentRouterTests: XCTestCase {

    // MARK: - Mock provider

    /// Mock that returns the canned JSON reply for the canned
    /// prompt. Stand-in for `OpenAICompatibleProvider` so the
    /// tests don't need a real LLM running.
    final class FakeRouterProvider: AIProvider, @unchecked Sendable {
        let name: String = "Fake"
        let replyJSON: String
        let capturedPrompts: NSMutableArray

        init(replyJSON: String) {
            self.replyJSON = replyJSON
            self.capturedPrompts = NSMutableArray()
        }

        func classify(_ query: String) async throws -> Intent {
            return .unknown(raw: query)
        }
        func ask(query: String, context: LLMContext) async throws -> String {
            capturedPrompts.add(query)
            return replyJSON
        }
    }

    // MARK: - search intent

    func testRoutesSearchIntent() async throws {
        let json = """
        {"kind": "search", "confidence": 0.95, "keywords": ["polyester"], "fileTypes": ["md", "pdf"], "dateRange": null}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "find my polyester notes")
        XCTAssertEqual(routed.kind, .search)
        XCTAssertEqual(routed.confidence, 0.95, accuracy: 0.01)
        XCTAssertEqual(routed.keywords, ["polyester"])
        XCTAssertEqual(routed.fileTypes, ["md", "pdf"])
        XCTAssertNil(routed.dateRange)
    }

    func testRoutesSearchIntentWithDateRange() async throws {
        let json = """
        {"kind": "search", "confidence": 0.92, "keywords": ["report"], "fileTypes": ["pdf"], "dateRange": "lastWeek"}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "find report.pdf from last week")
        XCTAssertEqual(routed.dateRange, "lastWeek")
    }

    // MARK: - ask intent

    func testRoutesAskIntent() async throws {
        let json = """
        {"kind": "ask", "confidence": 0.97, "keywords": [], "fileTypes": [], "dateRange": null}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "what is polyester?")
        XCTAssertEqual(routed.kind, .ask)
        XCTAssertEqual(routed.keywords, [])
    }

    // MARK: - openApp intent

    func testRoutesOpenAppIntent() async throws {
        let json = """
        {"kind": "openApp", "confidence": 0.99, "keywords": ["Safari"], "fileTypes": [], "dateRange": null, "appName": "Safari"}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "Safari")
        XCTAssertEqual(routed.kind, .openApp)
        XCTAssertEqual(routed.appName, "Safari")
    }

    // MARK: - ambiguous

    func testRoutesAmbiguousWhenConfidenceLow() async throws {
        // Confidence 0.5 should be reported in the RoutedIntent's
        // confidence field; the caller decides whether to
        // present a disambiguation UI based on that.
        let json = """
        {"kind": "ask", "confidence": 0.5, "keywords": ["polyester"], "fileTypes": ["md"], "dateRange": null}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "polyester")
        // The router reports the raw confidence; it's up to
        // the caller to convert low-confidence to .ambiguous
        // (because the caller has UX context — sometimes you
        // want to ask, sometimes you want to just try).
        XCTAssertEqual(routed.kind, .ask)
        XCTAssertEqual(routed.confidence, 0.5, accuracy: 0.01)
    }

    func testAmbiguityThresholdHelper() async throws {
        // The caller-side convenience: a query with low
        // confidence should be treated as ambiguous by the
        // caller. We document the contract here.
        let json = """
        {"kind": "ask", "confidence": 0.5, "keywords": ["polyester"], "fileTypes": ["md"], "dateRange": null}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "polyester")
        let isAmbiguous = routed.confidence < router.ambiguityThreshold
        XCTAssertTrue(isAmbiguous,
                      "Caller can use ambiguityThreshold to flip low-confidence to .ambiguous")
    }

    // MARK: - JSON parse failure → fallback

    func testFallsBackOnMalformedJSON() async throws {
        // If the LLM returns garbage, we should NOT throw. We
        // return .unknown (kind=unknown) with confidence 0 so
        // the caller can fall back to the rule parser.
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: "not json"))
        let routed = try await router.route(query: "test")
        XCTAssertEqual(routed.kind, .unknown)
        XCTAssertEqual(routed.confidence, 0.0, accuracy: 0.01)
    }

    func testFallsBackOnUnknownKind() async throws {
        // If the LLM returns a kind we don't recognize, treat as
        // unknown so the rule parser can take over.
        let json = """
        {"kind": "play_music", "confidence": 0.9}
        """
        let router = LLMIntentRouter(provider: FakeRouterProvider(replyJSON: json))
        let routed = try await router.route(query: "test")
        XCTAssertEqual(routed.kind, .unknown)
    }

    // MARK: - prompt format

    func testPromptMentionsIntentKinds() async throws {
        // Sanity: the prompt we send to the LLM should list the
        // intent kinds so the model knows what to choose from.
        let fake = FakeRouterProvider(replyJSON: #"{"kind":"ask","confidence":0.9,"keywords":[],"fileTypes":[],"dateRange":null}"#)
        let router = LLMIntentRouter(provider: fake)
        _ = try? await router.route(query: "hello")
        let prompt = fake.capturedPrompts[0] as? String ?? ""
        XCTAssertTrue(prompt.contains("search"), "Prompt should list 'search' intent")
        XCTAssertTrue(prompt.contains("ask"), "Prompt should list 'ask' intent")
        XCTAssertTrue(prompt.contains("openApp"), "Prompt should list 'openApp' intent")
    }

    func testPromptIncludesUserQuery() async throws {
        let fake = FakeRouterProvider(replyJSON: #"{"kind":"ask","confidence":0.9,"keywords":[],"fileTypes":[],"dateRange":null}"#)
        let router = LLMIntentRouter(provider: fake)
        _ = try? await router.route(query: "the meaning of life")
        let prompt = fake.capturedPrompts[0] as? String ?? ""
        XCTAssertTrue(prompt.contains("the meaning of life"),
                      "Prompt should include the user's query. Got: \(prompt)")
    }
}
