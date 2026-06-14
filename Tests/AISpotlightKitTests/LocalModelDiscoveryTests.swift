import XCTest
@testable import AISpotlightKit

/// Mock implementation of `LocalModelDiscovering` for unit tests. Uses a
/// closure so each test can supply its own canned response.
final class MockDiscovery: LocalModelDiscovering, @unchecked Sendable {
    enum Result {
        case success([String])
        case failure(Error)
    }

    private let resultForEndpoint: (URL) -> Result
    private(set) var callCount: Int = 0
    private(set) var calledWithEndpoints: [URL] = []

    init(resultForEndpoint: @escaping (URL) -> Result) {
        self.resultForEndpoint = resultForEndpoint
    }

    convenience init(models: [String]) {
        self.init(resultForEndpoint: { _ in .success(models) })
    }

    func availableModels(at endpoint: URL) async throws -> [String] {
        callCount += 1
        calledWithEndpoints.append(endpoint)
        switch resultForEndpoint(endpoint) {
        case .success(let names): return names
        case .failure(let err):  throw err
        }
    }
}

final class LocalModelDiscoveryTests: XCTestCase {
    func testSuccessReturnsModelList() async throws {
        let mock = MockDiscovery(models: ["gemma2:2b", "llama3:8b", "qwen2.5:7b"])
        let models = try await mock.availableModels(at: URL(string: "http://localhost:11434")!)
        XCTAssertEqual(models, ["gemma2:2b", "llama3:8b", "qwen2.5:7b"])
    }

    func testEmptyListWhenNoModelsInstalled() async throws {
        let mock = MockDiscovery(models: [])
        let models = try await mock.availableModels(at: URL(string: "http://localhost:11434")!)
        XCTAssertEqual(models, [])
    }

    func testFailurePropagates() async {
        let mock = MockDiscovery(resultForEndpoint: { _ in .failure(DiscoveryError.unreachable("connection refused")) })
        do {
            _ = try await mock.availableModels(at: URL(string: "http://localhost:11434")!)
            XCTFail("Expected throw")
        } catch let e as DiscoveryError {
            if case .unreachable = e { } else { XCTFail("Wrong error case: \(e)") }
        } catch { XCTFail("Wrong error type: \(error)") }
    }

    func testMockRecordsCalls() async throws {
        let mock = MockDiscovery(models: ["a"])
        let url1 = URL(string: "http://localhost:11434")!
        let url2 = URL(string: "http://192.168.1.5:11434")!
        _ = try await mock.availableModels(at: url1)
        _ = try await mock.availableModels(at: url2)
        XCTAssertEqual(mock.callCount, 2)
        XCTAssertEqual(mock.calledWithEndpoints, [url1, url2])
    }
}
