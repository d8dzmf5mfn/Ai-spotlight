import AppKit

/// A small icon in the macOS menu bar that toggles the AI Spotlight panel
/// on click. Acts as a fallback for when the global hotkey can't be
/// installed (e.g. macOS 14+ Input Monitoring permission is unreliable).
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
            button.action = #selector(handleClick)
            button.target = self
            button.toolTip = "AI Spotlight (click to open, or press ⌥+Space)"
        }
    }

    @objc private func handleClick() {
        onToggle()
    }

    func destroy() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
