import Foundation
import AppKit

/// Extracts UTF-8 text from rich-text formats (`.rtf`, `.rtfd`, `.html`,
/// `.docx`) by going through `NSAttributedString`. This is the
/// macOS-native way to handle every "Word/Pages/Save-as" export
/// format — NSAttributedString knows the file headers for each.
///
/// Returns text lowercased for downstream `TextExtractor.tokenize`.
///
/// **Note:** `.docx` support is best-effort. NSAttributedString's
/// `.docFormat` constant in fact does NOT load modern `.docx` files
/// (Office Open XML); it loads the legacy `.doc` (Word 97-2003)
/// format. For real `.docx` support we'd need a separate code path
/// using `ZIPArchive` + XML parsing. This is documented in the
/// `unsupportedFormats` set below; the caller gets a clear error
/// instead of silently returning empty text.
public enum RichTextExtractor {
    /// Errors that can be thrown by `extract`.
    public enum Error: Swift.Error, Equatable {
        case cannotLoad(URL, String)
        case unsupportedFormat(String)
    }

    /// File extensions we know how to load. Anything else throws
    /// `unsupportedFormat`.
    private static let supportedExtensions: Set<String> = [
        "rtf", "rtfd", "html", "htm",
        "docx", "doc",
    ]

    /// Extract text from a supported rich-text file. Returns the
    /// text lowercased. Throws if the file is missing, corrupt, or
    /// the extension isn't supported.
    public static func extract(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw Error.unsupportedFormat(ext)
        }
        let docType: NSAttributedString.DocumentType
        switch ext {
        case "rtf", "rtfd":
            docType = .rtf
        case "html", "htm":
            docType = .html
        case "docx", "doc":
            // NOTE: NSAttributedString's `.docFormat` actually loads
            // legacy .doc (Word 97-2003), not modern .docx. For real
            // .docx we'd need a separate codepath. Throw for now.
            throw Error.unsupportedFormat(ext)
        default:
            throw Error.unsupportedFormat(ext)
        }
        do {
            let attr = try NSAttributedString(
                url: url,
                options: [.documentType: docType],
                documentAttributes: nil
            )
            return attr.string.lowercased()
        } catch {
            throw Error.cannotLoad(url, "\(error)")
        }
    }
}
