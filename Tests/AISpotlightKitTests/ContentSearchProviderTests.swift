import XCTest
@testable import AISpotlightKit

/// Tests for the content-aware SearchProvider. Wires IndexStore +
/// TextExtractor into the existing orchestrator pipeline.
final class ContentSearchProviderTests: XCTestCase {

    private var rootDir: URL!
    private var store: IndexStore!

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentSearchProviderTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        store = try await IndexStore(diskPath: rootDir.appendingPathComponent("index.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        try await super.tearDown()
    }

    /// Helper: write a file with the given content.
    @discardableResult
    private func writeFile(_ name: String, content: String) throws -> URL {
        let url = rootDir.appendingPathComponent(name)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    /// Helper: ingest a file by manually upserting its terms into the
    /// store. Bypasses ContentIndexer (which would walk the directory
    /// and need real file timing) so tests are fast and deterministic.
    private func ingest(_ url: URL, content: String) async throws {
        let tokenSet = Set(TextExtractor.tokenize(content).map(\.term))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? Int) ?? content.count
        let doc = IndexDocument(url: url, mtime: mtime, byteSize: size)
        await store.upsert(doc, terms: tokenSet)
    }

    // MARK: - Basic wiring

    func testProviderName() {
        let provider = ContentSearchProvider(indexStore: store)
        XCTAssertEqual(provider.name, "Content")
    }

    func testIgnoresNonFindFileIntents() async throws {
        let provider = ContentSearchProvider(indexStore: store)
        let openIntent = Intent.openApp(name: "Safari")
        let results = await provider.search(intent: openIntent)
        XCTAssertTrue(results.isEmpty, "ContentSearchProvider only handles .findFile")

        let unknownIntent = Intent.unknown(raw: "what is the weather")
        let results2 = await provider.search(intent: unknownIntent)
        XCTAssertTrue(results2.isEmpty)
    }

    func testIgnoresFindFileWithoutTerms() async throws {
        // A .findFile intent with empty terms shouldn't crash; it
        // should just return no results.
        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: "report.pdf", dateFilter: nil, kind: .pdf, terms: [])
        let results = await provider.search(intent: intent)
        XCTAssertTrue(results.isEmpty, "Empty terms = no results")
    }

    // MARK: - Content matching

    func testFindsFilesByContentTerm() async throws {
        let a = try writeFile("a.md", content: "polyester chemistry notes")
        try await ingest(a, content: "polyester chemistry notes")

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester"])
        let results = await provider.search(intent: intent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, a)
    }

    func testFindsFilesByMultipleTerms() async throws {
        let a = try writeFile("a.md", content: "polyester chemistry")
        let b = try writeFile("b.md", content: "polyester synthesis")
        let c = try writeFile("c.md", content: "unrelated content")
        try await ingest(a, content: "polyester chemistry")
        try await ingest(b, content: "polyester synthesis")
        try await ingest(c, content: "unrelated content")

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester", "chemistry"])
        let results = await provider.search(intent: intent)
        let urls = Set(results.map(\.url))
        XCTAssertTrue(urls.contains(a), "a matches both terms")
        XCTAssertTrue(urls.contains(b), "b matches one term")
        XCTAssertFalse(urls.contains(c), "c matches nothing")
    }

    func testHigherMatchingTermCountRanksFirst() async throws {
        // a matches 2 terms, b matches 1. a should come first.
        let a = try writeFile("a.md", content: "polyester chemistry deep dive")
        let b = try writeFile("b.md", content: "polyester only")
        try await ingest(a, content: "polyester chemistry deep dive")
        try await ingest(b, content: "polyester only")

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester", "chemistry"])
        let results = await provider.search(intent: intent)
        XCTAssertEqual(results.first?.url, a, "2-match should outrank 1-match")
    }

    // MARK: - Snippet

    func testReturnsContentSnippet() async throws {
        let text = "The quick brown fox jumps over the lazy dog and runs into the forest"
        let url = try writeFile("a.md", content: text)
        try await ingest(url, content: text)

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["fox"])
        let results = await provider.search(intent: intent)
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.contentSnippet)
        XCTAssertTrue(results.first?.contentSnippet?.contains("fox") ?? false,
                      "Snippet should include the match")
    }

    // MARK: - Limit

    func testRespectsLimit() async throws {
        // 5 files, all matching; limit to 3.
        for i in 0..<5 {
            let url = try writeFile("file\(i).md", content: "polyester")
            try await ingest(url, content: "polyester")
        }

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: nil, dateFilter: nil, kind: nil,
                                     terms: ["polyester"])
        // The provider's `search` has a `limit: Int = 20` default param;
        // we can't pass it through Intent. We exercise the limit by
        // adding more docs than the default — but here the search itself
        // honors the default 20, so we just verify we got the doc.
        _ = await provider.search(intent: intent)
        // Also exercise the limit param directly (verifies the API
        // surface has a `limit` parameter, separate from Intent).
        let directResults = await provider.search(intent: intent, limit: 3)
        XCTAssertLessThanOrEqual(directResults.count, 3)
    }

    // MARK: - Combined with name (filename MDQuery)

    func testNameAndTermsBothMatch() async throws {
        // The current implementation is terms-only (Phase 3.1 MVP).
        // Verifies that Intent carrying both `name` and `terms` still
        // returns content hits (by terms). Name is used by
        // FileSystemProvider in the orchestrator.
        let a = try writeFile("notes.md", content: "polyester")
        try await ingest(a, content: "polyester")

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(name: "notes.md", dateFilter: nil, kind: .document,
                                     terms: ["polyester"])
        let results = await provider.search(intent: intent)
        XCTAssertEqual(results.count, 1, "name + terms → still returns content hit")
    }

    // MARK: - DateFilter and kind

    func testDateFilterIsIgnored() async throws {
        // Phase 3.1 MVP: the ContentSearchProvider doesn't filter by
        // date or kind — it relies on the orchestrator to fan out to
        // FileSystemProvider for those. We pass a non-nil dateFilter
        // and confirm we still get the hit.
        let a = try writeFile("a.md", content: "polyester")
        try await ingest(a, content: "polyester")

        let provider = ContentSearchProvider(indexStore: store)
        let intent = Intent.findFile(
            name: nil,
            dateFilter: .lastWeek,  // ignored by ContentSearchProvider
            kind: nil,
            terms: ["polyester"]
        )
        let results = await provider.search(intent: intent)
        XCTAssertEqual(results.count, 1, "ContentSearchProvider should ignore dateFilter")
    }
}
