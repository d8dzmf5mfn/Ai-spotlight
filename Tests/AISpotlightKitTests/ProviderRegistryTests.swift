import XCTest
@testable import AISpotlightKit

/// Tests for the Phase 5 ProviderDescriptor + ProviderRegistry.
/// The descriptor is the canonical "shape" of a provider;
/// the registry is the lookup mechanism. Both are pure
/// data — no async, no network — so these tests run fast.
final class ProviderDescriptorTests: XCTestCase {

    func testBearerHeaders() {
        let headers = AuthStyle.bearer.headers(apiKey: "sk-test")
        XCTAssertEqual(headers["Authorization"], "Bearer sk-test")
    }

    func testApiKeyHeader() {
        let headers = AuthStyle.apiKeyHeader(name: "x-api-key").headers(apiKey: "sk-ant-test")
        XCTAssertEqual(headers["x-api-key"], "sk-ant-test")
        XCTAssertNil(headers["Authorization"])
    }

    func testNoAuthHeaders() {
        let headers = AuthStyle.none.headers(apiKey: "ignored")
        XCTAssertTrue(headers.isEmpty)
    }

    func testSupportsModelsListForOpenAI() {
        let d = ProviderDescriptor(
            id: "openai", displayName: "OpenAI",
            defaultBaseURL: "https://api.openai.com/v1", auth: .bearer,
            discovery: .openAIListModels, health: .openAIListModels
        )
        XCTAssertTrue(d.supportsModelsList)
    }

    func testNotSupportsModelsListForAnthropic() {
        let d = ProviderDescriptor(
            id: "anthropic", displayName: "Anthropic",
            defaultBaseURL: "https://api.anthropic.com/v1",
            auth: .apiKeyHeader(name: "x-api-key"),
            discovery: .staticCatalog(["claude-3-5-sonnet-latest"]),
            health: .chatCompletionPing
        )
        XCTAssertFalse(d.supportsModelsList)
    }

    func testStaticCatalogIsDiscoveryStrategy() {
        let catalog = ["claude-3-5-sonnet-latest", "claude-opus-4-0"]
        let d = ProviderDescriptor(
            id: "x", displayName: "X", defaultBaseURL: "",
            auth: .bearer,
            discovery: .staticCatalog(catalog),
            health: .chatCompletionPing
        )
        guard case .staticCatalog(let got) = d.discovery else {
            XCTFail("expected staticCatalog"); return
        }
        XCTAssertEqual(got, catalog)
    }
}

final class ProviderRegistryTests: XCTestCase {

    func testAllHasAtLeastTheOriginalTen() async {
        let all = await ProviderRegistry.shared.all()
        XCTAssertGreaterThanOrEqual(all.count, 10)
    }

    func testDescriptorForKnownId() async {
        let d = await ProviderRegistry.shared.descriptor(for: "openai")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.defaultBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(d?.auth, .bearer)
    }

    func testDescriptorForUnknownId() async {
        let d = await ProviderRegistry.shared.descriptor(for: "not-a-real-provider")
        XCTAssertNil(d)
    }

    func testAnthropicUsesApiKeyHeader() async {
        let d = await ProviderRegistry.shared.descriptor(for: "anthropic")
        guard case .apiKeyHeader(let name) = d?.auth else {
            XCTFail("Anthropic should use apiKeyHeader auth"); return
        }
        XCTAssertEqual(name, "x-api-key")
    }

    func testOllamaHasNoAuth() async {
        let d = await ProviderRegistry.shared.descriptor(for: "ollama")
        XCTAssertEqual(d?.auth, AuthStyle.none)
    }

    func testOllamaUsesOllamaTagsDiscovery() async {
        let d = await ProviderRegistry.shared.descriptor(for: "ollama")
        guard case .ollamaTags = d?.discovery else {
            XCTFail("Ollama should use ollamaTags discovery"); return
        }
    }

    func testAllIdsAreUnique() async {
        let all = await ProviderRegistry.shared.all()
        let ids = all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate provider id")
    }

    func testAllHaveBaseURLOrCustom() async {
        let all = await ProviderRegistry.shared.all()
        for d in all {
            if d.id != "custom" {
                XCTAssertFalse(d.defaultBaseURL.isEmpty,
                              "\\(d.id) needs a defaultBaseURL")
                XCTAssertTrue(d.defaultBaseURL.hasPrefix("https://") || d.defaultBaseURL.hasPrefix("http://"),
                              "\\(d.id) baseURL is not a URL: \\(d.defaultBaseURL)")
            }
        }
    }

    func testSortedByDisplayName() async {
        let all = await ProviderRegistry.shared.all()
        let names = all.map { $0.displayName }
        XCTAssertEqual(names, names.sorted(), "Registry should be sorted")
    }
}
