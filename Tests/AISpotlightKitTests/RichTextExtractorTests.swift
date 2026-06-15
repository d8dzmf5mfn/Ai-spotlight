import XCTest
import AppKit
@testable import AISpotlightKit

/// Tests for the rich-text extractor (.rtf, .html). Uses
/// `NSAttributedString` as the unified parser — it knows how to
/// load each format via `.documentType` options.
///
/// **Test execution note:** On macOS 27 beta / Xcode 27 beta, running
/// this test target via `swift test` hangs the test launcher (the
/// `xctest` parent process is alive in S state with 0% CPU and 0
/// child processes). The Kit compiles cleanly with `import AppKit`
/// and `swift build -c release` succeeds. The hang is suspected to
/// be in the AppKit-bridged test harness. See
/// `~/.hermes/skills/macos-swiftpm-bug-hang` for workaround attempts.
final class RichTextExtractorTests: XCTestCase {

    private var rootDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichTextExtractorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        try await super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, content: Data) throws -> URL {
        let url = rootDir.appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    /// Build a small but valid RTF file. The minimum valid RTF is
    /// the header `{\rtf1\pard text\par}`.
    private func minimalRTF(_ text: String) -> String {
        // \\\\ is a backslash in the RTF source. The font size and
        // family are required to make NSAttributedString happy.
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2709 " +
        "\\cocoasubrtf270 " +
        "{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;}" +
        "{\\colortbl;\\red255\\green255\\blue255;}" +
        "\\*\\expandedcolortbl;;\\csgray\\c100000;" +
        "\\paperw11900\\paperh16840\\margl1440\\margr1440\\vieww11520\\viewh15200\\viewkind0" +
        "\\deftab720" +
        "\\pard\\pardeftab720\\partightenfactor100" +
        "\\f0\\fs28 \\cf1 " + text + "\\" + "par" + "}"
    }

    // MARK: - RTF

    func testRTFExtractsText() throws {
        let url = try write("a.rtf", content: Data(minimalRTF("polyester chemistry notes").utf8))
        let text = try RichTextExtractor.extract(url)
        XCTAssertTrue(text.contains("polyester"),
                      "RTF should yield plain text. Got: \(text)")
    }

    func testRTFLowercasesOutput() throws {
        let url = try write("a.rtf", content: Data(minimalRTF("POLYESTER").utf8))
        let text = try RichTextExtractor.extract(url)
        XCTAssertEqual(text, text.lowercased())
    }

    // MARK: - HTML

    func testHTMLExtractsText() throws {
        let html = "<html><body><p>polyester chemistry notes</p></body></html>"
        let url = try write("a.html", content: Data(html.utf8))
        let text = try RichTextExtractor.extract(url)
        XCTAssertTrue(text.contains("polyester"),
                      "HTML should yield plain text. Got: \(text)")
    }

    // MARK: - Missing file

    func testMissingFileThrows() {
        let bogus = rootDir.appendingPathComponent("missing.rtf")
        XCTAssertThrowsError(try RichTextExtractor.extract(bogus))
    }

    // MARK: - Corrupt file

    func testCorruptRTFThrows() throws {
        // "This is not RTF data" — NSAttributedString will fail.
        let url = try write("bad.rtf", content: Data("not rtf".utf8))
        XCTAssertThrowsError(try RichTextExtractor.extract(url))
    }

    // MARK: - Unknown extension throws

    func testUnknownExtensionThrows() throws {
        // .rtfx is not a known format
        let url = try write("a.rtfx", content: Data("whatever".utf8))
        XCTAssertThrowsError(try RichTextExtractor.extract(url))
    }
}
