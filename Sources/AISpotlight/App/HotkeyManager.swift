import AppKit
import Combine

/// Listens for a global ⌘+Space keypress (or any configured combo) and fires `onToggle`.
/// Requires Accessibility permission — first launch will trigger the system prompt.
final class HotkeyManager {
    private var monitor: Any?
    private let onToggle: () -> Void
    private let modifiers: NSEvent.ModifierFlags
    private let keyCode: UInt16

    init(modifiers: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 49, onToggle: @escaping () -> Void) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.onToggle = onToggle
    }

    func start() {
        // Stop any existing monitor first (safe to call multiple times)
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if event.keyCode == self.keyCode && event.modifierFlags.contains(self.modifiers) {
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
