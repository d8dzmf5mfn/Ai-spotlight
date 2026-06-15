import Foundation

/// One token in a text stream. `byteOffset` is the byte index of the
/// start of the term in the source string (UTF-8); `byteLength` is
/// the length in bytes. These let callers reconstruct the term
/// (e.g. for snippet extraction) without re-tokenizing.
public struct TokenSpan: Equatable, Sendable {
    public let term: String
    public let byteOffset: Int
    public let byteLength: Int
}

/// Text extraction utilities for the content index. Used by
/// `ContentIndexer` to feed `IndexStore`, and (later) by
/// `ContentSearchProvider` to show snippets in the result list.
///
/// All methods are pure functions on a `String` or `URL`. The
/// class has no state; it's a namespace of static helpers.
public enum TextExtractor {

    // MARK: - Configuration

    /// Files larger than this are skipped during indexing. PDFs and
    /// text files above 5 MB usually contain a lot of padding and
    /// are unlikely to be what the user is searching for.
    public static let maxFileSize: Int = 5 * 1024 * 1024

    /// Extensions the indexer should read. Compared lowercase; case in
    /// the URL doesn't matter. Files without an extension are still
    /// considered (some users have README, LICENSE, etc.).
    public static let supportedExtensions: Set<String> = [
        // Text
        "txt", "md", "markdown", "rst", "org", "log",
        // PDFs (extracted via PDFKit — see PDFTextExtractor.swift)
        "pdf",
        // Rich text (extracted via NSAttributedString — see
        // RichTextExtractor.swift)
        "rtf", "rtfd", "html", "htm",
        // NOTE: .docx is NOT supported by NSAttributedString's
        // .docFormat constant (it loads legacy .doc, not OOXML).
        // We omit it from the allow-list so the indexer skips these
        // files rather than silently failing.

        // Code (the long tail — anything we have an LSP server for, we
        // should index)
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp",
        "py", "pyi", "pyx",
        "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "go", "rs", "java", "kt", "kts", "scala", "groovy",
        "rb", "rake", "php", "pl", "pm",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "lua", "vim", "el", "clj", "cljs", "ex", "exs",
        "hs", "ml", "fs", "fsx", "r",
        // Data / config
        "json", "jsonc", "json5", "yaml", "yml", "toml",
        "xml", "plist",
        // Web
        "html", "htm", "css", "scss", "sass", "less",
        "vue", "svelte", "astro", "mdx",
        // Build / manifest (some — not all)
        "podspec", "gemspec", "cabal",
        // Config-ish
        "gitignore", "gitattributes", "editorconfig", "env", "ini",
        // Documentation
        "adoc", "asciidoc", "pod", "rdoc", "man",
    ]

    // MARK: - Tokenization

    /// Split `text` into a sequence of tokens. Rules:
    /// - Lowercased
    /// - Drops tokens shorter than 2 characters or longer than 40
    /// - Splits on whitespace and ASCII punctuation (but not on `_`)
    /// - **Each CJK ideograph is its own token** (Chinese/Japanese has
    ///   no whitespace, so word boundaries don't exist). CJK tokens
    ///   bypass the 2-char minimum because individual characters carry
    ///   meaning on their own.
    /// - The byte offset/length are computed in UTF-8.
    ///
    /// `text` is iterated as `unicodeScalars` so the offset arithmetic
    /// stays correct for multi-byte chars.
    public static func tokenize(_ text: String) -> [TokenSpan] {
        var out: [TokenSpan] = []
        var currentTerm = ""
        var currentStartUTF8Offset = 0  // offset in UTF-8 of `currentTerm` start
        var utf8Cursor = 0
        var charCursor = 0
        for scalar in text.unicodeScalars {
            let isCjk = isCJKScalar(scalar)
            let isSep = isSeparator(scalar)
            if isCjk {
                // Flush whatever word we were building
                if !currentTerm.isEmpty,
                   let span = span(term: currentTerm, start: currentStartUTF8Offset, end: utf8Cursor) {
                    out.append(span)
                    currentTerm = ""
                }
                // Emit the CJK char as its own token. We bypass
                // `span()` entirely because single-char CJK would
                // otherwise be filtered out by the len<2 check.
                out.append(TokenSpan(
                    term: String(scalar),
                    byteOffset: utf8Cursor,
                    byteLength: scalar.utf8.count
                ))
                utf8Cursor += scalar.utf8.count
                charCursor += 1
                continue
            }
            if isSep {
                if !currentTerm.isEmpty {
                    if let span = span(term: currentTerm, start: currentStartUTF8Offset, end: utf8Cursor) {
                        out.append(span)
                    }
                    currentTerm = ""
                }
            } else {
                if currentTerm.isEmpty {
                    currentStartUTF8Offset = utf8Cursor
                }
                currentTerm.unicodeScalars.append(scalar)
            }
            utf8Cursor += scalar.utf8.count
            charCursor += 1
        }
        // Trailing word
        if !currentTerm.isEmpty,
           let span = span(term: currentTerm, start: currentStartUTF8Offset, end: utf8Cursor) {
            out.append(span)
        }
        return out
    }

