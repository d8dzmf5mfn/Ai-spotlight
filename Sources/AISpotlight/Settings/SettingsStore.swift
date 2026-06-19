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
        didSet {
            defaults.set(activeProvider, forKey: Self.kProvider)
            // Phase 5-G: pushing the config when the provider changes ensures
            // the running provider switches to the new provider's settings
            // (e.g. ollama → custom). Without this, the live provider
            // retains the previous provider's config.model, which is the
            // root cause of the 'deepseek-v4-flash' governor 401 bug.
            pushConfigToProvider()
        }
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
            Log.write("[SettingsStore] pushConfigToProvider: resolveConfig returned nil for activeProvider=\(activeProvider)")
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
    /// Phase 5-C: per-step diagnostic verdicts. The UI
    /// renders 4 rows (URL reachable, API key valid,
    /// Model exists, Inference works), each with ✓ / ⏳ / ✗
    /// + a specific message. This replaces the previous
    /// single-line testResult.
    @Published var diagnosticVerdicts: [ConnectionDiagnosticService.Step: ConnectionDiagnosticService.Verdict] = [:]
    @Published var isRunningDiagnostic: Bool = false
    /// Phase 5-D: same 4-row structure for the Ollama
    /// section. We keep these in a separate dictionary so
    /// the Ollama and Custom diagnostics don't clobber
    /// each other when the user switches providers in
    /// Settings.
    @Published var ollamaDiagnosticVerdicts: [ConnectionDiagnosticService.Step: ConnectionDiagnosticService.Verdict] = [:]
    @Published var isRunningOllamaDiagnostic: Bool = false

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
        didSet {
            defaults.set(ollamaModel, forKey: Self.kOllama)
            // Phase 5-G: pushing the config when the Ollama model changes ensures
            // the live provider uses the updated model name for inference.
            pushConfigToProvider()
        }
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

    // MARK: Phase 6 Step-3: search backend augmentation
    /// Whether to include `SQLiteBackend` in the fan-out when
    /// `SearchOrchestrator` runs. Default OFF. When OFF, the
    /// orchestrator fans out to the original three providers
    /// (FileSystem, Content, Apps). When ON, the orchestrator
    /// also includes the SQLite augmentation backend; today the
    /// backend's `search()` is a no-op (returns []) and its
    /// provider weight is 0, so this flag has no observable
    /// effect yet. The flag exists so that the wiring point is
    /// in place when Step-3 ships the FTS5 query implementation.
    @Published var useSQLiteAugmentation: Bool {
        didSet { defaults.set(useSQLiteAugmentation, forKey: Self.kUseSQLite) }
    }

    /// Step-4: the IndexingBoundary for managing enrolled paths.
    /// Set by main.swift after creation. SettingsView uses this
    /// to let the user add/remove indexed directories.
    var indexingBoundary: IndexingBoundary?

    /// Step-4: reference to the SyncService for manual scan triggering.
    /// Set by main.swift after creation. SettingsView uses this
    /// to let the user trigger an immediate re-scan.
    var syncService: SyncService?

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
        // Default ON — Step-4: SQLite augmentation is active.
        // The backend participates in search fan-out alongside
        // MDQuery. Users can disable it here or manage indexed
        // folders in the "Indexed Folders" section.
        self.useSQLiteAugmentation = defaults.object(forKey: Self.kUseSQLite) as? Bool ?? true
    }

    private static let kIndexCode = "indexCodeFiles"
    private static let kIndexRich = "indexRichTextFiles"
    private static let kUseSQLite = "useSQLiteAugmentation"

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


    /// Phase 4.6: test the custom provider by sending a
    /// minimal POST /v1/chat/completions request with
    /// max_tokens=1. This verifies BOTH the URL and the
    /// API key, not just /models. (Some providers accept
    /// /models without auth, so /models alone is
    /// insufficient for cloud keys.) The cost is one
    /// token of generation; negligible.


    /// Phase 5-C: run the 4-step connection diagnostic.
    /// Replaces the single-line testCustomConnection for
    /// cloud providers. The UI now shows 4 rows (URL,
    /// Auth, Model, Inference), each with a precise error
    /// message so the user can tell at a glance which of
    /// the 4 layers failed.
    func runDiagnostic() async {
        guard let descriptor = await ProviderRegistry.shared.descriptor(for: selectedPreset) else {
            diagnosticVerdicts = [:]
            return
        }
        let baseURL = customBaseURL.isEmpty ? descriptor.defaultBaseURL : customBaseURL
        // Reset all 4 steps to .pending so the UI shows ⏳
        // for each, then immediately to .running for step 1.
        // The actor updates each step as it completes.
        diagnosticVerdicts = Dictionary(
            uniqueKeysWithValues: ConnectionDiagnosticService.Step.allCases.map { ($0, .pending) }
        )
        isRunningDiagnostic = true
        defer { isRunningDiagnostic = false }
        let service = ConnectionDiagnosticService()
        // Step-1: URL reachable
        diagnosticVerdicts[.urlReachable] = .running
        let v1 = await service.checkURLReachable(baseURL: baseURL)
        diagnosticVerdicts[.urlReachable] = v1
        if case .failed = v1 { return }
        // Step-2: Auth valid
        diagnosticVerdicts[.authValid] = .running
        let v2 = await service.checkAuthValid(
            descriptor: descriptor, baseURL: baseURL, apiKey: customAPIKey
        )
        diagnosticVerdicts[.authValid] = v2
        if case .failed = v2 { return }
        // Step-3: Model exists
        diagnosticVerdicts[.modelExists] = .running
        let v3 = await service.checkModelExists(
            descriptor: descriptor, baseURL: baseURL, apiKey: customAPIKey,
            model: customModel
        )
        diagnosticVerdicts[.modelExists] = v3
        if case .failed = v3 { return }
        // Step-4: Inference works
        diagnosticVerdicts[.inferenceWorks] = .running
        let v4 = await service.checkInferenceWorks(
            descriptor: descriptor, baseURL: baseURL, apiKey: customAPIKey,
            model: customModel
        )
        diagnosticVerdicts[.inferenceWorks] = v4
    }

    /// Phase 5-D: 4-step diagnostic for the Ollama
    /// section. Same actor, hard-coded Ollama
    /// descriptor, separate verdict dictionary. The
    /// Ollama base URL is `http://localhost:11434` (the
    /// discovery strategy is `.ollamaTags` which hits
    /// `/api/tags`, not `/v1/models`). The 4 steps are:
    /// 1. URL reachable (localhost:11434)
    /// 2. Ollama running (200 from /api/tags)
    /// 3. Model loaded (gemma2:2b is in the catalog)
    /// 4. Inference works (POST /api/generate or
    ///    /api/chat — Ollama's native endpoint, not
    ///    /v1/chat/completions)
    func runOllamaDiagnostic() async {
        guard let descriptor = await ProviderRegistry.shared.descriptor(for: "ollama") else {
            ollamaDiagnosticVerdicts = [:]
            return
        }
        let baseURL = descriptor.defaultBaseURL
        ollamaDiagnosticVerdicts = Dictionary(
            uniqueKeysWithValues: ConnectionDiagnosticService.Step.allCases.map { ($0, .pending) }
        )
        isRunningOllamaDiagnostic = true
        defer { isRunningOllamaDiagnostic = false }
        let service = ConnectionDiagnosticService()
        // Step-1: URL reachable
        ollamaDiagnosticVerdicts[.urlReachable] = .running
        let v1 = await service.checkURLReachable(baseURL: baseURL)
        ollamaDiagnosticVerdicts[.urlReachable] = v1
        if case .failed = v1 { return }
        // Step-2: Auth valid (Ollama uses no API key)
        ollamaDiagnosticVerdicts[.authValid] = .running
        let v2 = await service.checkAuthValid(
            descriptor: descriptor, baseURL: baseURL, apiKey: ""
        )
        ollamaDiagnosticVerdicts[.authValid] = v2
        if case .failed = v2 { return }
        // Step-3: Model exists
        ollamaDiagnosticVerdicts[.modelExists] = .running
        let v3 = await service.checkModelExists(
            descriptor: descriptor, baseURL: baseURL, apiKey: "",
            model: ollamaModel
        )
        ollamaDiagnosticVerdicts[.modelExists] = v3
        if case .failed = v3 { return }
        // Step-4: Inference works
        ollamaDiagnosticVerdicts[.inferenceWorks] = .running
        let v4 = await service.checkInferenceWorks(
            descriptor: descriptor, baseURL: baseURL, apiKey: "",
            model: ollamaModel
        )
        ollamaDiagnosticVerdicts[.inferenceWorks] = v4
    }
}
