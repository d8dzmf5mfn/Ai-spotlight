import XCTest
@testable import AISpotlightKit

/// Tests for Phase 5-G: MemoryStore. Uses a fresh
/// UserDefaults suite per test so the tests don't pollute
/// the host app's preferences.
final class MemoryStoreTests: XCTestCase {

    /// Each test gets its own UserDefaults instance so the
    /// caps and dedup behavior can be tested in isolation.
    private var defaults: UserDefaults!
    private var store: MemoryStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // UserDefaults in test mode ignores the suiteName
        // argument when running under XCTest, so we fall
        // back to the standard suite and clean up before
        // each test by removing our keys. (In CI, the test
        // target's bundle is sandboxed so this isolation
        // is automatic.)
        defaults.removePersistentDomain(forName: suiteName)
        store = MemoryStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testRecordFileOpen() async {
        let url = URL(fileURLWithPath: "/tmp/test-file-open.md")
        await store.recordFileOpen(url)
        let list = store.recentFiles()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0], "/tmp/test-file-open.md")
    }

    func testRecordFileOpenDedupeAndCap() async {
        // Add 25 unique paths; the cap is 20.
        for i in 0..<25 {
            await store.recordFileOpen(URL(fileURLWithPath: "/tmp/file-\(i).md"))
        }
        let list = store.recentFiles()
        XCTAssertEqual(list.count, 20)
        // Most recently added should be at the front.
        XCTAssertEqual(list[0], "/tmp/file-24.md")
        XCTAssertEqual(list[19], "/tmp/file-5.md")
        // Re-opening an existing file should move it to the
        // front, not duplicate it.
        await store.recordFileOpen(URL(fileURLWithPath: "/tmp/file-3.md"))
        let list2 = store.recentFiles()
        XCTAssertEqual(list2.count, 20)
        XCTAssertEqual(list2[0], "/tmp/file-3.md")
        // file-3 should no longer appear in the tail.
        XCTAssertFalse(list2.contains("/tmp/file-3.md", at: list2.count - 5..<list2.count))
    }

    func testRecordSearchTrimsAndDedupes() async {
        await store.recordSearch("  hello world  ")
        await store.recordSearch("hello world")  // duplicate after trim
        await store.recordSearch("different query")
        let list = store.recentSearches()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0], "different query")
        XCTAssertEqual(list[1], "hello world")
    }

    func testRecordEmptySearchIgnored() async {
        await store.recordSearch("   ")
        XCTAssertEqual(store.recentSearches().count, 0)
    }

    func testRecordAppLaunchCap() async {
        for i in 0..<15 {
            await store.recordAppLaunch("App\(i)")
        }
        let list = store.recentApps()
        XCTAssertEqual(list.count, 10, "App cap is 10")
        XCTAssertEqual(list[0], "App14")
    }

    func testContextBlockEmptyWhenNothing() {
        let block = store.contextBlockSync()
        XCTAssertEqual(block, "")
    }

    func testContextBlockFormatsAllThree() async {
        await store.recordFileOpen(URL(fileURLWithPath: "/tmp/report.md"))
        await store.recordFileOpen(URL(fileURLWithPath: "/tmp/notes.md"))
        await store.recordSearch("polyester")
        await store.recordAppLaunch("Notes")
        let block = store.contextBlockSync()
        XCTAssertTrue(block.contains("report.md"))
        XCTAssertTrue(block.contains("notes.md"))
        XCTAssertTrue(block.contains("polyester"))
        XCTAssertTrue(block.contains("Notes"))
        XCTAssertTrue(block.contains("Recent activity"))
    }

    func testClearAll() async {
        await store.recordFileOpen(URL(fileURLWithPath: "/tmp/clear-test.md"))
        await store.recordSearch("clear test")
        await store.recordAppLaunch("ClearApp")
        XCTAssertFalse(store.recentFiles().isEmpty)
        store.clearAll()
        XCTAssertEqual(store.recentFiles().count, 0)
        XCTAssertEqual(store.recentSearches().count, 0)
        XCTAssertEqual(store.recentApps().count, 0)
    }
}

// Small extension for contains(_:at:) which doesn't exist on Array.
extension Array where Element == String {
    func contains(_ element: String, at indices: Range<Int>) -> Bool {
        for i in indices where indices.contains(i) && self[i] == element {
            return true
        }
        return false
    }
}
