import Foundation
import AppKit
import AISpotlightKit

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var activeProvider: String {
        didSet { defaults.set(activeProvider, forKey: "activeAIProvider") }
    }
    // D1: hotkey fields removed. HotkeyManager is hardcoded to ⌘+Space for Phase 1.
    // A settings surface that doesn't actually rewire the hotkey would mislead users.

    let keychain: KeychainStoring
    @Published var openaiKey: String = ""

    init(keychain: KeychainStoring = KeychainStore()) {
        self.keychain = keychain
        // user decision: open-box, no key needed
        self.activeProvider = defaults.string(forKey: "activeAIProvider") ?? "none"
        self.openaiKey = (try? keychain.get("openai_api_key")) ?? ""
    }

    func saveKeys() {
        if !openaiKey.isEmpty { try? keychain.set(openaiKey, for: "openai_api_key") }
    }
}
