import Foundation

/// Concrete endpoint configuration. Built by `SettingsStore.resolveConfig()`
/// from user settings. The `OpenAICompatibleProvider` consumes this struct.
///
/// Note: lives in the Kit (not the App) so unit tests can construct
/// instances without pulling in AppKit.
public struct AIConfig: Equatable, Sendable {
    public let displayName: String
    public let baseURL: URL
    public let model: String
    /// `nil` for providers that don't require auth (Ollama, local).
    public let apiKey: String?

    public init(displayName: String, baseURL: URL, model: String, apiKey: String?) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}
