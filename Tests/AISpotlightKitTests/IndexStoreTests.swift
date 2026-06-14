import XCTest
@testable import AISpotlightKit

/// Tests for the in-memory inverted index used by Phase 3.1
/// ContentSearchProvider. The store is an actor; tests use a
/// unique temp file per test to keep them hermetic and runnable in
/// any order.
final class IndexStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func storeURL(_ name: String = "index.json") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func makeDoc(_ path: String, mtime: Date = Date(), size: Int = 100) -> IndexDocument {
        IndexDocument(url: URL(fileURLWithPath: path), mtime: mtime, byteSize: size)
    }

    // MARK: - Empty store

    func testEmptyStoreReturnsNoHits() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        let hits = await store.query(["polyester"], limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Upsert + query

    func testUpsertAndQueryOneTerm() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        try await store.upsert(makeDoc(url.path), terms: ["polyester", "chemistry"])

        let hits = await store.query(["polyester"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url, url)
        XCTAssertEqual(hits.first?.score, 1)
    }

    func testQueryMultipleTerms() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        let u1 = URL(fileURLWithPath: "/tmp/a.md")
        let u2 = URL(fileURLWithPath: "/tmp/b.md")
        let u3 = URL(fileURLWithPath: "/tmp/c.md")
        try await store.upsert(makeDoc(u1.path), terms: ["polyester"])
        try await store.upsert(makeDoc(u2.path), terms: ["polyester", "chemistry"])
        try await store.upsert(makeDoc(u3.path), terms: ["chemistry"])

        // Query "polyester" → only a and b
        let pHits = await store.query(["polyester"], limit: 10)
        XCTAssertEqual(Set(pHits.map(\.url)), [u1, u2])

        // Query "chemistry" → only b and c
        let cHits = await store.query(["chemistry"], limit: 10)
        XCTAssertEqual(Set(cHits.map(\.url)), [u2, u3])

        // Query both → b ranks first (matches both)
        let both = await store.query(["polyester", "chemistry"], limit: 10)
        XCTAssertEqual(both.first?.url, u2, "b matches both terms, should rank first")
    }
    func testUpsertReplacesTerms() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        let u = URL(fileURLWithPath: "/tmp/x.md")
        try await store.upsert(makeDoc(u.path), terms: ["old", "stuff"])
        try await store.upsert(makeDoc(u.path), terms: ["new"])

        // "old" should no longer match (replaced)
        let oldHits = await store.query(["old"], limit: 10)
        XCTAssertTrue(oldHits.isEmpty)

        // "new" should match
        let newHits = await store.query(["new"], limit: 10)
        XCTAssertEqual(newHits.count, 1)
    }

    // MARK: - Remove

    func testRemove() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        let u = URL(fileURLWithPath: "/tmp/gone.md")
        try await store.upsert(makeDoc(u.path), terms: ["foo"])
        try await store.remove(u)

        let hits = await store.query(["foo"], limit: 10)
        XCTAssertTrue(hits.isEmpty, "removed doc should not match")
    }

    // MARK: - Limit

    func testQueryRespectsLimit() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        for i in 0..<10 {
            let u = URL(fileURLWithPath: "/tmp/file\(i).md")
            try await store.upsert(makeDoc(u.path), terms: ["term"])
        }
        let hits = await store.query(["term"], limit: 3)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: - Persistence

    func testPersistAndReload() async throws {
        let url = storeURL()
        let s1 = try await IndexStore(diskPath: url)
        let u = URL(fileURLWithPath: "/tmp/persisted.md")
        try await s1.upsert(makeDoc(u.path), terms: ["persistent"])
        try await s1.persist(to: url)

        let s2 = try await IndexStore(diskPath: url)
        let hits = await s2.query(["persistent"], limit: 10)
        XCTAssertEqual(hits.count, 1, "Reloaded store should have the persisted doc")
        XCTAssertEqual(hits.first?.url, u)
    }

    func testLoadFromMissingFileReturnsEmpty() async throws {
        let store = try await IndexStore(diskPath: storeURL("does-not-exist.json"))
        let hits = await store.query(["anything"], limit: 10)
        XCTAssertTrue(hits.isEmpty, "Missing file should not crash; should be empty")
    }

    // MARK: - Stats

    func testStatsReportCounts() async throws {
        let store = try await IndexStore(diskPath: storeURL())
        try await store.upsert(makeDoc("/tmp/a.md"), terms: ["x", "y"])
        try await store.upsert(makeDoc("/tmp/b.md"), terms: ["y", "z"])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 2)
        XCTAssertEqual(stats.uniqueTermCount, 3)  // x, y, z (y is shared)
    }
}
