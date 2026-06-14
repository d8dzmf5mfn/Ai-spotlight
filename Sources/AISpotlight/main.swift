import AppKit
import AISpotlightKit
import Foundation
import SwiftUI

// Bootstrap log: first thing main.swift does, before any framework setup.
// If everything after this fails, we'll still have proof that main.swift
// was entered and how far execution got. See Log.bootstrap for why this
// can't just be a Log.write call.
Log.bootstrap("main.swift top-level code entered")

// NOTE:
// Global hotkey (Carbon / NSEvent / CGEventTap) is intentionally disabled in Phase 1.
// On macOS 27 + Swift 6 + SwiftPM builds, hotkey registration is unreliable due to
// TCC / signing / event routing inconsistencies (Carbon returns noErr but the C
// callback is never invoked; NSEvent monitors install but receive no events).
//
// We defer system-level input capture to Phase 2, after:
//   - proper Developer ID signing
//   - a .dmg / .pkg installer
//   - settling on a known-good third-party library (e.g. KeyboardShortcuts) or
//     a Raycast-style helper-app architecture
//
// In Phase 1, the supported way to summon the panel is the menu bar icon —
// see StatusBarController. This is the right MVP boundary: the product is
// "AI command palette", not "system input capturer".
_ = AppLauncher.shared

final class AppLauncher: NSObject, NSApplicationDelegate {
    static let shared = AppLauncher()
    var panel: SpotlightPanel!
    var state: AppState!

    override init() {
        super.init()
        Log.write("AppLauncher init")
        let app = NSApplication.shared
        app.delegate = self
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("applicationDidFinishLaunching entered")

        FirstLaunchHelper.runIfNeeded()

        // Check Accessibility (do NOT prompt — that resets the grant
        // every launch. The user grants it once in System Settings; we just
        // verify.)
        let trusted = AXIsProcessTrusted()
        Log.write("accessibility trusted=\(trusted)")

        let settings = SettingsStore()
        let keychain: KeychainStoring = KeychainStore()
        let ai = AIFactory.makeProvider(named: settings.activeProvider, keychain: keychain)
        let interpreter = QueryInterpreter(aiProvider: ai)
        let orchestrator = SearchOrchestrator(providers: [
            FileSystemProvider(),
            AppProvider(),
        ])
        state = AppState(interpreter: interpreter, orchestrator: orchestrator)

        let host = NSHostingController(rootView: SearchWindowView(state: state))
        panel = SpotlightPanel()
        panel.contentViewController = host

        let toggleAction: () -> Void = { [weak self] in
            guard let self else { return }
            self.state.query = ""
            self.state.results = []
            self.panel.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let tf = self.findTextField(in: self.panel.contentView) {
                    self.panel.makeFirstResponder(tf)
                }
            }
        }

        // Single, reliable entry point: the menu bar icon.
        _ = StatusBarController(onToggle: toggleAction)
        Log.write("status bar icon installed")

        // Global hotkey (⌘+Space by default, user-rebindable in Settings).
        // Uses sindresorhus/KeyboardShortcuts — see ~/.hermes/skills/
        // macos-global-hotkey-diagnosis for why we abandoned the hand-rolled
        // Carbon/NSEvent path.
        HotkeyService.startGlobal(onToggle: toggleAction)
        Log.write("hotkey service started")

        // First-launch UX: show panel once so the user sees the search experience.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Log.write("auto-toggling panel for first-time UX")
            self?.panel.toggle()
        }
    }

    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let v = view else { return nil }
        if let tf = v as? NSTextField { return tf }
        for sub in v.subviews {
            if let tf = findTextField(in: sub) { return tf }
        }
        return nil
    }
}
