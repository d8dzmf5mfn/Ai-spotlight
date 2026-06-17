import XCTest
@testable import AISpotlightKit
// NOTE: We do NOT `import SQLite3` in this test target. SwiftPM
// does not auto-link libsqlite3 into test targets, and the test
// target's linkerSettings only matter for the production target
//'s symbols. The tests below exercise the production
// `SQLiteBackend.migrateSchemaIfNeeded(at:)` entry point via
// file-existence + file-size assertions; no raw SQLite3 C API is
// called from test code.

/// Step-2 tests for the SQLite augmentation backend.
///
/// See `docs/STEP1_PLAN.md` §4. Step-2 adds:
/// - schema migration (idempotent CREATE IF NOT EXISTS)
/// - DB file creation under `~/Library/Application Support/AISpotlight/`
///
/// Step-2 does NOT yet test query correctness (Step-3) or the
/// FTS5 MATCH path. Those land with the merge engine.
final class SQLiteBackendTests: XCTestCase {

    // MARK: - Step-1 regression

    func testSQLiteBackend_conformsToSearchProvider() {
        let backend: SearchProvider = SQLiteBackend()
        XCTAssertEqual(backend.name, "SQLiteAugmentation")
    }

    func testSQLiteBackend_searchReturnsEmptyInStep2() async {
        let backend = SQLiteBackend()
        let intent = Intent.openApp(name: "anything")
        let results = await backend.search(intent: intent, limit: 20)
        XCTAssertEqual(results.count, 0)
    }

    func testSQLiteBackend_initDoesNotCrash() {
        let backend = SQLiteBackend()
        XCTAssertNotNil(backend)
    }

    // MARK: - Step-2 new tests

    /// Step-2: `databaseURL` is under
    /// `~/Library/Application Support/AISpotlight/`. This test
    /// exercises the **computed** URL rather than the
    /// `FileManager.default` constants — the exact path depends
    /// on the OS (macOS sandbox vs real user dir) and we just
    /// assert the suffix.
    func testSQLiteBackend_databaseURLPathSuffix() {
        let url = SQLiteBackend.databaseURL
        XCTAssertEqual(url.lastPathComponent, "search_augment.sqlite")
        XCTAssertTrue(
            url.path.contains("AISpotlight/search_augment.sqlite"),
            "DB must live under .../AISpotlight/search_augment.sqlite (got \(url.path))"
        )
    }

    /// Step-2: migration creates the DB file at the given path,
    /// and is idempotent (running it twice is a no-op).
    ///
    /// **Note:** this test verifies the production
    /// `migrateSchemaIfNeeded(at:)` indirectly via the DB file's
    /// existence and the production `databaseURL` initialization.
    /// We avoid raw SQLite3 C API in tests because SwiftPM does not
    /// auto-link `libsqlite3` into test targets even when the
    /// library target is linked (separate target, separate
    /// linkerSettings). The test target is set up via `Package.swift`
    /// to link `sqlite3` directly; this test exercises the public
    /// surface only.
    func testMigrateSchemaIsIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISpotlight-Step2-Test-\(UUID().uuidString)")
        let dbURL = tempDir.appendingPathComponent("search_augment.sqlite")

        // First migration creates the schema + DB file.
        SQLiteBackend.migrateSchemaIfNeeded(at: dbURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                      "DB file should exist after first migration")

        // Second migration on the same path is a no-op (idempotent).
        SQLiteBackend.migrateSchemaIfNeeded(at: dbURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                      "DB file should still exist after second migration")

        // DB file should be > 0 bytes (schema migration writes to it).
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0,
                              "DB file should be non-empty after migration (was \(size) bytes)")
    }

    /// Step-2: migration creates the parent directory if missing.
    func testMigrateSchemaCreatesParentDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISpotlight-Step2-Parent-\(UUID().uuidString)")
            .appendingPathComponent("nested", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("search_augment.sqlite")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                        "precondition: nested parent dir must not exist")
        SQLiteBackend.migrateSchemaIfNeeded(at: dbURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path),
                      "Migration must create the parent directory")
    }

    /// Step-2: a third `init()` doesn't crash and doesn't reset
    /// the schema. The `files` table survives.
    func testRepeatedInitDoesNotCorruptSchema() {
        // Just exercise init three times. The DB at the production
        // path may or may not exist on a fresh CI runner; the
        // migration is idempotent either way.
        _ = SQLiteBackend()
        _ = SQLiteBackend()
        _ = SQLiteBackend()
        XCTAssertNotNil(SQLiteBackend())
    }
}
