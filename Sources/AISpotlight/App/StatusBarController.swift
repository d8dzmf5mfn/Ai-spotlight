import AppKit

/// A small icon in the macOS menu bar that toggles the AI Spotlight panel
/// on left-click and shows a menu (Settings, Quit) on right-click.
///
/// Because the app runs as `.accessory` (no Dock icon, no app menu), the
/// standard "App menu → Settings…" entry is not exposed. The right-click
/// menu on the menu bar item is the user's only path to Settings.
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass.circle",
                                    accessibilityDescription: "AI Spotlight")
            button.action = #selector(toggleFromButton)
            button.target = self
            button.toolTip = "AI Spotlight — click to open, right-click for menu"
        }
        // Setting `menu` causes AppKit to handle right-click (shows menu)
        // and left-click (fires the action) automatically. We don't need
        // a manual `currentEvent` check here.
        statusItem.menu = buildMenu()
    }

    @objc private func toggleFromButton() {
        onToggle()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Toggle Panel",
                                     action: #selector(menuToggle),
                                     keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                       action: #selector(openSettings),
                                       keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AI Spotlight",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuToggle() {
        onToggle()
    }

    @objc private func openSettings() {
        // Open the SwiftUI Settings scene. We post a notification so the
        // AppDelegate can show the window. The Settings scene is registered
        // in AISpotlightApp via `Settings { SettingsView() }`, but in an
        // accessory app the menu-bar Settings… is the only way to surface it.
        NotificationCenter.default.post(name: .aispotlightOpenSettings, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func destroy() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

extension Notification.Name {
    static let aispotlightOpenSettings = Notification.Name("AISpotlight.openSettings")
}
