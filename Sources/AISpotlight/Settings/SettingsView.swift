import SwiftUI
import KeyboardShortcuts
import AISpotlightKit

struct SettingsView: View {
    /// Phase 5-F: the SAME SettingsStore instance that
    /// main.swift created and wired the liveProvider to.
    /// NOT a fresh @StateObject — a fresh instance would
    /// have liveProvider = nil and pushConfigToProvider
    /// would silently do nothing.
    @ObservedObject var store: SettingsStore
    @StateObject private var discovery = LocalModelDiscoveryState()

    var body: some View {
        Form {
            // Phase 6 (b2): top-level visual grouping. Each `Group`
            // wraps one or more related Section(s) under a header
            // so the Settings window no longer reads as one long
            // undifferentiated list of sections. The header Text
            // is intentionally rendered above the Section's own
            // header — Apple's Form section header remains
            // visible inside the card so each Section remains
            // self-describing.
            Group {
                Text("AI Assistant")
                    .font(.headline)
                    .padding(.top, 4)

            Section("AI Provider") {
                Picker("Provider", selection: $store.activeProvider) {
                    Text("None (rule-based only)").tag("none")
                    Text("Ollama (local)").tag("ollama")
                    Text("Custom (any OpenAI-compatible API)").tag("custom")
                }
                Text(providerDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.activeProvider == "ollama" {
                Section("Ollama settings") {
                    HStack(alignment: .center) {
                        // Picker replaces the freeform text field once the
                        // user has run discovery; if discovery hasn't
                        // succeeded we still let them type a custom model.
                        if discovery.discoveredModels.isEmpty {
                            TextField("Model", text: $store.ollamaModel, prompt: Text("gemma2:2b"))
                        } else {
                            Picker("Model", selection: $store.ollamaModel) {
                                ForEach(discovery.discoveredModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                        }
                        Button {
                            Task { await discovery.detect() }
                        } label: {
                            if discovery.isDetecting {
                                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                            } else {
                                Text("Detect")
                            }
                        }
                        .disabled(discovery.isDetecting)
                    }
                    Text(discoveryStatusLine)
                        .font(.caption).foregroundStyle(discoveryStatusColor)
                    Text("Default endpoint: http://localhost:11434")
                        .font(.caption).foregroundStyle(.secondary)
                    // Phase 5-D: 4-step diagnostic replaces the
                    // 1-line "Test Ollama connection" button.
                    // Same 4-row UI as the Custom section,
                    // but uses ollamaDiagnosticVerdicts and
                    // a separate verdict dict so the two
                    // sections don't clobber each other.
                    ollamaDiagnosticView
                }
            }

            if store.activeProvider == "custom" {
                Section("Custom provider settings") {
                    // Phase 4.6: cloud-model preset picker. Most
                    // OpenAI-compatible providers share the
                    // same /v1/chat/completions endpoint as
                    // OpenAI's own API, so the user just picks
                    // a preset, fills in their API key, and
                    // they're done. We don't lock the fields
                    // after picking — power users can still
                    // override the URL or model.
                    Picker("Preset", selection: $store.selectedPreset) {
                        ForEach(ProviderPreset.all) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .onChange(of: store.selectedPreset) { _, new in
                        if let p = ProviderPreset.all.first(where: { $0.id == new }) {
                            // Pre-fill the URL and model with
                            // the preset's defaults, but only
                            // if those fields are still at the
                            // previous preset's values. This
                            // way switching back and forth
                            // between presets doesn't trash the
                            // user's manual URL edits.
                            store.applyPreset(p)
                        }
                    }
                    TextField("Base URL", text: $store.customBaseURL, prompt: Text("https://api.openai.com/v1"))
                    // Phase 5-H: warn the user when their
                    // customModel is not in the discovered
                    // catalog. This is exactly the failure
                    // mode that caused the "deepseek-v4-flash"
                    // 401: a stale value in UserDefaults that
                    // DeepSeek governor rejects. We show a
                    // red banner + a "Reset to first catalog
                    // entry" button.
                    if !store.discoveredModels.isEmpty
                        && !store.discoveredModels.contains(store.customModel)
                        && !store.useManualModel
                        && Self.canDiscoverModels(for: store.selectedPreset) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model '\(store.customModel)' is not in this provider's catalog")
                                    .font(.callout.bold())
                                Text("Pick a model from the dropdown above, or click Reset to use the first available model.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let first = store.discoveredModels.first {
                                    Button("Reset to '\(first)'") {
                                        store.customModel = first
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    // Phase 5-B: the model field is now a Picker
                    // when discovery has populated the list, OR
                    // a freeform TextField when the user picks
                    // "Type manually...". The Picker calls
                    // ModelDiscoveryService on preset change
                    // (see SettingsStore.applyPreset).
                    modelField
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API key")
                            .font(.subheadline)
                        SecureField("leave blank for providers that don't require one",
                                    text: $store.customAPIKey)
                        Text("Leave blank for providers that don't require one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Phase 5-C: 4-step diagnostic replaces the
                    // single-line testResult UI. Each row shows
                    // ✓ / ⏳ / ✗ with a precise error message
                    // for the corresponding step.
                    diagnosticView
                }
            }
            }  // end Group "AI Assistant"

            Group {
                Text("Search & Indexing")
                    .font(.headline)
                    .padding(.top, 8)

            Section("Content Index") {
                // Phase 3.2.2: user picks which categories of files
                // get indexed. Defaults are all on (zero-friction).
                // Note: only "code" and "rich text" are exposed in the
                // MVP. Text/data and PDFs are always indexed — they
                // have no privacy angle worth a toggle.
                Toggle("Source code files", isOn: $store.indexCodeFiles)
                    .help("Swift, Python, JS, etc. — turn off for privacy.")
                Toggle("Rich text & HTML", isOn: $store.indexRichTextFiles)
                    .help("RTF, HTML — parsed via NSAttributedString.")
            }

            Section("Search Backend") {
                // Phase 6 Step-3: the SQLite augmentation backend is
                // wired into the SearchOrchestrator fan-out when
                // this toggle is ON. Today the backend's `search()`
                // is a no-op (returns []) and its provider weight
                // is 0, so the toggle has no observable effect on
                // results. It exists so the wiring point is in
                // place when Step-3 ships the FTS5 query
                // implementation.
                Toggle("SQLite augmentation (experimental)",
                       isOn: $store.useSQLiteAugmentation)
                    .help("Add a SQLite-backed search provider to the fan-out. Currently a no-op stub; effective when Step-3 ships the FTS5 query implementation.")
                Text("When enabled, a SQLite-backed search provider participates in the fan-out. Today it returns no results. The flag wires the toggle into the orchestrator so Step-3 can land its FTS5 query without further Settings changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }  // end Group "Search & Indexing"

            Group {
                Text("Keyboard")
                    .font(.headline)
                    .padding(.top, 8)

            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle AI Spotlight:",
                                          name: HotkeyService.togglePanelName)
                // Phase 4.3.3: the hotkey requires Accessibility
                // permission. Without it, ⌘+Space won't reach
                // our app — macOS Spotlight will steal it (or
                // nothing happens). Show a button to open
                // System Settings so the user can grant
                // permission in one click.
                if !AXIsProcessTrusted() {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .font(.callout.bold())
                            Text("Click the button below to open System Settings → Privacy & Security → Accessibility, then toggle AI Spotlight on. The hotkey won't work until you do.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("Default: ⌘+Space. If ⌘+Space also opens macOS Spotlight, " +
                     "disable it in System Settings → Keyboard → Keyboard Shortcuts " +
                     "→ Spotlight → uncheck \"Show Spotlight search\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }  // end Group "Keyboard"
        }
        .padding(20)
        // Phase 4.6: the Settings UI grew with cloud-model
        // presets, model size warnings, and the test-
        // connection button. The old fixed 480x500 frame
        // clipped the URL field, the preset dropdown
        // labels (e.g. "ByteDance Doubao (豆包)"), and the
        // accessibility-permission warning. We now use
        // ScrollView + ideal width/height so the window
        // fits the content but can also be resized if
        // the user prefers a larger layout. The ideal
        // values are larger than the old fixed values.
        .frame(minWidth: 540, maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - Status / state helpers

    private var providerDescription: String {
        switch store.activeProvider {
        case "none":
            return "Pure rule-based parser (English + Chinese keywords). " +
                   "No AI cost, no network."
        case "ollama":
            return "Local LLM via Ollama. Make sure the Ollama server " +
                   "is running (default: ollama serve). " +
                   "No API key needed."
        case "custom":
            return "Any OpenAI-compatible API (OpenAI, Together, Groq, LM Studio, etc.). " +
                   "API key is optional for local servers."
        default:
            return ""
        }
    }

    private var discoveryStatusLine: String {
        switch discovery.status {
        case .idle:        return "Click Detect to look for installed Ollama models."
        case .detecting:   return "Talking to http://localhost:11434…"
        case .found(let n):
            if n == 0 { return "Ollama is running but no models are installed. Run: ollama pull gemma2:2b" }
            return "Found \(n) model\(n == 1 ? "" : "s") on your local Ollama."
        case .failed(let msg): return "Discovery failed: \(msg)"
        }
    }

    private var discoveryStatusColor: Color {
        switch discovery.status {
        case .idle, .detecting: return .secondary
        case .found(let n):     return n > 0 ? .green : .orange
        case .failed:           return .red
        }
    }

    private func dismissWindow() {
        // @State saveStatus is purely visual feedback; SettingsStore's
        // @Published vars persist to UserDefaults on every change, so
        // there's nothing to "save" — the user's edits are already live.
        NSApp.keyWindow?.performClose(nil)
    }



    /// Phase 4.3.7: warn when the chosen model is
    /// likely to OOM on a 16GB Mac. Naming conventions
    /// like "4b", "7b", "12b" give a rough size hint:
    /// those are 2.5GB+ at Q4 quantization and tend
    /// to OOM alongside an active AI Spotlight
    /// process. The user can ignore if they have 32GB+.
    @ViewBuilder
    private var modelSizeWarning: some View {
        let m = store.ollamaModel.lowercased()
        let risky = m.contains(":4b") || m.contains(":7b") || m.contains(":8b")
                || m.contains(":12b") || m.contains(":14b") || m.contains(":27b")
                || m.contains(":30b") || m.contains(":70b")
        if risky {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Heads up")
                        .font(.callout.bold())
                }
                Text("Heads up: \(store.ollamaModel) needs ~2.5GB+ of RAM. On a 16GB Mac with AI Spotlight running, this can OOM. Try gemma2:2b or qwen2.5:3b.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Phase 5-C: the 4-row connection diagnostic view.
    /// Renders one row per step (URL, Auth, Model,
    /// Inference), each with ✓ / ⏳ / ✗ + the step's
    /// verdict message. A "Run full diagnostic" button
    /// triggers `store.runDiagnostic()`.
    @ViewBuilder
    private var diagnosticView: some View {
        diagnosticSection(
            verdicts: store.diagnosticVerdicts,
            isRunning: store.isRunningDiagnostic,
            onRun: { Task { await store.runDiagnostic() } }
        )
    }

    /// Phase 5-D: same 4-row UI for the Ollama section.
    /// Separate verdict dict, separate isRunning flag,
    /// separate run method. Same row layout.
    @ViewBuilder
    private var ollamaDiagnosticView: some View {
        diagnosticSection(
            verdicts: store.ollamaDiagnosticVerdicts,
            isRunning: store.isRunningOllamaDiagnostic,
            onRun: { Task { await store.runOllamaDiagnostic() } }
        )
    }

    /// Shared 4-row diagnostic view. Both the Custom
    /// section and the Ollama section use this.
    @ViewBuilder
    private func diagnosticSection(
        verdicts: [ConnectionDiagnosticService.Step: ConnectionDiagnosticService.Verdict],
        isRunning: Bool,
        onRun: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onRun) {
                HStack {
                    if isRunning {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "stethoscope")
                    }
                    Text(isRunning ? "Running diagnostic…" : "Run full diagnostic")
                }
            }
            .disabled(isRunning)
            // Show the 4 rows. We always show them once
            // diagnostic has been run at least once; before
            // that they're hidden so the Settings page
            // doesn't grow when the user hasn't done anything.
            ForEach(ConnectionDiagnosticService.Step.allCases, id: \.self) { step in
                if let verdict = verdicts[step] {
                    diagnosticRow(step: step, verdict: verdict)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticRow(
        step: ConnectionDiagnosticService.Step,
        verdict: ConnectionDiagnosticService.Verdict
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verdictIcon(verdict))
                .frame(width: 16)
                .font(.body.monospaced())
            VStack(alignment: .leading, spacing: 1) {
                Text(step.rawValue)
                    .font(.caption.bold())
                Text(verdictDetail(verdict))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func verdictIcon(_ v: ConnectionDiagnosticService.Verdict) -> String {
        switch v {
        case .pending: return "○"
        case .running: return "⏳"
        case .passed: return "✓"
        case .failed: return "✗"
        }
    }

    private func verdictDetail(_ v: ConnectionDiagnosticService.Verdict) -> String {
        switch v {
        case .pending: return "Waiting…"
        case .running: return "Running…"
        case .passed(let msg): return msg
        case .failed(let msg): return msg
        }
    }


    /// Phase 5-B: the model name field. Smart field that
    /// shows a Picker when discovery has populated the
    /// model list, or a TextField when the user has chosen
    /// to type manually. The "Refresh" button is shown
    /// alongside the field so the user can re-fetch on
    /// demand.
    @ViewBuilder
    private var modelField: some View {
        let canDiscover = Self.canDiscoverModels(for: store.selectedPreset)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if store.useManualModel || !canDiscover || store.discoveredModels.isEmpty {
                    TextField("Model", text: $store.customModel, prompt: Text("gpt-4o-mini"))
                } else {
                    Picker("Model", selection: $store.customModel) {
                        ForEach(store.discoveredModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                }
                Button {
                    Task { await store.refreshModels() }
                } label: {
                    if store.isDiscoveringModels {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isDiscoveringModels || !canDiscover)
                .help("Refresh model list")
            }
            if let err = store.modelDiscoveryError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if let last = store.lastModelRefresh {
                Text("Last refresh: " + Self.relativeTime(last))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !canDiscover {
                Text("This provider has no /v1/models endpoint. Type the model name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if canDiscover && !store.useManualModel && !store.discoveredModels.isEmpty {
                Button("Type a custom model name instead") { store.useManualModel = true }
                    .font(.caption).buttonStyle(.link)
            } else if canDiscover && store.useManualModel {
                Button("Pick from the list") { store.useManualModel = false }
                    .font(.caption).buttonStyle(.link)
            }
        }
    }

    /// Phase 5-B: hardcoded map of provider id to whether
    /// the provider exposes a /v1/models (or /api/tags for
    /// Ollama) endpoint. We use this sync helper because
    /// @ViewBuilder can't do async. In commit C we'll
    /// switch SettingsView to use the ProviderDescriptor
    /// directly and delete this helper.
    private static func canDiscoverModels(for id: String) -> Bool {
        return id != "anthropic"
    }

    /// Phase 5-B: format a Date as a short relative time
    /// string ("2 min ago", "5 sec ago"). Pure function.
    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) sec ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

/// Owns the auto-discovery UI state. Kept as an ObservableObject so the
/// async detection result updates the view automatically.
@MainActor
final class LocalModelDiscoveryState: ObservableObject {
    enum Status: Equatable {
        case idle
        case detecting
        case found(Int)
        case failed(String)
    }

    @Published var isDetecting: Bool = false
    @Published var discoveredModels: [String] = []
    @Published var status: Status = .idle

    private let discovery: LocalModelDiscovering

    init(discovery: LocalModelDiscovering = OllamaDiscovery()) {
        self.discovery = discovery
    }

    /// Trigger one detection round. Updates `status` and `discoveredModels`.
    /// Errors are reported in-band (no throw) so the UI can show a friendly
    /// message rather than a hard alert.
    func detect() async {
        guard !isDetecting else { return }
        isDetecting = true
        status = .detecting
        let endpoint = URL(string: "http://localhost:11434")!
        do {
            let models = try await discovery.availableModels(at: endpoint)
            discoveredModels = models
            status = .found(models.count)
        } catch {
            discoveredModels = []
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        isDetecting = false
    }

}
