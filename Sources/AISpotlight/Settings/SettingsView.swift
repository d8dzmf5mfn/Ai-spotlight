import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @StateObject private var store = SettingsStore()

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $store.activeProvider) {
                    Text("None (rule-based only)").tag("none")
                    Text("OpenAI").tag("openai")
                    // D2: MiniMax removed until Phase 2 implements MiniMaxProvider.
                }
            }
            Section("API Keys") {
                SecureField("OpenAI API Key", text: $store.openaiKey)
                Button("Save") { store.saveKeys() }
            }
            Section("Hotkey") {
                // Recorder writes the user's chosen binding to UserDefaults
                // under HotkeyService.togglePanelName.rawValue, which the
                // library then re-installs on next launch.
                KeyboardShortcuts.Recorder("Toggle AI Spotlight:",
                                          name: HotkeyService.togglePanelName)
                Text("Default: ⌘+Space. If ⌘+Space also opens macOS Spotlight, " +
                     "disable it in System Settings → Keyboard → Keyboard Shortcuts " +
                     "→ Spotlight → uncheck \"Show Spotlight search\".")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }
}
