import XCTest
@testable import AISpotlightKit

final class IntentTests: XCTestCase {
    func testFindFileRoundTripsThroughJSON() throws {
        let original = Intent.findFile(name: "report", dateFilter: .yesterday, kind: .pdf)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded, "Intent must survive a JSON round-trip")
    }

    func testOpenAppRoundTripsThroughJSON() throws {
        let original = Intent.openApp(name: "Safari")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testUnknownRoundTripsThroughJSON() throws {
        let original = Intent.unknown(raw: "what is the weather")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Phase 3 additions

    /// Phase 3.1: a findFile with `terms` (the content-search keywords) must
    /// round-trip through JSON. The default `terms: []` must NOT change
    /// the existing wire format (backwards-compat with Phase 1/2 callers).
    func testFindFileWithTermsRoundTripsThroughJSON() throws {
        let original = Intent.findFile(
            name: "report.pdf",
            dateFilter: .lastWeek,
            kind: .pdf,
            terms: ["polyester", "chemistry"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded)
        // Spot-check the values after round-trip, in case the enum
        // case-equal but associated values diverge.
        if case let .findFile(name, date, kind, terms) = decoded {
            XCTAssertEqual(name, "report.pdf")
            XCTAssertEqual(date, .lastWeek)
            XCTAssertEqual(kind, .pdf)
            XCTAssertEqual(terms, ["polyester", "chemistry"])
        } else {
            XCTFail("Round-trip lost case info: \(decoded)")
        }
    }

    /// Phase 3.4: a conversational "ask" intent must round-trip through
    /// JSON. Default `contextURLs: []` keeps the wire format minimal
    /// when no file context is attached.
    func testAskRoundTripsThroughJSON() throws {
        let original = Intent.ask(
            query: "summarize my notes on polyester",
            contextURLs: [URL(fileURLWithPath: "/tmp/notes.md")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded)
        if case let .ask(query, urls) = decoded {
            XCTAssertEqual(query, "summarize my notes on polyester")
            XCTAssertEqual(urls.count, 1)
            XCTAssertEqual(urls[0].path, "/tmp/notes.md")
        } else {
            XCTFail("Round-trip lost case info: \(decoded)")
        }
    }

    /// Phase 3.4: the default `Intent.ask(query: "hi")` (no context URLs)
    /// must still round-trip cleanly — the empty URL array is part of
    /// the wire format, not a "missing field" the decoder has to guess.
    func testAskEmptyContextURLsRoundTripsThroughJSON() throws {
        let original = Intent.ask(query: "hi")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Intent.self, from: data)
        XCTAssertEqual(original, decoded)
        if case let .ask(query, urls) = decoded {
            XCTAssertEqual(query, "hi")
            XCTAssertTrue(urls.isEmpty)
        } else {
            XCTFail("Round-trip lost case info: \(decoded)")
        }
    }
}
