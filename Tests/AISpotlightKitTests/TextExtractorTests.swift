import XCTest
@testable import AISpotlightKit

/// Tests for the text tokenizer + snippet extractor. Used by
/// ContentIndexer (3.1.3) to feed IndexStore (3.1.1) and by
/// ContentSearchProvider (3.1.4) to show context snippets in the UI.
final class TextExtractorTests: XCTestCase {

    // MARK: - Basic tokenization

    func testTokenizeSimpleEnglish() {
        let tokens = TextExtractor.tokenize("The quick brown fox")
        XCTAssertEqual(tokens.map(\.term), ["the", "quick", "brown", "fox"])
    }

    func testTokenizeDropsShortTokens() {
        // "a" (len 1) and "I" (len 1) are dropped. "an" (len 2) is kept.
        // 2-char tokens are valid (think "go", "AI").
        let tokens = TextExtractor.tokenize("a an the cat I")
        XCTAssertEqual(tokens.map(\.term), ["an", "the", "cat"])
    }

    func testTokenizeDropsVeryLongTokens() {
        let long = String(repeating: "a", count: 50)
        let tokens = TextExtractor.tokenize("normal \(long) end")
        XCTAssertEqual(tokens.map(\.term), ["normal", "end"])
    }

    func testTokenizeStripsPunctuation() {
        let tokens = TextExtractor.tokenize("hello, world! how are you?")
        XCTAssertEqual(tokens.map(\.term), ["hello", "world", "how", "are", "you"])
    }

    func testTokenizeEmptyString() {
        let tokens = TextExtractor.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testTokenizeOnlyPunctuation() {
        let tokens = TextExtractor.tokenize("!!! ??? --- ...")
        XCTAssertTrue(tokens.isEmpty)
    }

    // MARK: - Byte offsets

    func testTokenOffsetsAreAccurate() {
        let text = "hello world"
        let tokens = TextExtractor.tokenize(text)
        // Extract each token's slice from the original string
        for token in tokens {
            let start = text.utf8.index(text.utf8.startIndex, offsetBy: token.byteOffset)
            let end = text.utf8.index(start, offsetBy: token.byteLength)
            let slice = String(text.utf8[start..<end]) ?? ""
            XCTAssertEqual(slice, token.term, "Offset should reproduce the term text")
        }
    }

    // MARK: - CJK (Chinese/Japanese/Korean)

    func testTokenizeChineseText() {
        // CJK has no spaces. We split per character (a real Chinese
        // word-segmenter like jieba is a Phase 4 add-on, not Phase 3.1
        // MVP). Single CJK chars are kept unconditionally — they're
        // meaningful on their own.
        let tokens = TextExtractor.tokenize("聚酯化学笔记")
        XCTAssertEqual(Set(tokens.map(\.term)), Set(["聚", "酯", "学", "化", "笔", "记"]))
    }

    func testTokenizeMixedEnglishAndChinese() {
        // Input: 2 English ("polyester", "chemistry") + 4 CJK
        // ("聚", "酯", "化", "学") = 6 tokens.
        let tokens = TextExtractor.tokenize("polyester 聚酯 chemistry 化学")
        XCTAssertEqual(tokens.count, 6, "Expected 2 English + 4 CJK = 6 tokens")
        XCTAssertTrue(tokens.contains(where: { $0.term == "polyester" }))
        XCTAssertTrue(tokens.contains(where: { $0.term == "聚" }))
        XCTAssertTrue(tokens.contains(where: { $0.term == "酯" }))
        XCTAssertTrue(tokens.contains(where: { $0.term == "chemistry" }))
        XCTAssertTrue(tokens.contains(where: { $0.term == "化" }))
        XCTAssertTrue(tokens.contains(where: { $0.term == "学" }))
    }

    // MARK: - Snippet extraction

    func testSnippetCentersOnMatch() {
        let text = "The quick brown fox jumps over the lazy dog"
        let snippet = TextExtractor.snippet(around: "fox", in: text, radius: 10)
        XCTAssertTrue(snippet.contains("fox"), "Snippet must contain the match")
        XCTAssertTrue(snippet.contains("brown"), "Snippet should include context before")
        XCTAssertTrue(snippet.contains("jumps"), "Snippet should include context after")
    }

    func testSnippetClipsAtRadius() {
        let text = String(repeating: "x", count: 200) + "fox" + String(repeating: "y", count: 200)
        let snippet = TextExtractor.snippet(around: "fox", in: text, radius: 10)
        XCTAssertLessThan(snippet.count, 50, "Snippet should be clipped around the match")
        XCTAssertTrue(snippet.contains("fox"))
    }

    func testSnippetHandlesFirstMatch() {
        let text = "fox fox fox"
        let snippet = TextExtractor.snippet(around: "fox", in: text, radius: 5)
        XCTAssertTrue(snippet.contains("fox"))
    }

    func testSnippetEmptyForMissingMatch() {
        let text = "no match here"
        let snippet = TextExtractor.snippet(around: "absent", in: text, radius: 10)
        XCTAssertEqual(snippet, "")
    }

    func testSnippetEllipsizesTruncation() {
        let text = String(repeating: "a", count: 100) + "match" + String(repeating: "b", count: 100)
        let snippet = TextExtractor.snippet(around: "match", in: text, radius: 5)
        XCTAssertTrue(snippet.contains("…"), "Truncated snippet should have ellipsis")
    }

    // MARK: - Extension allow-list

    func testSupportedExtensionsIncludesCommon() {
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("md"))
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("txt"))
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("swift"))
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("py"))
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("json"))
    }

    func testSupportedExtensionsExcludesExecutables() {
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("app"))
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("dmg"))
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("exe"))
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("zip"))
    }

    func testIsSupportedAcceptsCaseInsensitive() {
        XCTAssertTrue(TextExtractor.isSupported(URL(fileURLWithPath: "/tmp/README.MD")))
        XCTAssertTrue(TextExtractor.isSupported(URL(fileURLWithPath: "/tmp/code.Swift")))
        XCTAssertTrue(TextExtractor.isSupported(URL(fileURLWithPath: "/tmp/no-extension")))
        XCTAssertFalse(TextExtractor.isSupported(URL(fileURLWithPath: "/tmp/binary.exe")))
    }

    // MARK: - File size limit

    func testMaxFileSizeIs5MB() {
        XCTAssertEqual(TextExtractor.maxFileSize, 5 * 1024 * 1024)
    }

    func testIsIndexableAcceptsSmallFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-\(UUID().uuidString).md")
        try Data(repeating: 0x20, count: 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Set up a real file URL with attributes
        let result = TextExtractor.isIndexable(url: url)
        XCTAssertTrue(result, "1KB .md file should be indexable")
    }

    func testIsIndexableRejectsOversizedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huge-\(UUID().uuidString).md")
        // Write 6MB of data (over the 5MB limit)
        try Data(repeating: 0x20, count: 6 * 1024 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = TextExtractor.isIndexable(url: url)
        XCTAssertFalse(result, "6MB file should be skipped (5MB limit)")
    }
}
