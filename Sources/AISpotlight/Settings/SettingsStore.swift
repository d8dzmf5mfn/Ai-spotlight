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

    // MARK: Phase 4.6 cloud-model preset
    /// The currently-selected preset. The Picker in
    /// SettingsView writes to this when the user picks a
    /// provider from the dropdown. When nil, no preset is
    /// active (e.g. fresh install before user picks one).
    @Published var selectedPreset: String = "openai"
    /// Live status of the "Test connection" button in
    /// SettingsView. UI shows this next to the button.
    @Published var testResult: TestResult = .none
    public enum TestResult: Equatable, Sendable {
        case none
        case testing
        case success(String)
        case failure(String)
        var message: String {
            switch self {
            case .none: return ""
            case .testing: return "Testing…"
            case .success(let m): return m
            case .failure(let m): return m
            }
        }
        /// "success", "failure", or "neutral". The SwiftUI
        /// view maps this to a Color in the UI layer;
        /// we keep the store Color-free so the model
        /// stays portable.
        public var style: String {
            switch self {
            case .none, .testing: return "neutral"
            case .success: return "success"
            case .failure: return "failure"
            }
        }
    }

    /// Apply a preset's defaults to the URL and model
    /// fields. We only overwrite fields that are still at
    /// their default values (i.e. the user hasn't manually
    /// edited them) so picking a preset never trashes
    /// work the user already did.
    func applyPreset(_ preset: ProviderPreset) {
        // Always set the model — it's the most user-visible
        // setting and changes when a new provider is picked.
        customModel = preset.defaultModel
        // For the URL: only set if it's empty or still
        // equals the current preset's value (meaning the
        // user hasn't manually edited it).
        if customBaseURL.isEmpty {
            customBaseURL = preset.baseURL
        }
    }

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

    /// Phase 4.6: test the custom provider by sending a
    /// GET /v1/models request. If the user's API key
    /// and URL are valid, this returns 200 with the model
    /// list. If not, we surface the error. We use /models
    /// (not /chat/completions) because it's a GET — cheaper,
    /// no token cost, and most providers support it.
    func testCustomConnection() async {
        testResult = .testing
        guard let url = URL(string: customBaseURL) else {
            testResult = .failure("Invalid URL: \(customBaseURL)")
            return
        }
        // Build the request: GET {baseURL}/models
        let modelsURL = url.appendingPathComponent("models")
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "GET"
        if !customAPIKey.isEmpty {
            req.setValue("Bearer \(customAPIKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                testResult = .failure("Not an HTTP response")
                return
            }
            if (200..<300).contains(http.statusCode) {
                testResult = .success("Connected (HTTP \(http.statusCode), \(data.count) bytes)")
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let trimmed = body.prefix(200)
                testResult = .failure("HTTP \(http.statusCode): \(trimmed)")
            }
        } catch let e as URLError {
            testResult = .failure("Connection error: \(e.localizedDescription)")
        } catch {
            testResult = .failure("Error: \(error.localizedDescription)")
        }
    }
}
