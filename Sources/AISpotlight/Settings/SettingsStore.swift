import Foundation
import AppKit
import AISpotlightKit

/// User-configurable settings. Three things can be configured:
///   1. The AI provider (none / ollama / custom)
///   2. For custom: base URL, model name, API key
///   3. The global hotkey (handled separately by KeyboardShortcuts.Recorder)
///
/// API key is stored in Keychain; everything else in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    /// String keys are constant for the lifetime of the process — pull
    /// them out so the @Published didSet handlers can use them without
    /// re-creating the literal each time.
    private static let kProvider  = "activeAIProvider"
    private static let kBaseURL  = "customBaseURL"
    private static let kModel     = "customModel"
    private static let kOllama    = "ollamaModel"
    private static let kKeychain  = "custom_api_key"
    let keychain: KeychainStoring

    // MARK: AI provider
    @Published var activeProvider: String {
        didSet { defaults.set(activeProvider, forKey: Self.kProvider) }
    }
    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: Self.kBaseURL) }
    }
    @Published var customModel: String {
        didSet { defaults.set(customModel, forKey: Self.kModel) }
    }
    @Published var customAPIKey: String = ""

    // MARK: Ollama-specific (shared defaults with custom; user can override)
    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Self.kOllama) }
    }

    // MARK: Index allow-list (Phase 3.2.2)
    /// Whether to index source code files. Privacy-sensitive users
    /// turn this off; the rest leave it on (the default).
    @Published var indexCodeFiles: Bool {
        didSet { defaults.set(indexCodeFiles, forKey: Self.kIndexCode) }
    }
    /// Whether to index rich-text files (.rtf, .rtfd, .html, .htm).
    @Published var indexRichTextFiles: Bool {
        didSet { defaults.set(indexRichTextFiles, forKey: Self.kIndexRich) }
    }

    init(keychain: KeychainStoring = KeychainStore()) {
        self.keychain = keychain
        // user decision: open-box, no key needed by default
        self.activeProvider = defaults.string(forKey: Self.kProvider) ?? "none"
        self.customBaseURL  = defaults.string(forKey: Self.kBaseURL)  ?? "https://api.openai.com/v1"
        self.customModel     = defaults.string(forKey: Self.kModel)     ?? "gpt-4o-mini"
        self.ollamaModel     = defaults.string(forKey: Self.kOllama)    ?? "gemma2:2b"
        self.customAPIKey    = (try? keychain.get(Self.kKeychain)) ?? ""
        // Default both ON — zero-friction: the user opts out.
        self.indexCodeFiles = defaults.object(forKey: Self.kIndexCode) as? Bool ?? true
        self.indexRichTextFiles = defaults.object(forKey: Self.kIndexRich) as? Bool ?? true
    }

    private static let kIndexCode = "indexCodeFiles"
    private static let kIndexRich = "indexRichTextFiles"

    func saveKeys() {
        if !customAPIKey.isEmpty {
            try? keychain.set(customAPIKey, for: Self.kKeychain)
        }
    }

    /// Resolve the active configuration into a concrete `AIConfig` value that
    /// the AIFactory can consume. `none` → nil (caller falls back to rules).
    func resolveConfig() -> AIConfig? {
        switch activeProvider {
        case "none":
            return nil
        case "ollama":
            return AIConfig(
                displayName: "Ollama",
                baseURL: URL(string: "http://localhost:11434/v1")!,
                model: ollamaModel,
                apiKey: nil
            )
        case "custom":
            guard let url = URL(string: customBaseURL), !customModel.isEmpty else {
                return nil
            }
            return AIConfig(
                displayName: "Custom",
                baseURL: url,
                model: customModel,
                apiKey: customAPIKey.isEmpty ? nil : customAPIKey
            )
        default:
            return nil
        }
    }
}
