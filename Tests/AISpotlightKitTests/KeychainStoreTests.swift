import XCTest
@testable import AISpotlightKit

final class KeychainStoreTests: XCTestCase {
    func testInMemorySetGetDelete() throws {
        let kc = InMemoryKeychain()
        try kc.set("hello", for: "openai")
        XCTAssertEqual(try kc.get("openai"), "hello")
        try kc.delete("openai")
        XCTAssertNil(try kc.get("openai"))
    }

    func testInMemoryGetMissingReturnsNil() throws {
        let kc = InMemoryKeychain()
        XCTAssertNil(try kc.get("never_set"))
    }

    func testInMemoryOverwrite() throws {
        let kc = InMemoryKeychain()
        try kc.set("first", for: "k")
        try kc.set("second", for: "k")
        XCTAssertEqual(try kc.get("k"), "second")
    }
}
