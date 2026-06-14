import AppKit
import SwiftUI

final class SpotlightPanel: NSPanel {
    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 400)
        super.init(
            contentRect: contentRect,
            // A1: drop .hudWindow (deprecated since macOS 10.12) and rely on
            // SwiftUI's .ultraThinMaterial background for the vibrancy look.
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isMovableByWindowBackground = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
    }

    // A2: with .nonactivatingPanel, canBecomeMain is silently ignored anyway.
    // Remove the override so we don't lie about the panel's capabilities.
    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible { orderOut(nil); return }
        positionCenter()
        makeKeyAndOrderFront(nil)
    }

    private func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(
            x: vf.midX - frame.width / 2,
            y: vf.midY - frame.height / 2 + 200
        )
        setFrameOrigin(origin)
    }
}
