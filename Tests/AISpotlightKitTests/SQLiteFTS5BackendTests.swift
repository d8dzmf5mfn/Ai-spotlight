import XCTest
@testable import AISpotlightKit

/// Tests for SQLiteFTS5Backend. Each test creates a
/// fresh temp DB so they're isolated from each other
/// and from the in-memory backend tests.
final class SQLiteFTS5BackendTests: XCTestCase {

    /// Build a fresh backend with a unique temp DB path.
    /// The DB file is deleted in `tearDownWithError`.
    private func makeBackend(file: String = #function) -> SQLiteFTS5Backend {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(file)-\(UUID().uuidString).sqlite3")
        return SQLiteFTS5Backend(dbPath: url)
    }

    func testEmptyIndexReturnsEmpty() async throws {
        let backend = makeBackend()
        let hits = try await backend.query(["polyester"], limit: 10)
        XCTAssertEqual(hits.count, 0)
        let stats = try await backend.stats()
        XCTAssertEqual(stats.documentCount, 0)
    }

    func testUpsertAndQuery() async throws {
        let backend = makeBackend()
        let url1 = URL(fileURLWithPath: "/tmp/test1.md")
        let url2 = URL(fileURLWithPath: "/tmp/test2.md")

        _ = try await backend.upsert(
            IndexDocument(url: url1, mtime: Date(), byteSize: 100),
            terms: ["polyester", "chemistry"]
        )
        _ = try await backend.upsert(
            IndexDocument(url: url2, mtime: Date(), byteSize: 100),
            terms: ["polyester", "biology"]
        )

        let hits = try await backend.query(["polyester"], limit: 10)
        XCTAssertEqual(hits.count, 2)

        let chemHits = try await backend.query(["chemistry"], limit: 10)
        XCTAssertEqual(chemHits.count, 1)
        XCTAssertEqual(chemHits.first?.url, url1)
    }

    func testBulkLoadReplaces() async throws {
        let backend = makeBackend()
        let url1 = URL(fileURLWithPath: "/tmp/a.md")
        let url2 = URL(fileURLWithPath: "/tmp/b.md")

        _ = try await backend.upsert(
            IndexDocument(url: url1, mtime: Date(), byteSize: 100),
            terms: ["first"]
        )
        try await backend.bulkLoad([
            (2, IndexDocument(url: url2, mtime: Date(), byteSize: 100), ["second"]),
        ])
        let hits1 = try await backend.query(["first"], limit: 10)
        XCTAssertEqual(hits1.count, 0, "Old doc should be evicted by bulkLoad")
        let hits2 = try await backend.query(["second"], limit: 10)
        XCTAssertEqual(hits2.count, 1, "New doc should be in index")
    }

    func testRemove() async throws {
        let backend = makeBackend()
        let url = URL(fileURLWithPath: "/tmp/removeme.md")
        _ = try await backend.upsert(
            IndexDocument(url: url, mtime: Date(), byteSize: 100),
            terms: ["test", "remove"]
        )
        let beforeHits = try await backend.query(["test"], limit: 10)
        XCTAssertEqual(beforeHits.count, 1)
        try await backend.remove(url)
        let afterHits = try await backend.query(["test"], limit: 10)
        XCTAssertEqual(afterHits.count, 0)
    }

    func testScoreHigherForMoreMatches() async throws {
        // Documents matching more query terms should
        // rank higher. The InMemory backend scored
        // by match count; the SQLite backend uses
        // bm25, which has the same intuition.
        let backend = makeBackend()
        let urlA = URL(fileURLWithPath: "/tmp/a.md")
        let urlB = URL(fileURLWithPath: "/tmp/b.md")
        _ = try await backend.upsert(
            IndexDocument(url: urlA, mtime: Date(), byteSize: 100),
            terms: ["polyester", "chemistry", "biology"]
        )
        _ = try await backend.upsert(
            IndexDocument(url: urlB, mtime: Date(), byteSize: 100),
            terms: ["polyester"]
        )
        let hits = try await backend.query(["polyester", "chemistry"], limit: 10)
        XCTAssertEqual(hits.count, 2)
        // A matches both terms, B matches only one.
        // A should have the higher score.
        XCTAssertEqual(hits.first?.url, urlA)
    }

    func testPersistence() async throws {
        // Insert, close, reopen, query. The index
        // should be durable across backend instances.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let docURL = URL(fileURLWithPath: "/tmp/persisttest.md")
        do {
            let backend = SQLiteFTS5Backend(dbPath: url)
            _ = try await backend.upsert(
                IndexDocument(url: docURL, mtime: Date(), byteSize: 100),
                terms: ["persistent", "data"]
            )
            try await backend.persist()
        }
        // Reopen the same DB file in a new backend.
        let reopened = SQLiteFTS5Backend(dbPath: url)
        let hits = try await reopened.query(["persistent"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url, docURL)
    }
}
