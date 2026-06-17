import XCTest
@testable import AISpotlightKit

/// Step-1 smoke test for the SQLite augmentation backend.
///
/// See `docs/STEP1_PLAN.md` §4. Step-1 is **soft validation**:
/// these tests verify the type compiles, conforms to
/// `SearchProvider`, and the empty stub returns the expected
/// empty results. They do **not** assert query correctness or
/// any database interaction — that is Step-2 (sync layer) and
/// Step-3 (merge layer) work.
final class SQLiteBackendTests: XCTestCase {

    func testSQLiteBackend_conformsToSearchProvider() {
        let backend: SearchProvider = SQLiteBackend()
        XCTAssertEqual(backend.name, "SQLiteAugmentation")
    }

    func testSQLiteBackend_searchReturnsEmptyInStep1() async {
        let backend = SQLiteBackend()
        // Any intent — Step-1 always returns []. Query logic
        // is Step-3.
        let intent = Intent.openApp(name: "anything")
        let results = await backend.search(intent: intent, limit: 20)
        XCTAssertEqual(results.count, 0)
    }

    func testSQLiteBackend_initDoesNotCrash() {
        // Step-1 init is empty. This test exists so a future
        // regression (e.g. accidentally adding file I/O to init)
        // surfaces as a test failure rather than a runtime crash
        // at app launch.
        let backend = SQLiteBackend()
        XCTAssertNotNil(backend)
    }
}
