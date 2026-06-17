import XCTest
@testable import AISpotlightKit

final class ResultMergerTests: XCTestCase {
    private func makeResult(_ path: String, score: Double) -> SearchResult {
        SearchResult(
            title: (path as NSString).lastPathComponent,
            subtitle: nil,
            iconSystemName: "doc",
            url: URL(fileURLWithPath: path),
            kind: .file,
            score: score
        )
    }

    func testMergesAndDeduplicatesByURL() {
        let a: [SearchResult] = [makeResult("/x", score: 5)]
        let b: [SearchResult] = [makeResult("/x", score: 9), makeResult("/y", score: 3)]
        // Phase 6 Step-1.5: new signature takes provider-tagged
        // buckets. Both buckets here are tagged as .fileSystem
        // (weight 1.0), so the dedup-keep-higher logic should keep
        // the score=9 entry.
        let merged = ResultMerger.merge([(.fileSystem, a), (.fileSystem, b)])
        XCTAssertEqual(merged.count, 2, "Should dedupe /x to one entry")
        XCTAssertEqual(merged.first?.score, 9, "Dedupe keeps higher score")
        XCTAssertEqual(merged.first?.weightedScore, 9, "Weighted score == raw score when weight=1")
    }

    func testSortsByScoreDescending() {
        let a: [SearchResult] = [makeResult("/a", score: 1)]
        let b: [SearchResult] = [makeResult("/b", score: 5)]
        let buckets: [(ProviderID, [SearchResult])] = [(.fileSystem, a), (.fileSystem, b)]
        let merged = ResultMerger.merge(buckets)
        // Both providers weight=1, so weightedScore == raw score.
        XCTAssertEqual(merged.map(\.weightedScore), [5, 1])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(ResultMerger.merge([]).isEmpty)
    }

    /// Phase 6 Step-1.5: verify per-provider weight shifts the
    /// ranking. A raw score=20 from `contentSearch` (weight 1.2)
    /// must outrank a raw score=20 from `fileSystem` (weight 1.0).
    func testProviderWeightShiftsRanking() {
        let fileResult = makeResult("/a", score: 20)
        let contentResult = makeResult("/b", score: 20)
        // Same raw score; content should now rank first.
        let merged = ResultMerger.merge([
            (.fileSystem, [fileResult]),
            (.contentSearch, [contentResult])
        ])
        XCTAssertEqual(merged.count, 2)
        guard let first = merged.first, let last = merged.last else {
            return XCTFail("merged should have 2 elements")
        }
        XCTAssertEqual(first.providerID, .contentSearch,
                       "contentSearch (weight 1.2) should outrank fileSystem (weight 1.0) at same raw score")
        XCTAssertEqual(first.weightedScore, 24.0, accuracy: 0.001)
        XCTAssertEqual(last.weightedScore, 20.0, accuracy: 0.001)
    }
}
