import AppKit

/// Shows a one-time dialog guiding the user to disable macOS Spotlight's
/// ⌘+Space binding, so our hotkey can take over. Without this, ⌘+Space would
/// either do nothing (if our monitor wins) or open system Spotlight AND toggle
/// our panel (if both fire).
@MainActor
enum FirstLaunchHelper {
    private static let shownKey = "didShowSpotlightConflictDialog"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        NSLog("[AISpotlight] FirstLaunchHelper.runIfNeeded: flag=%d", defaults.bool(forKey: shownKey) ? 1 : 0)
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "⌘+Space is taken by macOS Spotlight"
        alert.informativeText = """
        AI Spotlight uses ⌘+Space to open, but macOS Spotlight already owns it.

        Click "Open System Settings" to jump to the keyboard shortcuts pane, then:
          1. Select "Spotlight" in the sidebar
          2. Uncheck "Show Spotlight search" (the ⌘+Space binding)
          3. Come back here and press ⌘+Space — AI Spotlight will open
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
