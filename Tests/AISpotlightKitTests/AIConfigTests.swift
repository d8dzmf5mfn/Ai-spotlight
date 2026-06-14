import XCTest
@testable import AISpotlightKit

/// Tests for the AIConfig → endpoint resolution path. The actual HTTP
/// call against a live OpenAI-compatible server is integration-tested
/// manually (see ~/Documents/AI-Spotlight-Testing.md).
final class AIConfigTests: XCTestCase {
    func testOllamaConfigDefaultEndpoint() {
        let cfg = AIConfig(
            displayName: "Ollama",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            model: "gemma2:2b",
            apiKey: nil
        )
        XCTAssertEqual(cfg.baseURL.host, "localhost")
        XCTAssertEqual(cfg.baseURL.port, 11434)
        XCTAssertEqual(cfg.model, "gemma2:2b")
        XCTAssertNil(cfg.apiKey, "Ollama should not require an API key")
    }

    func testCustomConfigWithAPIKey() {
        let cfg = AIConfig(
            displayName: "Custom",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-4o-mini",
            apiKey: "sk-test123"
        )
        XCTAssertTrue(cfg.baseURL.absoluteString.contains("openai.com"))
        XCTAssertEqual(cfg.model, "gpt-4o-mini")
        XCTAssertEqual(cfg.apiKey, "sk-test123")
    }

    func testConfigEquality() {
        let a = AIConfig(displayName: "X", baseURL: URL(string: "https://x.com")!,
                         model: "m", apiKey: "k")
        let b = AIConfig(displayName: "X", baseURL: URL(string: "https://x.com")!,
                         model: "m", apiKey: "k")
        let c = AIConfig(displayName: "X", baseURL: URL(string: "https://x.com")!,
                         model: "m", apiKey: "k2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "Different API keys should not be equal")
    }
}
