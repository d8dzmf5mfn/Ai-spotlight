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
        // Phase 4.6.2: the NSWindow was hardcoded to 480x460
        // and the SwiftUI frame modifier was being ignored
        // because the window content size is set here. We
        // now use 600x500 as the initial content size and
        // set `minSize` so the user can resize up. The
        // SwiftUI body still has the ideal/min frame
        // hints but those act as suggestions when the
        // host controller reports a content size; the
        // NSWindow's contentRect is what actually drives
        // the rendered window.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                          styleMask: style,
                          backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "AI Spotlight Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 360)
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
