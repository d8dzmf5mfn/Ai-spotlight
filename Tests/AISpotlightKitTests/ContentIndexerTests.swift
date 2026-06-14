import XCTest
@testable import AISpotlightKit

/// Tests for the directory walker + incremental indexer. Uses
/// a real temp directory (with real files) because the indexer's
/// mtime-based skip logic depends on actual file system behavior.
final class ContentIndexerTests: XCTestCase {

    private var rootDir: URL!
    private var store: IndexStore!

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIndexerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        store = try await IndexStore(diskPath: rootDir.appendingPathComponent("index.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        try await super.tearDown()
    }

    // MARK: - Helper

    /// Write a file with the given content, returning its URL.
    @discardableResult
    private func writeFile(_ name: String, content: String = "hello world") throws -> URL {
        let url = rootDir.appendingPathComponent(name)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    /// Write a file inside a subdirectory (creating the dir).
    @discardableResult
    private func writeFile(in subdir: String, name: String, content: String = "hello") throws -> URL {
        let dir = rootDir.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    // MARK: - Walk + index basics

    func testIndexesAllSupportedFiles() async throws {
        try writeFile("a.md", content: "polyester")
        try writeFile("b.swift", content: "let x = 1")
        try writeFile("c.txt", content: "more text")

        let indexer = ContentIndexer(store: store)
        let progress = await indexer.index(roots: [rootDir])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 3)
        XCTAssertGreaterThan(progress.filesScanned, 0)
    }

    func testSkipsUnsupportedExtensions() async throws {
        try writeFile("a.md", content: "index me")
        try writeFile("b.exe", content: "skip me")    // not in supportedExtensions
        try writeFile("c.dmg", content: "skip me too")

        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 1, "Only .md should be indexed")
    }

    func testSkipsHiddenAndBuildDirs() async throws {
        // .git, node_modules, build, .next, dist, .venv, __pycache__, .DS_Store
        try writeFile("regular.md", content: "keep")
        try writeFile(in: ".git", name: "config.md", content: "skip")
        try writeFile(in: "node_modules", name: "package.md", content: "skip")
        try writeFile(in: "build", name: "out.md", content: "skip")
        try writeFile(in: ".next", name: "cache.md", content: "skip")
        try writeFile(in: "dist", name: "bundle.md", content: "skip")
        try writeFile(in: ".venv", name: "py.md", content: "skip")
        try writeFile(in: "__pycache__", name: "cache.md", content: "skip")
        try writeFile(".DS_Store", content: "skip")

        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 1, "Only the top-level regular.md should be indexed")
    }

    func testSkipsExtensionlessBinaryFiles() async throws {
        try writeFile("a.md", content: "index me")
        // .DS_Store is a binary file with no extension — we should
        // attempt to read it, find it's not UTF-8, and skip it.
        let dsStore = rootDir.appendingPathComponent(".DS_Store")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: dsStore)

        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 1)
    }

    // MARK: - Mtime change detection

    func testSkipsUnchangedFiles() async throws {
        try writeFile("a.md", content: "polyester")
        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])

        // Re-index without changing the file. Indexer's mtime check
        // should skip it (no re-tokenize). We can't easily prove "skip"
        // from the outside, so just verify the index still has it.
        _ = await indexer.index(roots: [rootDir])
        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 1)
    }
    func testReindexesChangedFiles() async throws {
        let url = try writeFile("a.md", content: "polyester")
        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])

        // Change the file — token "chemistry" should appear after re-index
        try "polyester chemistry notes".data(using: .utf8)?.write(to: url)
        // Sleep so the mtime definitely differs
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        _ = await indexer.index(roots: [rootDir])

        let hits = await store.query(["chemistry"], limit: 10)
        XCTAssertEqual(hits.count, 1, "Modified file should be re-indexed with new terms")
    }

    func testRemovesDeletedFiles() async throws {
        let url = try writeFile("a.md", content: "polyester")
        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir])
        let stats1 = await store.stats()
        XCTAssertEqual(stats1.documentCount, 1)

        // Delete the file outside the indexer, then re-index
        try FileManager.default.removeItem(at: url)
        _ = await indexer.index(roots: [rootDir])

        let stats2 = await store.stats()
        XCTAssertEqual(stats2.documentCount, 0, "Deleted file should be evicted")
    }

    // MARK: - Multiple roots

    func testIndexesMultipleRoots() async throws {
        let root2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIndexerTests-root2-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root2) }

        try writeFile("fromRoot1.md", content: "a")
        try "fromRoot2.md".data(using: .utf8)?.write(to: root2.appendingPathComponent("fromRoot2.md"))

        let indexer = ContentIndexer(store: store)
        _ = await indexer.index(roots: [rootDir, root2])

        let stats = await store.stats()
        XCTAssertEqual(stats.documentCount, 2)
    }

    // MARK: - Progress reporting

    func testProgressReportsFileCounts() async throws {
        try writeFile("a.md", content: "x")
        try writeFile("b.md", content: "y")
        try writeFile("c.md", content: "z")

        let indexer = ContentIndexer(store: store)
        let progress = await indexer.index(roots: [rootDir])

        XCTAssertEqual(progress.filesScanned, 3, "Should report total scanned count")
        XCTAssertEqual(progress.filesIndexed, 3, "All 3 should be indexed (all new)")
    }

    func testProgressReportsReindexedAndSkipped() async throws {
        try writeFile("a.md", content: "unchanged")
        let indexer = ContentIndexer(store: store)
        let p1 = await indexer.index(roots: [rootDir])
        XCTAssertEqual(p1.filesIndexed, 1)

        // Sleep to ensure mtime resolution on APFS (1 nanosecond
        // resolution but we want seconds-level for a clean diff).
        try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1s

        let p2 = await indexer.index(roots: [rootDir])
        XCTAssertEqual(p2.filesScanned, 1)
        XCTAssertEqual(p2.filesIndexed, 0, "Unchanged file should be skipped (not re-indexed)")
    }
}
