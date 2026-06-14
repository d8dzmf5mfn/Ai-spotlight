import Foundation
import AppKit
import AISpotlightKit

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var activeProvider: String {
        didSet { defaults.set(activeProvider, forKey: "activeAIProvider") }
    }
    @Published var hotkeyModifiers: Int {
        didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }
    @Published var hotkeyKey: Int {
        didSet { defaults.set(hotkeyKey, forKey: "hotkeyKey") }
    }
    @Published var hotkeyKeyString: String {
        didSet { defaults.set(hotkeyKeyString, forKey: "hotkeyKeyString") }
    }

    let keychain: KeychainStoring
    @Published var openaiKey: String = ""
    @Published var minimaxKey: String = ""

    init(keychain: KeychainStoring = KeychainStore()) {
        self.keychain = keychain
        // user decision: open-box, no key needed
        self.activeProvider = defaults.string(forKey: "activeAIProvider") ?? "none"
        let mod = defaults.integer(forKey: "hotkeyModifiers")
        self.hotkeyModifiers = mod == 0 ? Int(NSEvent.ModifierFlags.command.rawValue) : mod
        let key = defaults.integer(forKey: "hotkeyKey")
        self.hotkeyKey = key == 0 ? 49 : key  // 49 = space
        self.hotkeyKeyString = defaults.string(forKey: "hotkeyKeyString") ?? "space"
        self.openaiKey = (try? keychain.get("openai_api_key")) ?? ""
        self.minimaxKey = (try? keychain.get("minimax_api_key")) ?? ""
    }

    func saveKeys() {
        if !openaiKey.isEmpty { try? keychain.set(openaiKey, for: "openai_api_key") }
        if !minimaxKey.isEmpty { try? keychain.set(minimaxKey, for: "minimax_api_key") }
    }
}
