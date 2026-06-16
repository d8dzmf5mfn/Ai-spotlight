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
        didSet {
            defaults.set(customBaseURL, forKey: Self.kBaseURL)
            pushConfigToProvider()
        }
    }
    @Published var customModel: String {
        didSet {
            defaults.set(customModel, forKey: Self.kModel)
            pushConfigToProvider()
        }
    }
    @Published var customAPIKey: String = "" {
        didSet {
            // Phase 5-E fix: save to Keychain on change.
            // The previous code only loaded from Keychain
            // on init and never wrote back. If the app
            // was restarted, the new key was lost.
            if !customAPIKey.isEmpty {
                try? keychain.set(customAPIKey, for: Self.kKeychain)
            } else {
                try? keychain.delete(Self.kKeychain)
            }
            pushConfigToProvider()
        }
    }

    // MARK: Phase 5-F: live provider re-wiring
    /// The currently-active provider. main.swift sets this
    /// once at launch. SettingsStore pokes it via
    /// `updateConfig` whenever customModel / customBaseURL /
    /// customAPIKey change. This is the small fix for the
    /// "SettingsStore ≠ runtime provider config" bug where
    /// the running provider kept the launch-time model
    /// (deepseek-v4-flash) even after the user changed
    /// Settings.
    ///
    /// We type this as `OpenAICompatibleProvider?` rather
    /// than `AIProvider?` because only the OpenAI-compatible
    /// path has the updateConfig method. Ollama goes through
    /// the same provider type (it's also OpenAI-compatible
    /// at /v1/chat/completions since 0.5.0), so the type
    /// covers both. The custom URL path is the same type
    /// too. This avoids introducing a protocol method
    /// we'd then have to implement on every provider.
    weak var liveProvider: OpenAICompatibleProvider?

    /// Recompute the resolved config and push it to the
    /// live provider, if one is registered. Called from
    /// didSet handlers on customBaseURL, customModel,
    /// and customAPIKey. Idempotent and cheap — it's a
    /// struct copy + a property reassignment.
    func pushConfigToProvider() {
        guard let provider = liveProvider else {
            Log.write("[SettingsStore] pushConfigToProvider: no liveProvider (SettingsStore was deallocated or wiring missing)")
            return
        }
        guard let newConfig = resolveConfig() else {
            Log.write("[SettingsStore] pushConfigToProvider: resolveConfig returned nil (activeProvider=custom but URL or model is empty)")
            return
        }
        Log.write("[SettingsStore] pushConfigToProvider: pushing model=\(newConfig.model) baseURL=\(newConfig.baseURL.absoluteString)")
        provider.updateConfig(newConfig)
    }

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
        // For the URL: always set it to the preset's default.
        // Phase 5-E fix: the previous code guarded with
        // `if customBaseURL.isEmpty`, which meant that
        // changing from one preset to another (e.g. from
        // a custom "governor" endpoint to DeepSeek) would
        // NOT update the URL. The old URL persisted, the
        // running provider sent requests to the old host,
        // and the user got "HTTP 401 -Authentication Fails
        // (governor)" even though the Settings UI showed
        // the new provider's green "Test connection" status.
        // If the user wants a custom URL they use the
        // "Custom" preset, which has an empty default URL
        // and lets them type freely.
        customBaseURL = preset.defaultBaseURL
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
            // Phase 5-E: robust success check. Some providers
            // and local proxies (Ollama's OpenAI-compat shim,
            // LM Studio, OpenClaw, LiteLLM) greedily return
            // HTTP 200 to a max_tokens:1 request even when
            // the model name is invalid. We previously took
            // any 200 as a green check, which masked typos
            // like deepseek-v4-flash (which the user then
            // hit at chat-completion time as HTTP 401
            // "Authentication Fails (governor)" from
            // DeepSeek's model-authorization layer).
            //
            // The new check: a real success response must
            // contain a `choices` array with at least one
            // entry. A 200 with no choices or with an
            // `error` field in the body is reported as a
            // failure, not a success.
            if (200..<300).contains(http.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorDict = json["error"] as? [String: Any] {
                        let message = (errorDict["message"] as? String) ?? "Unknown error"
                        testResult = .failure("HTTP \(http.statusCode): \(message)")
                        return
                    }
                    if let choices = json["choices"] as? [[String: Any]], !choices.isEmpty {
                        testResult = .success("Connected (HTTP \(http.statusCode), model '\(customModel)' accepted)")
                        return
                    }
                }
                // 200 but no choices and no error — could be a
                // proxy that wraps the body. Surface the raw
                // body so the user can see what's happening.
                let body = String(data: data, encoding: .utf8) ?? ""
                testResult = .failure("HTTP 200 but response is not a chat completion: \(body.prefix(200))")
                return
            }
            // 4xx / 5xx — parse OpenAI-style error body first
            // ({"error": {"message": "..."}}), then fall back
            // to a raw body slice.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                testResult = .failure("HTTP \(http.statusCode): \(message)")
                return
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let trimmed = body.prefix(200)
            testResult = .failure("HTTP \(http.statusCode): \(trimmed)")
        } catch let e as URLError {
            testResult = .failure("Connection error: \(e.localizedDescription)")
        } catch {
            testResult = .failure("Error: \(error.localizedDescription)")
        }
    }
}
