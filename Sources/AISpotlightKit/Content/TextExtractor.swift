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
public enum TextExtractor {

    // MARK: - Configuration

    /// Files larger than this are skipped during indexing. PDFs and
    /// text files above 5 MB usually contain a lot of padding and
    /// are unlikely to be what the user is searching for.
    public static let maxFileSize: Int = 5 * 1024 * 1024

    /// Categorize an extension for the configurable allow-list
    /// (Phase 3.2.2). The user can toggle each category in Settings.
    public enum Category: String, CaseIterable, Sendable {
        case text, code, richText, pdf

        /// Extensions that belong to this category. Note: a single
        /// extension (e.g. `html`) can be in only one category for
        /// the allow-list purposes; we put web-y formats in `.richText`
        /// since the indexer routes them to NSAttributedString.
        public var extensions: Set<String> {
            switch self {
            case .text:
                return ["txt", "md", "markdown", "rst", "org", "log",
                        "json", "jsonc", "yaml", "yml", "toml",
                        "xml", "plist", "ini", "env"]
            case .code:
                return ["swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp",
                        "py", "pyi", "pyx", "js", "jsx", "ts", "tsx", "mjs", "cjs",
                        "go", "rs", "java", "kt", "kts", "scala", "groovy",
                        "rb", "rake", "php", "pl", "pm", "sh", "bash", "zsh",
                        "fish", "ps1", "bat", "cmd", "lua", "vim", "el",
                        "clj", "cljs", "ex", "exs", "hs", "ml", "fs", "fsx", "r",
                        "css", "scss", "sass", "less", "vue", "svelte", "astro",
                        "mdx", "gitignore", "gitattributes", "editorconfig",
                        "podspec", "gemspec", "cabal", "adoc", "asciidoc",
                        "pod", "rdoc", "man"]
            case .richText:
                return ["rtf", "rtfd", "html", "htm"]
            case .pdf:
                return ["pdf"]
            }
        }

        /// Human-readable label for the Settings UI toggle.
        public var displayName: String {
            switch self {
            case .text: return "Text & data files"
            case .code: return "Source code files"
            case .richText: return "Rich text & HTML"
            case .pdf: return "PDFs"
            }
        }
    }

    /// The flat set of all extensions across all categories. Kept
    /// for callers that don't care about the per-category split
    /// (e.g. tests, the indexer fall-through case).
    public static var supportedExtensions: Set<String> {
        var out: Set<String> = []
        for cat in Category.allCases { out.formUnion(cat.extensions) }
        return out
    }

    /// Compute the set of extensions to index given the user's
    /// category toggles. Used by the indexer to filter what it
    /// walks + ingests.
    public static func filteredExtensions(
        for enabledCategories: Set<Category>
    ) -> Set<String> {
        var out: Set<String> = []
        for cat in enabledCategories {
            out.formUnion(cat.extensions)
        }
        return out
    }

    /// True if the URL's extension belongs to ANY of the enabled
    /// categories. The `enabledCategories` set should come from
    /// `SettingsStore`.
    public static func isSupported(
        _ url: URL,
        enabledCategories: Set<Category>
    ) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return true
        }
        for cat in enabledCategories where cat.extensions.contains(ext) {
            return true
        }
        return false
    }

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
    public static func tokenize(_ text: String) -> [TokenSpan] {
        var out: [TokenSpan] = []
        var currentTerm = ""
        var currentStartUTF8Offset = 0
        var utf8Cursor = 0
        var charCursor = 0
        for scalar in text.unicodeScalars {
            let isCjk = isCJKScalar(scalar)
            let isSep = isSeparator(scalar)
            if isCjk {
                if !currentTerm.isEmpty,
                   let span = span(term: currentTerm, start: currentStartUTF8Offset, end: utf8Cursor) {
                    out.append(span)
                    currentTerm = ""
                }
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
        if !currentTerm.isEmpty,
           let span = span(term: currentTerm, start: currentStartUTF8Offset, end: utf8Cursor) {
            out.append(span)
        }
        return out
    }

    private static func span(term: String, start: Int, end: Int) -> TokenSpan? {
        let cleaned = term.lowercased()
        let len = cleaned.count
        if len < 2 || len > 40 { return nil }
        return TokenSpan(term: cleaned, byteOffset: start, byteLength: end - start)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        let v = scalar.value
        return (0x21...0x2F).contains(v)
            || (0x3A...0x40).contains(v)
            || (0x5B...0x60).contains(v)
            || (0x7B...0x7E).contains(v)
            || scalar == "—" || scalar == "–" || scalar == "…" || scalar == "「" || scalar == "」"
    }

    // MARK: - Snippet

    public static func snippet(around term: String, in text: String, radius: Int = 80) -> String {
        guard !term.isEmpty, !text.isEmpty else { return "" }
        let lowerText = text.lowercased()
        let lowerTerm = term.lowercased()
        guard let range = lowerText.range(of: lowerTerm) else { return "" }
        let startCharIdx = lowerText.distance(from: lowerText.startIndex,
                                              to: range.lowerBound)
        let endCharIdx = lowerText.distance(from: lowerText.startIndex,
                                            to: range.upperBound)
        let leftPad = max(0, startCharIdx - radius)
        let rightPad = max(0, text.count - endCharIdx - radius)
        let leftClip = leftPad > 0
        let rightClip = rightPad > 0
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

    // MARK: - File-level helpers (no settings — assume all categories on)

    /// True if the URL's extension is one we should index.
    public static func isSupported(_ url: URL) -> Bool {
        isSupported(url, enabledCategories: Set(Category.allCases))
    }

    /// True if the URL is small enough and has a supported extension.
    public static func isIndexable(url: URL) -> Bool {
        guard isSupported(url) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxFileSize {
            return false
        }
        return true
    }
}
