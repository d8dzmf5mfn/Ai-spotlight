import AppKit
import Foundation
import KeyboardShortcuts
import AISpotlightKit

/// Thin wrapper around sindresorhus/KeyboardShortcuts that registers a single
/// global hotkey which toggles a callback. Centralizes the KeyboardShortcuts.Name
/// declaration and the onKeyDown subscription in one place so the rest of the
/// app doesn't need to know about the library.
///
/// Default: ⌘+Space. To free that up, the user disables system Spotlight's
/// ⌘+Space binding in System Settings → Keyboard → Keyboard Shortcuts → Spotlight
/// → uncheck "Show Spotlight search". The Settings UI also lets the user rebind
/// via `KeyboardShortcuts.Recorder`.
final class HotkeyService {
    /// Stable identifier for our hotkey. Persists user rebindings across
    /// app launches (KeyboardShortcuts stores them in UserDefaults under this name).
    static let togglePanelName = KeyboardShortcuts.Name("toggleAISpotlight")

    /// The default combo. The user can rebind via the Settings recorder.
    /// Note: `KeyboardShortcuts.Key.space` is the strongly-typed key, and
    /// `NSEvent.ModifierFlags.command` is the typed modifier bitmask.
    static let defaultShortcut: KeyboardShortcuts.Shortcut =
        .init(.space, modifiers: .command)

    /// One-shot global registration. The callback is held by the library,
    /// so we don't need to retain the HotkeyService instance.
    static func startGlobal(onToggle: @escaping () -> Void) {
        let name = togglePanelName
        if KeyboardShortcuts.getShortcut(for: name) == nil {
            KeyboardShortcuts.setShortcut(defaultShortcut, for: name)
        }
        KeyboardShortcuts.onKeyDown(for: name) {
            Log.write("hotkey: ⌘+Space pressed, toggling panel")
            onToggle()
        }
        Log.write("hotkey: KeyboardShortcuts registered for \(name)")
    }
}
