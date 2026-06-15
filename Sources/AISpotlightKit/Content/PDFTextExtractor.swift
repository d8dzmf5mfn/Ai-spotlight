import Foundation
import PDFKit

/// Extracts UTF-8 text from a `.pdf` file using PDFKit. Returns the
/// text lowercased (so the downstream `TextExtractor.tokenize` can
/// match it as expected without an extra normalization pass).
///
/// `PDFDocument(url:)` is the modern PDFKit entry point. It throws
/// nothing on failure — it returns `nil`. We convert that to a
/// thrown `CocoaError` so the indexer can decide whether to skip
/// the file or surface the error to the user.
///
/// **Note:** This is the **only** way Phase 3.1's `ContentIndexer`
/// needs to read a PDF. We could also implement RTF/DOCX/HTML
/// extraction via NSAttributedString (Task 3.2.1) — for now PDF
/// alone unblocks the most common use case (academic notes,
/// downloaded research papers).
public enum PDFTextExtractor {
    /// Errors that can be thrown by `extract`.
    public enum Error: Swift.Error, Equatable {
        /// `PDFDocument(url:)` returned `nil`. The file may not
        /// exist, may be corrupt, or may be encrypted.
        case cannotOpen(URL)
    }

    /// Read the PDF at `url` and return its extracted text,
    /// lowercased. Returns "" if the PDF opens but has no text.
    /// Throws `.cannotOpen` if the file cannot be opened.
    public static func extract(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw Error.cannotOpen(url)
        }
        let raw = doc.string ?? ""
        return raw.lowercased()
    }
}
