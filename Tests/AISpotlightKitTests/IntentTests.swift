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
}
