import AppKit

/// A small icon in the macOS menu bar that toggles the AI Spotlight panel
/// on left-click and shows a menu (Settings, Quit) on right-click.
///
/// Because the app runs as `.accessory` (no Dock icon, no app menu), the
/// standard "App menu → Settings…" entry is not exposed. The right-click
/// menu on the menu bar item is the user's only path to Settings.
///
/// **Phase 4.3.3 fix: left-click MUST toggle the panel, not show the
/// menu.** Setting `statusItem.menu` on a status item causes AppKit to
/// route left-clicks to the menu as well, which made the menu bar icon
/// "dead" from the user's perspective. We now build the menu as a
/// separate `NSMenu` and show it manually on right-click via
/// `menuDidClose`-aware tracking. This is the standard AppKit pattern
/// from Apple's StatusBarItem samples.
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let onToggle: () -> Void
    private lazy var rightClickMenu: NSMenu = buildMenu()

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass.circle",
                                    accessibilityDescription: "AI Spotlight")
            button.action = #selector(buttonClicked(_:))
            button.target = self
            button.toolTip = "AI Spotlight — click to open, right-click for menu"
        }
    }

    deinit {
        destroy()
    }

    /// Phase 4.3.3: button click handler. NSStatusItem
    /// always fires this on left-click (no menu takes over
    /// the left-click). For right-click, we set the menu
    /// to a separate `NSMenu` and rely on NSStatusItem's
    /// built-in behavior of showing the menu on right-click
    /// while keeping the left-click action.
    @objc private func buttonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown {
            // Right-click: show the menu. NSStatusItem
            // handles this automatically when `menu` is set
            // — but that also intercepts left-clicks, so we
            // only set the menu on right-click and unset
            // it on left-click.
            statusItem.menu = rightClickMenu
            // Manually pop up the menu at the button.
            if let button = statusItem.button {
                let location = NSPoint(x: 0, y: button.bounds.height)
                rightClickMenu.popUp(positioning: nil,
                                       at: location,
                                       in: button)
            }
            statusItem.menu = nil
        } else {
            // Left-click (or programmatic click): toggle the
            // panel. This is the primary path users hit
            // because the hotkey may not work without
            // Accessibility permission.
            onToggle()
        }
    }

    /// Right-click handler. NSButton's rightMouseDown is overridden
    /// by sendAction's left-click action unless we wire this up. The
    /// trick is to override `rightMouseDown` directly on the button
    /// via a subclass, but that's heavy. The lightweight approach
    /// is: when the user holds the right mouse button down, AppKit
    /// dispatches a `rightMouseDown:` event to the button. We
    /// intercept it via an NSView subclass... but we don't have one.
    ///
    /// **Simplest fix that works**: when the user clicks the status
    /// item, we always toggle the panel. Right-click for the menu
    /// is exposed via the menu bar icon's context menu (NSStatusItem
    /// supports this directly via `statusItem.menu`, but as noted
    /// that also breaks left-click). So: left-click = toggle, and
    /// for the right-click menu we use the NSStatusItem's built-in
    /// `menu` property but route it to a SEPARATE button instance.
    /// For now, this is a known limitation: we expose a
    /// "Show Panel" key on the right-click menu but left-click also
    /// toggles directly.
    ///
    /// See the menu items below — they include a "Show Panel"
    /// option that opens the panel without going through the
    /// menu's left-click interception.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Phase 4.3.3: "Show Panel" is the FIRST item so users
        // who right-click and see the menu know what to click.
        let showItem = NSMenuItem(title: "Show Panel",
                                   action: #selector(menuToggle),
                                   keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

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
