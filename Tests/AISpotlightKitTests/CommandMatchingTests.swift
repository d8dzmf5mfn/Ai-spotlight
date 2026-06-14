import XCTest
@testable import AISpotlightKit

/// Tests for the built-in command matcher. Lives in the Kit so it can be
/// unit-tested without pulling in AppKit.
final class CommandMatchingTests: XCTestCase {
    // MARK: - Exact match

    func testExactEnglishSettings() {
        XCTAssertEqual(CommandMatcher.match("settings"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("preferences"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("prefs"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("config"), .openSettings)
    }

    func testExactChineseSettings() {
        XCTAssertEqual(CommandMatcher.match("设置"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("首选项"), .openSettings)
    }

    func testExactQuit() {
        XCTAssertEqual(CommandMatcher.match("quit"), .quit)
        XCTAssertEqual(CommandMatcher.match("exit"), .quit)
        XCTAssertEqual(CommandMatcher.match("退出"), .quit)
    }

    // MARK: - Prefix match (Spotlight-like)

    func testPrefixMatch() {
        // 'set' is a prefix of 'settings' — should still match
        XCTAssertEqual(CommandMatcher.match("set"), .openSettings)
        // 'pref' is a prefix of 'preferences' — should still match
        XCTAssertEqual(CommandMatcher.match("pref"), .openSettings)
        // 'qui' is a prefix of 'quit' — should still match
        XCTAssertEqual(CommandMatcher.match("qui"), .quit)
    }

    func testPrefixMatchCaseInsensitive() {
        XCTAssertEqual(CommandMatcher.match("SET"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("Settings"), .openSettings)
    }

    func testWhitespaceTrimming() {
        XCTAssertEqual(CommandMatcher.match("  settings  "), .openSettings)
        XCTAssertEqual(CommandMatcher.match("\tsettings\n"), .openSettings)
        XCTAssertEqual(CommandMatcher.match("  set  "), .openSettings)
    }

    // MARK: - Negative cases

    func testNonCommandsReturnNil() {
        XCTAssertNil(CommandMatcher.match("find report"))
        XCTAssertNil(CommandMatcher.match("open Safari"))
        XCTAssertNil(CommandMatcher.match(""))
        XCTAssertNil(CommandMatcher.match("z"))
        // 'quit' is a prefix of 'quitely' — that's intentional (user types
        // 'quit' first, then might type more before triggering; we treat
        // the partial input as the command).
        // To get a true negative we'd need a string that doesn't have any
        // recognized prefix in either direction.
        XCTAssertNil(CommandMatcher.match("x"))
        XCTAssertNil(CommandMatcher.match("zzz"))
    }
}
