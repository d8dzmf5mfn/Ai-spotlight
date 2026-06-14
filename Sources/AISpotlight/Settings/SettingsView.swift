import SwiftUI

struct SettingsView: View {
    @StateObject private var store = SettingsStore()

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $store.activeProvider) {
                    Text("None (rule-based only)").tag("none")
                    Text("OpenAI").tag("openai")
                    Text("MiniMax").tag("minimax")
                }
            }
            Section("API Keys") {
                SecureField("OpenAI API Key", text: $store.openaiKey)
                SecureField("MiniMax API Key", text: $store.minimaxKey)
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