    /// Public for tests — also used by `snippet(around:in:radius:)`.
    /// Lowercases, applies the length filter. ASCII tokens shorter
    /// than 2 chars or longer than 40 chars are dropped (single-char
    /// CJK tokens bypass the length filter entirely — they are
    /// emitted in `tokenize` directly without going through this).
    private static func span(term: String, start: Int, end: Int) -> TokenSpan? {
        let cleaned = term.lowercased()
        let len = cleaned.count
        if len < 2 || len > 40 { return nil }
        return TokenSpan(term: cleaned, byteOffset: start, byteLength: end - start)
    }

    /// Is this scalar one of the CJK Unified Ideographs ranges (or
    /// Hiragana / Katakana / Hangul)? Single character check, not a
    /// full locale-aware segmentation — good enough for "find
    /// content within CJK files".
    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v)     // CJK Extension A
            || (0x4E00...0x9FFF).contains(v)     // CJK Unified
            || (0xF900...0xFAFF).contains(v)     // CJK Compatibility
            || (0x3040...0x309F).contains(v)     // Hiragana
            || (0x30A0...0x30FF).contains(v)     // Katakana
            || (0xAC00...0xD7AF).contains(v)     // Hangul Syllables
    }

    /// Whitespace, ASCII control, or common punctuation that
    /// separates words. Underscore is NOT a separator so identifiers
    /// like `foo_bar` tokenize as one word (when the indexer feeds
    /// code files).
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        // Common punctuation that breaks English words
        let v = scalar.value
        // ASCII punctuation range + a few extras
        return (0x21...0x2F).contains(v)   // !"#$%&'()*+,-./
            || (0x3A...0x40).contains(v)   // :;<=>?@
            || (0x5B...0x60).contains(v)   // [\]^_`
            || (0x7B...0x7E).contains(v)   // {|}~
            || scalar == "—" || scalar == "–" || scalar == "…" || scalar == "「" || scalar == "」"
    }

    // MARK: - Snippet

    /// Return a snippet of `text` centered on the first occurrence of
    /// `term` (case-insensitive). Up to `radius` characters on each
    /// side, joined with "…" when clipped. Empty string if `term` not
    /// found.
    public static func snippet(around term: String, in text: String, radius: Int = 80) -> String {
        guard !term.isEmpty, !text.isEmpty else { return "" }
        let lowerText = text.lowercased()
        let lowerTerm = term.lowercased()
        guard let range = lowerText.range(of: lowerTerm) else { return "" }
        // Convert character-distance to indices
        let startCharIdx = lowerText.distance(from: lowerText.startIndex,
                                              to: range.lowerBound)
        let endCharIdx = lowerText.distance(from: lowerText.startIndex,
                                            to: range.upperBound)
        let leftPad = max(0, startCharIdx - radius)
        let rightPad = max(0, text.count - endCharIdx - radius)
        let leftClip = leftPad > 0
        let rightClip = rightPad > 0
        // Index the original (un-lowercased) text
        let sc = text.startIndex
        let leftIdx = text.index(sc, offsetBy: leftPad)
        let rightIdx = text.index(sc, offsetBy: text.count - rightPad)
        let body = text[leftIdx..<rightIdx]
        var out = ""
        if leftClip { out += "…" }
        out += body
        if rightClip { out += "…" }
        return out
    }

    // MARK: - File-level helpers

    /// True if the URL's extension is one we should index.
    public static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            // Extensionless files (README, LICENSE) are still text.
            return true
        }
        return supportedExtensions.contains(ext)
    }

    /// True if the URL is small enough and has a supported extension.
    /// `false` is the indexer's signal to skip the file.
    public static func isIndexable(url: URL) -> Bool {
        guard isSupported(url) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxFileSize {
            return false
        }
        return true
    }
}
