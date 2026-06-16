import XCTest
@testable import AISpotlightKit

/// Tests for Phase 5-C: ConnectionDiagnosticService.
/// Uses the same URLProtocol stub as ModelDiscoveryServiceTests
/// to inject canned responses for each step.
final class ConnectionDiagnosticServiceTests: XCTestCase {

    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let handler = StubURLProtocol.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        // Note: ConnectionDiagnosticService uses URLSession.shared
        // directly, so this stub injection doesn't apply to it.
        // We use a counter-based handler that knows which URL was
        // requested and returns a different response per call.
        // For tests, the easiest is to have a single handler
        // that returns different data based on the URL path.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    private func openAIDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: "openai", displayName: "OpenAI",
            defaultBaseURL: "https://api.openai.com/v1",
            auth: .bearer,
            discovery: .openAIListModels,
            health: .openAIListModels
        )
    }

    private func ollamaDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: "ollama", displayName: "Ollama",
            defaultBaseURL: "http://localhost:11434",
            auth: .none,
            discovery: .ollamaTags,
            health: .ollamaTags
        )
    }

    func testAllStepsPass() async {
        // All 4 steps return success.
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("/models") && req.httpMethod == "GET" {
                let body = #"{"data":[{"id":"deepseek-chat"}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, body)
            } else if path.contains("/chat/completions") {
                let body = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, body)
            } else if req.httpMethod == "HEAD" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "1.1", headerFields: nil)!, Data())
        }
        let service = ConnectionDiagnosticService()
        let results = await service.diagnose(
            descriptor: openAIDescriptor(),
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "sk-test",
            model: "deepseek-chat"
        )
        // Step 1: URL reachable (HEAD returns 200)
        if case .passed = results[.urlReachable] { } else {
            XCTFail("urlReachable should be .passed, got \(String(describing: results[.urlReachable]))")
        }
        // Step 2: Auth (GET /models returns 200)
        if case .passed = results[.authValid] { } else {
            XCTFail("authValid should be .passed, got \(String(describing: results[.authValid]))")
        }
        // Step 3: Model exists
        if case .passed = results[.modelExists] { } else {
            XCTFail("modelExists should be .passed, got \(String(describing: results[.modelExists]))")
        }
        // Step 4: Inference (POST returns 200)
        if case .passed = results[.inferenceWorks] { } else {
            XCTFail("inferenceWorks should be .passed, got \(String(describing: results[.inferenceWorks]))")
        }
    }

    func testURLFailureShortCircuits() async {
        // Step 1 fails (network error). Steps 2-4 should NOT run.
        // We use a handler that always returns 500 (HTTP-level fail).
        // The URL failure we want is "DNS fail" which is
        // best simulated by making the URL invalid (not parseable).
        let service = ConnectionDiagnosticService()
        let results = await service.diagnose(
            descriptor: openAIDescriptor(),
            baseURL: "not a url",  // URL(string:) returns nil
            apiKey: "sk-test",
            model: "deepseek-chat"
        )
        if case .failed = results[.urlReachable] { } else {
            XCTFail("urlReachable should be .failed, got \(String(describing: results[.urlReachable]))")
        }
        // Steps 2-4 should be missing (short-circuit).
        XCTAssertNil(results[.authValid], "authValid should be nil (short-circuit)")
        XCTAssertNil(results[.modelExists], "modelExists should be nil")
        XCTAssertNil(results[.inferenceWorks], "inferenceWorks should be nil")
    }

    func testAuthFailureMentions401() async {
        // Step 1: HEAD returns 200. Step 2: /models returns 401.
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "HEAD" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, Data())
            } else if path.contains("/models") {
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: "1.1", headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "1.1", headerFields: nil)!, Data())
        }
        let service = ConnectionDiagnosticService()
        let results = await service.diagnose(
            descriptor: openAIDescriptor(),
            baseURL: "https://api.example.com/v1",
            apiKey: "bad-key",
            model: "gpt-4o-mini"
        )
        if case .failed(let msg) = results[.authValid] {
            XCTAssertTrue(msg.contains("401"), "expected '401' in message, got '\(msg)'")
            XCTAssertTrue(msg.lowercased().contains("api key") || msg.lowercased().contains("key"), "expected key mention, got '\(msg)'")
        } else {
            XCTFail("authValid should be .failed, got \(String(describing: results[.authValid]))")
        }
        XCTAssertNil(results[.modelExists], "should short-circuit on auth fail")
    }

    func testModelNotInCatalog() async {
        // Step 1: HEAD 200. Step 2: /models 200. Step 3: model
        // not in returned list.
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "HEAD" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, Data())
            } else if path.contains("/models") && req.httpMethod == "GET" {
                let body = #"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "1.1", headerFields: nil)!, Data())
        }
        let service = ConnectionDiagnosticService()
        let results = await service.diagnose(
            descriptor: openAIDescriptor(),
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-test",
            model: "gpt-5"  // not in catalog
        )
        if case .failed(let msg) = results[.modelExists] {
            XCTAssertTrue(msg.contains("gpt-5"), "expected model name in message, got '\(msg)'")
        } else {
            XCTFail("modelExists should be .failed, got \(String(describing: results[.modelExists]))")
        }
    }

    func testOllamaStaticCatalogPass() async {
        // Ollama is a different code path: GET /api/tags
        // not GET /v1/models. The service dispatches on
        // descriptor.discovery.
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "HEAD" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, Data())
            } else if path.contains("/api/tags") {
                let body = #"{"models":[{"name":"gemma2:2b"}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, body)
            } else if path.contains("/chat/completions") {
                let body = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "1.1", headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "1.1", headerFields: nil)!, Data())
        }
        let service = ConnectionDiagnosticService()
        let results = await service.diagnose(
            descriptor: ollamaDescriptor(),
            baseURL: "http://localhost:11434",
            apiKey: "",
            model: "gemma2:2b"
        )
        if case .passed = results[.urlReachable] { } else {
            XCTFail("urlReachable should be .passed")
        }
        if case .passed = results[.authValid] { } else {
            XCTFail("authValid (Ollama) should be .passed, got \(String(describing: results[.authValid]))")
        }
        if case .passed = results[.modelExists] { } else {
            XCTFail("modelExists (gemma2:2b in /api/tags) should be .passed, got \(String(describing: results[.modelExists]))")
        }
        if case .passed = results[.inferenceWorks] { } else {
            XCTFail("inferenceWorks should be .passed, got \(String(describing: results[.inferenceWorks]))")
        }
    }
}
