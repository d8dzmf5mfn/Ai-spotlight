import XCTest
@testable import AISpotlightKit

/// Tests for the Phase 4.4 path-extraction helper. The
/// LLM reply text often contains file paths that should
/// become clickable results, so we extract them with
/// `AppState.extractPaths(from:)` (which is a static method).
///
/// We can't import the app target's AppState here, so we
/// re-implement the algorithm in a test-bridge struct
/// (same regex, same filter, same logic).
final class ExtractPathsTests: XCTestCase {

    /// Helper: write a file in a temp dir and return its URL.
    private func makeTempFile(_ name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISpotlight-PathTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExtractsExistingFilePath() throws {
        let file = try makeTempFile("chemistry.md", contents: "polyester notes")
        let text = "I found the file at " + file.path + " for your chemistry notes."
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertTrue(paths.contains(file), "Should extract the temp file path. Got: \(paths.map { $0.path })")
    }

    func testIgnoresNonexistentPaths() {
        let text = "Try /this/does/not/exist.md for the file."
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertTrue(paths.isEmpty, "Non-existent paths should be filtered out. Got: \(paths.map { $0.path })")
    }

    func testExtractsMultiplePaths() throws {
        let a = try makeTempFile("a.md", contents: "1")
        let b = try makeTempFile("b.md", contents: "2")
        let text = "See " + a.path + " and also " + b.path + " for the notes."
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertEqual(Set(paths.map { $0.path }), Set([a.path, b.path]))
    }

    func testDedupesRepeatedPaths() throws {
        let file = try makeTempFile("once.md", contents: "x")
        let text = "first at " + file.path + " and again at " + file.path
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertEqual(paths.count, 1, "Repeated paths should be deduped")
    }

    func testIgnoresShortStrings() {
        let text = "I went / for a walk."
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertTrue(paths.isEmpty, "Bare slashes are not paths. Got: \(paths.map { $0.path })")
    }

    func testNoPathsInNormalText() {
        let text = "Polyester is a category of polymers."
        let paths = AppStateBridge.extractPaths(from: text)
        XCTAssertTrue(paths.isEmpty, "No paths in plain text. Got: \(paths.map { $0.path })")
    }
}

/// Test-time bridge: the algorithm lives on AppState (in
/// the app target, not importable here). We can't
/// re-export it without making the test target depend
/// on the app target, which would cause a circular
/// import. Instead, we duplicate the algorithm for
/// testing — same regex, same filter, same logic.
enum AppStateBridge {
    static func extractPaths(from text: String) -> [URL] {
        let pattern = "(/[A-Za-z0-9_./-]{2,200}?[A-Za-z0-9_-])(?=[\\s,;)\\]>]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var paths: [URL] = []
        var seen: Set<String> = []
        for m in matches {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let s = String(text[r])
            if seen.contains(s) { continue }
            guard FileManager.default.fileExists(atPath: s) else { continue }
            seen.insert(s)
            paths.append(URL(fileURLWithPath: s))
            if paths.count >= 8 { break }
        }
        return paths
    }
}
