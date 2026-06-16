import SwiftUI
import KeyboardShortcuts
import AISpotlightKit

struct SettingsView: View {
    @StateObject private var store = SettingsStore()
    @StateObject private var discovery = LocalModelDiscoveryState()

    var body: some View {
        Form {
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
                }
            }

            if store.activeProvider == "custom" {
                Section("Custom provider settings") {
                    TextField("Base URL", text: $store.customBaseURL, prompt: Text("https://api.openai.com/v1"))
                    TextField("Model", text: $store.customModel, prompt: Text("gpt-4o-mini"))
                    SecureField("API key (leave blank for providers that don't require one)",
                                text: $store.customAPIKey)
                }
            }

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
        }
        .padding(20)
        .frame(width: 480, height: 500)
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
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Heads up: \(store.ollamaModel) needs ~2.5GB+ of RAM. On a 16GB Mac with AI Spotlight running, this can OOM. Try gemma2:2b or qwen2.5:3b.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
