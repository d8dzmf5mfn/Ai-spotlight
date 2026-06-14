import AppKit
import SwiftUI

final class SpotlightPanel: NSPanel {
    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 400)
        super.init(
            contentRect: contentRect,
            // Drop .nonactivatingPanel so the panel can become key/main properly.
            // The downside is the panel may briefly steal focus when shown; we
            // compensate by calling makeKeyAndOrderFront and immediately
            // returning focus to the previous app is not possible — but the
            // search field needs focus to be useful.
            styleMask: [.borderless, .resizable],
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

    func toggle() {
        if isVisible {
            orderOut(nil)
            return
        }
        positionCenter()
        // Make key so the search field receives input.
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
