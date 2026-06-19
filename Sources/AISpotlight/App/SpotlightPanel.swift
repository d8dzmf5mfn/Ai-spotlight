import AppKit
import SwiftUI

final class SpotlightPanel: NSPanel {
    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 400)
        super.init(
            contentRect: contentRect,
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
        // Scale-away on order-out for a polished dismissal
        self.animationBehavior = .documentWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func toggle() {
        if isVisible {
            // Animated hide
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 0
            } completionHandler: {
                self.orderOut(nil)
                self.alphaValue = 1.0
            }
            return
        }
        positionCenter()
        // Start invisible, then fade in
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
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
