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
}
