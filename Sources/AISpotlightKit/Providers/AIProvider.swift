import Foundation

public protocol AIProvider: Sendable {
    var name: String { get }
    func classify(_ query: String) async throws -> Intent
}

public enum AIProviderError: Error, LocalizedError {
    case missingAPIKey
    case badResponse(Int)
    case decodeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing API key in Keychain"
        case .badResponse(let code): return "HTTP \(code)"
        case .decodeFailure(let body): return "Could not decode response: \(body.prefix(200))"
        }
    }
}
