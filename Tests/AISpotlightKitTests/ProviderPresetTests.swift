import XCTest
@testable import AISpotlightKit

/// Tests for the cloud-model preset list. We don't make
/// any HTTP calls here — those would need real API
/// keys and a network. We just verify the static
/// structure (presets exist, URLs are well-formed,
/// model names are non-empty) and the lookup helper.
final class ProviderPresetTests: XCTestCase {

    func testAllPresetsHaveRequiredFields() {
        for p in ProviderPreset.all {
            XCTAssertFalse(p.id.isEmpty, "preset id is empty")
            XCTAssertFalse(p.displayName.isEmpty, "preset \\(p.id) displayName is empty")
            // "custom" is the catch-all with empty URL/model —
            // skip the URL/model check for it.
            if p.id != "custom" {
                XCTAssertFalse(p.defaultBaseURL.isEmpty, "preset \\(p.id) baseURL is empty")
                XCTAssertTrue(p.defaultBaseURL.hasPrefix("https://") || p.defaultBaseURL.hasPrefix("http://"),
                              "preset \\(p.id) baseURL is not a URL: \\(p.defaultBaseURL)")
                XCTAssertFalse(p.defaultModel.isEmpty,
                              "preset \\(p.id) defaultModel is empty")
            }
        }
    }

    func testAllPresetsHaveUniqueIds() {
        let ids = ProviderPreset.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate preset id in \\(ids)")
    }

    func testIncludesBothChineseAndInternationalProviders() {
        let ids = ProviderPreset.all.map { $0.id }
        // Chinese providers.
        XCTAssertTrue(ids.contains("deepseek"), "missing DeepSeek")
        XCTAssertTrue(ids.contains("zhipu"), "missing Zhipu GLM")
        // International providers.
        XCTAssertTrue(ids.contains("openai"), "missing OpenAI")
    }

    func testByIdReturnsPreset() {
        XCTAssertNotNil(ProviderPreset.by(id: "deepseek"))
        XCTAssertNotNil(ProviderPreset.by(id: "openai"))
        XCTAssertEqual(ProviderPreset.by(id: "deepseek")?.defaultBaseURL,
                       "https://api.deepseek.com/v1")
    }

    func testByIdReturnsNilForUnknown() {
        XCTAssertNil(ProviderPreset.by(id: "not-a-real-provider"))
        XCTAssertNil(ProviderPreset.by(id: ""))
    }

    func testDeepSeekUsesCorrectModel() {
        // deepseek-chat is the current model name. If
        // DeepSeek renames it, this test will need
        // updating — that's intentional, the test
        // is a tripwire for that change.
        let preset = ProviderPreset.by(id: "deepseek")
        XCTAssertEqual(preset?.defaultModel, "deepseek-chat")
    }
}
