import Foundation
import AISpotlightKit

/// Builds an `AIProvider` from the user-configured provider name.
/// Returns nil for "none" so the QueryInterpreter falls back to rule-only.
enum AIFactory {
    static func makeProvider(named name: String, keychain: KeychainStoring) -> AIProvider? {
        switch name {
        case "openai": return OpenAIProvider(keychain: keychain)
        case "minimax": return MiniMaxProvider(keychain: keychain)
        default: return nil  // "none" or unknown → rule-based only
        }
    }
}
