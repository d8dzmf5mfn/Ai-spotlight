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

    // MARK: Phase 5-B model discovery
    /// The list of models the user can pick from. Populated
    /// by `ModelDiscoveryService.refresh(...)`. Empty until
    /// the user clicks "Refresh models" or the picker is
    /// opened for the first time.
    @Published var discoveredModels: [String] = []
    /// True while a discovery HTTP call is in flight.
    @Published var isDiscoveringModels: Bool = false
    /// When the last discovery call completed. Shown in
    /// the UI as "Last refresh: 2 min ago".
    @Published var lastModelRefresh: Date? = nil
    /// Error from the last discovery call, if any.
    @Published var modelDiscoveryError: String? = nil

    /// Run a model discovery. Safe to call concurrently —
    /// the service is an actor.
    func refreshModels() async {
        guard let descriptor = await ProviderRegistry.shared.descriptor(for: selectedPreset) else {
            modelDiscoveryError = "Unknown provider: \(selectedPreset)"
            return
        }
        isDiscoveringModels = true
        modelDiscoveryError = nil
        defer { isDiscoveringModels = false }
        let service = ModelDiscoveryService()
        // Build the baseURL: descriptor's default + user's override.
        let baseURL = customBaseURL.isEmpty ? descriptor.defaultBaseURL : customBaseURL
        do {
            // Anthropic + others with staticCatalog have no
            // network call — the discovery service just
            // returns the static list. That's still useful
            // because it sets lastModelRefresh and clears
            // the error.
            let models = try await service.refresh(
                descriptor: descriptor,
                baseURL: baseURL,
                apiKey: customAPIKey
            )
            discoveredModels = models
            lastModelRefresh = Date()
        } catch let e as DiscoveryError {
            modelDiscoveryError = e.errorDescription
        } catch {
            modelDiscoveryError = error.localizedDescription
        }
    }

    /// True if the user has typed a custom model name not
    /// in the discovered list. The Picker shows a
    /// "Type manually..." row that toggles this.
    @Published var useManualModel: Bool = false
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
            customBaseURL = preset.defaultBaseURL
        }
        // Phase 5-B: trigger a model discovery so the
        // Picker populates immediately. The user can also
        // click "Refresh" to re-fetch on demand.
        useManualModel = false
        discoveredModels = []
        lastModelRefresh = nil
        modelDiscoveryError = nil
        Task { await refreshModels() }
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

    /// Phase 4.6.2: test the Ollama connection by sending
    /// a GET to `http://localhost:11434/api/tags`. This is
    /// Ollama's actual health-check endpoint (not /v1/models,
    /// which Ollama does not implement). Returns the count
    /// of loaded models on success. We don't require the
    /// user's ollamaModel setting to be in the list — just
    /// that the server is reachable.
    func testOllamaConnection() async {
        testResult = .testing
        let url = URL(string: "http://localhost:11434/api/tags")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                testResult = .failure("Not an HTTP response")
                return
            }
            if (200..<300).contains(http.statusCode) {
                // Parse the JSON to count loaded models. The
                // shape is {"models": [{"name": "..."}, ...]}.
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    testResult = .success("Ollama running, \(models.count) model(s) loaded")
                } else {
                    testResult = .success("Ollama running (HTTP \(http.statusCode))")
                }
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                testResult = .failure("HTTP \(http.statusCode): \(body.prefix(150))")
            }
        } catch let e as URLError {
            if e.code == .cannotConnectToHost {
                testResult = .failure("Ollama not running. Start it with: ollama serve")
            } else {
                testResult = .failure("Connection error: \(e.localizedDescription)")
            }
        } catch {
            testResult = .failure("Error: \(error.localizedDescription)")
        }
    }

    /// Phase 4.6: test the custom provider by sending a
    /// minimal POST /v1/chat/completions request with
    /// max_tokens=1. This verifies BOTH the URL and the
    /// API key, not just /models. (Some providers accept
    /// /models without auth, so /models alone is
    /// insufficient for cloud keys.) The cost is one
    /// token of generation; negligible.
    func testCustomConnection() async {
        testResult = .testing
        guard let url = URL(string: customBaseURL) else {
            testResult = .failure("Invalid URL: \(customBaseURL)")
            return
        }
        // Build a minimal /v1/chat/completions request with
        // max_tokens=1. This exercises the same endpoint the
        // LLMConversationService uses, so a successful test
        // means the URL, the API key, and the model name are
        // all valid together.
        let chatURL = url.appendingPathComponent("chat/completions")
        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !customAPIKey.isEmpty {
            req.setValue("Bearer \(customAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        // Tiny prompt to keep the test response fast.
        let body: [String: Any] = [
            "model": customModel,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                testResult = .failure("Not an HTTP response")
                return
            }
            if (200..<300).contains(http.statusCode) {
                testResult = .success("Connected (HTTP \(http.statusCode))")
            } else {
                // Try to extract OpenAI-style error message.
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
