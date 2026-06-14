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
        let a = [makeResult("/x", score: 5)]
        let b = [makeResult("/x", score: 9), makeResult("/y", score: 3)]
        let merged = ResultMerger.merge([a, b])
        XCTAssertEqual(merged.count, 2, "Should dedupe /x to one entry")
        XCTAssertEqual(merged.first?.score, 9, "Dedupe keeps higher score")
    }

    func testSortsByScoreDescending() {
        let a: [SearchResult] = [makeResult("/a", score: 1)]
        let b: [SearchResult] = [makeResult("/b", score: 5)]
        let buckets: [[SearchResult]] = [a, b]
        let merged = ResultMerger.merge(buckets)
        XCTAssertEqual(merged.map(\SearchResult.score), [5, 1])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(ResultMerger.merge([]).isEmpty)
    }
}
