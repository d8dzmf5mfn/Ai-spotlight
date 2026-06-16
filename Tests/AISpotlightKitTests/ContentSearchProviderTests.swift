import XCTest
@testable import AISpotlightKit

/// Phase 4.2.10: ContentSearchProvider is now backed by
/// macOS's Spotlight index via MDQuery. There's nothing
/// testable in the "happy path" of a content search without
/// a real indexed corpus (which would require either
/// running actual mds queries against a populated index,
/// or mocking the MDQuery C API — neither of which is
/// worth the test infrastructure for Phase 4.2.10).
///
/// What we CAN test:
/// 1. The provider's name field.
/// 2. That non-.findFile intents are ignored (the only
///    kind we handle is .findFile).
/// 3. That .findFile with empty terms returns empty
///    (we don't build a query string from nothing).
/// 4. That the provider conforms to the protocol
///    contract.
final class ContentSearchProviderTests: XCTestCase {

    // MARK: - Basic wiring

    func testProviderName() {
        let provider = ContentSearchProvider()
        XCTAssertEqual(provider.name, "Content")
    }

    func testIgnoresOpenAppIntent() async {
        let provider = ContentSearchProvider()
        let intent = Intent.openApp(name: "Safari")
        let results = await provider.search(intent: intent)
        XCTAssertTrue(results.isEmpty, "ContentSearchProvider only handles .findFile")
    }

    func testIgnoresUnknownIntent() async {
        let provider = ContentSearchProvider()
        let intent = Intent.unknown(raw: "what is the weather")
        let results = await provider.search(intent: intent)
        XCTAssertTrue(results.isEmpty)
    }

    func testIgnoresFindFileWithoutTerms() async {
        // A .findFile intent with empty terms shouldn't crash;
        // it should just return no results.
        let provider = ContentSearchProvider()
        let intent = Intent.findFile(
            name: "report.pdf",
            dateFilter: nil,
            kind: .pdf,
            terms: []
        )
        let results = await provider.search(intent: intent)
        XCTAssertTrue(results.isEmpty, "Empty terms = no results")
    }

}
