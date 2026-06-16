import XCTest
@testable import AISpotlightKit

/// Tests for the Phase 4.3 built-in tools. Each test calls
/// a real macOS command (`mdfind`, `open`, `ls`) so these
/// are integration tests rather than pure unit tests.
final class BuiltinToolsTests: XCTestCase {

    func testListAppsReturnsMultipleApps() async throws {
        // The /Applications directory typically has 20+
        // apps installed. We just verify that the list is
        // non-empty and sorted. We don't hardcode Safari
        // because some users (this one) have hundreds of
        // apps and the top-N may or may not include it.
        let tool = BuiltinTools.listApps()
        let result = try await tool.handler(["scope": "system"])
        guard case .array(let arr) = result.payload["apps"] else {
            XCTFail("Expected .array payload for apps key")
            return
        }
        let names = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        XCTAssertGreaterThan(names.count, 0, "Expected at least one app in /Applications")
        // Sorted alphabetically
        XCTAssertEqual(names, names.sorted(), "Apps should be sorted")
    }

    func testListAppsScopeUser() async throws {
        // The user scope returns ~/Applications which may be
        // empty. Just verify the scope filter works (it
        // doesn't crash and returns valid data).
        let tool = BuiltinTools.listApps()
        let result = try await tool.handler(["scope": "user"])
        guard case .int(let count) = result.payload["count"] else {
            XCTFail("Expected .int count")
            return
        }
        XCTAssertGreaterThanOrEqual(count, 0)
    }

    func testListAppsBadScopeThrows() async throws {
        let tool = BuiltinTools.listApps()
        do {
            _ = try await tool.handler(["scope": "bogus"])
            XCTFail("Expected badArgs error for bogus scope")
        } catch let e as ToolError {
            if case .badArgs = e { /* expected */ }
            else { XCTFail("Expected badArgs, got: \(e)") }
        }
    }

    func testSearchFilesEmptyQueryThrows() async throws {
        let tool = BuiltinTools.searchFiles()
        do {
            _ = try await tool.handler(["query": ""])
            XCTFail("Expected badArgs error for empty query")
        } catch let e as ToolError {
            if case .badArgs = e { /* expected */ }
            else { XCTFail("Expected badArgs, got: \(e)") }
        }
    }

    func testSearchFilesMissingQueryThrows() async throws {
        let tool = BuiltinTools.searchFiles()
        do {
            _ = try await tool.handler([:])
            XCTFail("Expected badArgs error for missing query")
        } catch let e as ToolError {
            if case .badArgs = e { /* expected */ }
            else { XCTFail("Expected badArgs, got: \(e)") }
        }
    }

    func testOpenFileNonexistentThrows() async throws {
        let tool = BuiltinTools.openFile()
        do {
            _ = try await tool.handler(["path": "/tmp/definitely_does_not_exist_12345.xyz"])
            XCTFail("Expected runtimeError for nonexistent file")
        } catch let e as ToolError {
            if case .runtimeError = e { /* expected */ }
            else { XCTFail("Expected runtimeError, got: \(e)") }
        }
    }

    // MARK: - Registry

    func testRegistryRegistersAndRetrieves() async {
        let registry = LLMToolRegistry()
        let tool = BuiltinTools.searchFiles()
        await registry.register(tool)
        let retrieved = await registry.get("search_files")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "search_files")
    }

    func testRegistryUnregister() async {
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())
        await registry.unregister("search_files")
        let retrieved = await registry.get("search_files")
        XCTAssertNil(retrieved)
    }

    func testRegistryAllToolsSorted() async {
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.openFile())
        await registry.register(BuiltinTools.searchFiles())
        await registry.register(BuiltinTools.listApps())
        let all = await registry.allTools()
        XCTAssertEqual(all.count, 3)
        // Sorted alphabetically: list_apps, open_file, search_files
        XCTAssertEqual(all.map { $0.name }, ["list_apps", "open_file", "search_files"])
    }

    func testToolsForPromptEmpty() async {
        let registry = LLMToolRegistry()
        let prompt = await registry.toolsForPrompt()
        XCTAssertEqual(prompt, "")
    }

    func testToolsForPromptNonEmpty() async {
        let registry = LLMToolRegistry()
        await registry.register(BuiltinTools.searchFiles())
        let prompt = await registry.toolsForPrompt()
        XCTAssertTrue(prompt.contains("search_files"))
        XCTAssertTrue(prompt.contains("JSON"))
        XCTAssertTrue(prompt.contains("tool"))
    }

    /// Phase 5-H: read_file reads a known file's content.
    func testReadFileReads() async throws {
        // Create a temp file with known content.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aispotlight-readtest-\(UUID().uuidString).md")
        try "Hello, AI Spotlight from read_file!".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tool = BuiltinTools.readFile()
        let result = try await tool.handler(["path": tmp.path as Any])
        // Find the "content" payload key.
        guard let contentVal = result.payload["content"] else {
            XCTFail("read_file should return a content payload key")
            return
        }
        guard case .string(let text) = contentVal else {
            XCTFail("read_file should return a string content payload, got: \(contentVal)")
            return
        }
        XCTAssertTrue(text.contains("Hello, AI Spotlight"))
    }

    func testReadFileMissingPathThrows() async {
        let tool = BuiltinTools.readFile()
        do {
            _ = try await tool.handler([:])
            XCTFail("expected badArgs")
        } catch {
            // expected
        }
    }

    func testReadFileNonexistentThrows() async {
        let tool = BuiltinTools.readFile()
        do {
            _ = try await tool.handler(["path": "/nonexistent/path/12345.md" as Any])
            XCTFail("expected runtimeError")
        } catch {
            // expected
        }
    }

    func testReadFileRequiresConsent() {
        let tool = BuiltinTools.readFile()
        XCTAssertTrue(tool.requiresConsent, "read_file should require consent")
    }

    func testClipboardGetRequiresNoConsent() {
        let tool = BuiltinTools.clipboardGet()
        XCTAssertFalse(tool.requiresConsent, "clipboard_get should NOT require consent")
    }

    func testClipboardSetRequiresConsent() {
        let tool = BuiltinTools.clipboardSet()
        XCTAssertTrue(tool.requiresConsent, "clipboard_set should require consent")
    }

}
