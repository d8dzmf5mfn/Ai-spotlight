import AppKit
import Combine

/// Listens for a global ⌘+Space keypress (or any configured combo) and fires `onToggle`.
/// Requires Accessibility permission — first launch will trigger the system prompt.
final class HotkeyManager {
    private var monitor: Any?
    private let onToggle: () -> Void
    private let modifiers: NSEvent.ModifierFlags
    private let keyCode: UInt16
    /// Window to ignore events from (i.e. our own search field) so that
    /// pressing ⌘+Space while typing doesn't hide the panel (B8 fix).
    weak var panel: NSWindow?

    init(modifiers: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 49, onToggle: @escaping () -> Void) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.onToggle = onToggle
    }

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // B8: ignore events from our own panel's window
            if let panel = self.panel, event.window === panel { return }
            // B7: exact modifier match (not superset) — ⌘+Shift+Space should NOT toggle
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == self.keyCode && eventMods == self.modifiers {
                DispatchQueue.main.async { self.onToggle() }
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { stop() }
}
