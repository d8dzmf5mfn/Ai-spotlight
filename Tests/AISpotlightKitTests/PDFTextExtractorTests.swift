import XCTest
import PDFKit
import CoreText
import AppKit
@testable import AISpotlightKit

/// Tests for PDF text extraction. We use PDFKit to generate a tiny
/// test PDF in `setUp` rather than bundling a fixture — bundling
/// binary blobs in SPM is awkward and a hand-crafted PDF can drift
/// out of sync with what the test expects.
final class PDFTextExtractorTests: XCTestCase {

    private var pdfURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextExtractorTests-\(UUID().uuidString).pdf")
        try Self.writeSamplePDF(to: tmp)
        pdfURL = tmp
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: pdfURL)
        try await super.tearDown()
    }

    /// Write a 1-page PDF containing a known string. Uses PDFKit so
    /// the file is always valid (we don't ship a hand-crafted .pdf
    /// fixture).
    ///
    /// **Why this is non-trivial:** `PDFKit.PDFDocument.string` extracts
    /// only the **text stream** of a PDF, not annotations. So we
    /// have to draw text into the page's content stream. The cleanest
    /// way is to use Core Graphics to write a text string into the
    /// PDF context, then read it back with PDFKit.
    private static func writeSamplePDF(to url: URL) throws {
        // 1. Use CGPDFContext to write a PDF with embedded text.
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFTextExtractorTests", code: 1)
        }
        context.beginPDFPage(nil)
        // Draw a string using Core Text. The text is embedded in the
        // page's content stream as a Tj operator, which is what
        // `PDFDocument.string` reads.
        let text = "polyester chemistry notes" as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let attrString = NSAttributedString(string: text as String, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 50, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - Extraction

    func testExtractsTextFromAnnotation() throws {
        let text = try PDFTextExtractor.extract(pdfURL)
        XCTAssertTrue(text.contains("polyester"),
                      "Should extract the annotation text. Got: \(text)")
        XCTAssertTrue(text.contains("chemistry"))
    }

    func testExtractsLowercasedByDefault() throws {
        let text = try PDFTextExtractor.extract(pdfURL)
        XCTAssertEqual(text, text.lowercased(),
                       "PDFTextExtractor returns lowercased text for downstream tokenize()")
    }

    func testEmptyPDFReturnsEmptyString() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextExtractorTests-empty-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 1-page PDF with no text.
        let emptyPage = PDFPage()
        emptyPage.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        let emptyDoc = PDFDocument()
        emptyDoc.insert(emptyPage, at: 0)
        guard emptyDoc.write(to: tmp) else {
            throw NSError(domain: "PDFTextExtractorTests", code: 2)
        }
        let text = try PDFTextExtractor.extract(tmp)
        XCTAssertEqual(text, "", "Empty PDF should return empty string")
    }

    func testMissingFileThrows() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextExtractorTests-missing-\(UUID().uuidString).pdf")
        // Don't create the file.
        XCTAssertThrowsError(try PDFTextExtractor.extract(bogus)) { error in
            // PDFKit returns nil PDFDocument, which we convert to a
            // thrown error. We don't assert the specific error type —
            // just that it throws.
            XCTAssertNotNil(error)
        }
    }
}
