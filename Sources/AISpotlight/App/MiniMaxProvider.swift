import Foundation
import AISpotlightKit

/// Placeholder for the MiniMax provider. Phase 1 ships this as a stub that
/// always returns `missingAPIKey`, which QueryInterpreter catches and falls
/// back to rule-based. The real endpoint + JSON contract land in Phase 2
/// (when we have time to verify against current API docs and write tests).
actor MiniMaxProvider: AIProvider {
    nonisolated let name = "MiniMax"
    private let keychain: KeychainStoring

    init(keychain: KeychainStoring) { self.keychain = keychain }

    func classify(_ query: String) async throws -> Intent {
        throw AIProviderError.missingAPIKey
    }
}
