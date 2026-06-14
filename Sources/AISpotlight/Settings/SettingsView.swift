import SwiftUI

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
                Text("Press ⌘+Space to toggle. If ⌘+Space also opens macOS Spotlight, see Task 17.5 to free it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}
