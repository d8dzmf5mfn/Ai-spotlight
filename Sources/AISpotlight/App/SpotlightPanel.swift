import AppKit
import SwiftUI

final class SpotlightPanel: NSPanel {
    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 400)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .hudWindow],
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Show the panel (centered, slightly above mid-screen like Spotlight) or hide it.
    func toggle() {
        if isVisible { orderOut(nil); return }
        positionCenter()
        makeKeyAndOrderFront(nil)
    }

    private func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        // Slightly above center, like real Spotlight
        let origin = NSPoint(
            x: vf.midX - frame.width / 2,
            y: vf.midY - frame.height / 2 + 200
        )
        setFrameOrigin(origin)
    }
}
