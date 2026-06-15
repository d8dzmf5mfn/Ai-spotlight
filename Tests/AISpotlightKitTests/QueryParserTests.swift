import XCTest
@testable import AISpotlightKit

final class QueryParserTests: XCTestCase {
    func testParsesYesterdayPDF() {
        let intent = QueryParser.parse("find the PDF I downloaded yesterday")
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: .yesterday, kind: .pdf))
    }

    func testParsesTodayFile() {
        let intent = QueryParser.parse("show me files I edited today")
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: .today, kind: nil))
    }

    func testParsesOpenApp() {
        let intent = QueryParser.parse("open Safari")
        XCTAssertEqual(intent, .openApp(name: "Safari"))
    }

    func testParsesChineseFindPDF() {
        let intent = QueryParser.parse("找昨天下载的 PDF")
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: .yesterday, kind: .pdf))
    }

    func testParsesNamedFile() {
        let intent = QueryParser.parse("find report.pdf")
        XCTAssertEqual(intent, .findFile(name: "report.pdf", dateFilter: nil, kind: .pdf))
    }

    func testUnknownReturnsUnknown() {
        let intent = QueryParser.parse("hello world")
        XCTAssertEqual(intent, .unknown(raw: "hello world"))
    }

    // MARK: - Phase 4.2: prefix-free app + file lookup

    /// "Safari" alone should be an app open — no `open` prefix needed.
    /// This matches Spotlight/Raycast behavior: type a single word,
    /// if it's a known app, open it.
    func testParsesSingleWordAsApp() {
        let intent = QueryParser.parse("Safari")
        XCTAssertEqual(intent, .openApp(name: "Safari"))
    }

    /// Multi-word app names like "Visual Studio Code" should also
    /// open without needing `open` — the file system would have
    /// no file matching that name, so a multi-token query that
    /// doesn't look like a find query is an app.
    func testParsesMultiWordAppName() {
        let intent = QueryParser.parse("Visual Studio Code")
        XCTAssertEqual(intent, .openApp(name: "Visual Studio Code"))
    }

    /// "open Safari" should still work (regression: don't break
    /// the explicit prefix).
    func testParsesOpenAppWithPrefix() {
        let intent = QueryParser.parse("open Safari")
        XCTAssertEqual(intent, .openApp(name: "Safari"))
    }

    /// "find Safari" should still find a file (find verb wins).
    /// Regression test for the "find verb precedence" rule.
    func testParsesFindVerbTakesPrecedence() {
        let intent = QueryParser.parse("find Safari")
        // "find" is a find verb — it triggers matchFile. "Safari"
        // has no file extension dot, so name is nil. The intent
        // is .findFile with the find verb signal; the orchestrator
        // does the actual filename fuzzy match.
        XCTAssertEqual(intent, .findFile(name: nil, dateFilter: nil, kind: nil))
    }

    // --- Regression: substring-matching bugs found in adversarial review ---

    func testShowerDoesNotTriggerFind() {
        // "shower" contains "show" as substring — must NOT be classified as find-verb.
        // Input has no date/kind either, so a buggy parser would (and did) return findFile.
        // The fix: verb matching uses token set (exact words), not substring search.
        let intent = QueryParser.parse("I had a shower")
        XCTAssertEqual(intent, .unknown(raw: "I had a shower"),
                       "Substring 'show' inside 'shower' must not trigger find-verb")
    }

    func testForgotDoesNotTriggerFind() {
        // "forgot" does NOT contain "get" (f-o-r-g-o-t) — the substring trap
        // fires only on tokens that actually contain the verb as a substring
        // (e.g. "shower" contains "show", "opening" contains "open").
        // This test pins that "forgot" stays .unknown as a regression guard
        // against any future change that breaks exact-word verb matching.
        let intent = QueryParser.parse("I forgot the file")
        XCTAssertEqual(intent, .unknown(raw: "I forgot the file"))
    }

    func testOpeningDoesNotTriggerFind() {
        // "opening" contains "open" — must NOT be misclassified as find-verb
        let intent = QueryParser.parse("the opening of the file")
        XCTAssertEqual(intent, .unknown(raw: "the opening of the file"),
                       "Substring 'open' inside 'opening' must not trigger find-verb")
    }

    func testTrailingPeriodNotTreatedAsFilename() {
        // "Find notes." should NOT extract "notes." as a filename
        let intent = QueryParser.parse("Find notes.")
        if case let .findFile(name, _, _, _) = intent {
            XCTAssertNil(name, "Trailing period must not be treated as a filename, got \(String(describing: name))")
        }
        // If we got .findFile at all here, that's also acceptable — but name must be nil
    }

    func testLeadingWhitespaceHandled() {
        // Leading tab/space must not break the open-verb prefix check
        let intent = QueryParser.parse("  open Safari")
        XCTAssertEqual(intent, .openApp(name: "Safari"),
                       "Leading whitespace must be trimmed before verb matching")
    }
}
