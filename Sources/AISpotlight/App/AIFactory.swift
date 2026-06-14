import Foundation
import AISpotlightKit

/// Builds an `AIProvider` from an `AIConfig`. The config is built by
/// `SettingsStore.resolveConfig()` from user settings — `nil` means
/// "no AI", and the caller should fall back to rule-based parsing.
enum AIFactory {
    static func makeProvider(from config: AIConfig?) -> AIProvider? {
        guard let config else { return nil }
        return OpenAICompatibleProvider(config: config)
    }
}
