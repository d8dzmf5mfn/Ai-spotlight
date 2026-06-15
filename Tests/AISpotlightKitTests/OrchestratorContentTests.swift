import XCTest
@testable import AISpotlightKit

/// Tests for the orchestrator × ContentSearchProvider wiring. The
/// orchestrator is already generic over `[SearchProvider]` (it was
/// designed that way in Phase 1), so this is mostly a regression
/// guard: drop a `ContentSearchProvider` into the bucket and confirm
/// it merges correctly with the existing `FileSystemProvider` /
/// `AppProvider` results.
final class OrchestratorContentTests: XCTestCase {

    private var rootDir: URL!
    private var store: IndexStore!

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestratorContentTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        store = try await IndexStore(diskPath: rootDir.appendingPathComponent("index.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        try await super.tearDown()
    }

    /// Helper: write a file and manually ingest it into the IndexStore.
    /// Bypasses the ContentIndexer so tests are fast and deterministic.
    @discardableResult
    private func ingest(_ name: String, content: String) async throws -> URL {
        let url = rootDir.appendingPathComponent(name)
        try content.data(using: .utf8)?.write(to: url)
        let tokenSet = Set(TextExtractor.tokenize(content).map(\.term))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? Int) ?? content.count
        let doc = IndexDocument(url: url, mtime: mtime, byteSize: size)
        await store.upsert(doc, terms: tokenSet)
        return url
    }

    // MARK: - Wiring

    func testOrchestratorIncludesContentResults() async throws {
        _ = try await ingest("a.md", content: "polyester chemistry notes")
        _ = try await ingest("b.md", content: "polyester synthesis")

        // A bare orchestrator with just the ContentSearchProvider.
        // We don't have real FileSystemProvider/AppProvider in the
        // test target (they require NSWorkspace), so we use a stub
        // that returns no results.
        let stub = StubProvider(results: [])
        let content = ContentSearchProvider(indexStore: store)
        let orchestrator = SearchOrchestrator(providers: [stub, content])

        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester"])
        let results = await orchestrator.run(intent: intent)

        XCTAssertEqual(results.count, 2, "Both content hits should come back")
        let urls = Set(results.map(\.url))
        XCTAssertTrue(urls.contains(URL(fileURLWithPath: rootDir.appendingPathComponent("a.md").path)))
        XCTAssertTrue(urls.contains(URL(fileURLWithPath: rootDir.appendingPathComponent("b.md").path)))
    }

    func testContentResultsRankAboveStubProvider() async throws {
        _ = try await ingest("a.md", content: "polyester")

        // Stub provider that returns a "low score" result, so the
        // content hit (score = 1 + 100 = 101) should outrank it.
        let lowResult = SearchResult(
            title: "low",
            subtitle: nil,
            iconSystemName: "questionmark",
            url: URL(fileURLWithPath: "/tmp/never.md"),
            kind: .file,
            score: 1.0
        )
        let stub = StubProvider(results: [lowResult])
        let content = ContentSearchProvider(indexStore: store)
        let orchestrator = SearchOrchestrator(providers: [stub, content])

        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester"])
        let results = await orchestrator.run(intent: intent)

        XCTAssertEqual(results.first?.score, 101.0, "Content hit should outrank stub")
        XCTAssertEqual(results.first?.title, "a.md")
    }

    func testMergedResultsAreDeduped() async throws {
        // If a file is "found" by both the stub and the content
        // provider, the merger should keep the higher-scored one
        // (i.e. the content hit).
        let a = try await ingest("a.md", content: "polyester")
        let stubResult = SearchResult(
            title: "stub",
            subtitle: nil,
            iconSystemName: "stub",
            url: a,
            kind: .file,
            score: 5.0
        )
        let stub = StubProvider(results: [stubResult])
        let content = ContentSearchProvider(indexStore: store)
        let orchestrator = SearchOrchestrator(providers: [stub, content])

        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester"])
        let results = await orchestrator.run(intent: intent)

        // ResultMerger dedupes by URL, keeps the higher score.
        XCTAssertEqual(results.count, 1, "Same URL from two providers should dedupe")
        XCTAssertEqual(results.first?.score, 101.0, "Higher score wins")
    }

    func testEmptyIndexReturnsEmpty() async {
        // No files ingested — index is empty.
        let stub = StubProvider(results: [])
        let content = ContentSearchProvider(indexStore: store)
        let orchestrator = SearchOrchestrator(providers: [stub, content])

        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["anything"])
        let results = await orchestrator.run(intent: intent)
        XCTAssertTrue(results.isEmpty, "Empty index → no results")
    }

    // MARK: - Helper stub

    /// A SearchProvider that returns a fixed set of results. Used to
    /// simulate FileSystemProvider/AppProvider without dragging in
    /// AppKit (which isn't available in the Kit test target).
    final class StubProvider: SearchProvider, @unchecked Sendable {
        let name = "Stub"
        let results: [SearchResult]
        init(results: [SearchResult]) { self.results = results }
        func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
            return Array(results.prefix(limit))
        }
    }
}
