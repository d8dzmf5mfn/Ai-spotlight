import AppKit
import SwiftUI

/// Owns the Settings window. Listens for `.aispotlightOpenSettings` and
/// brings up (or creates) a non-activating panel hosting `SettingsView`.
///
/// Why not use the SwiftUI `Settings { }` scene directly? In an `.accessory`
/// app the standard "App menu → Settings…" doesn't exist, and there's no
/// default keybinding (`⌘+,`) binding to a window that doesn't exist. We
/// open our own window from the menu bar menu instead.
final class SettingsWindowController: NSObject {
    private var window: NSWindow!

    override init() {
        super.init()
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                          styleMask: style,
                          backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "AI Spotlight Settings"
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(show),
            name: .aispotlightOpenSettings,
            object: nil
        )
    }

    @objc func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
