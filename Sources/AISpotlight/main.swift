import AppKit
import AISpotlightKit
import Foundation
import SwiftUI
import Carbon.HIToolbox

// Direct file write at process start — before any framework setup
let startMsg = "\(Date()) main.swift top-level code entered\n"
let _ = try? Data(startMsg.utf8).write(to: URL(fileURLWithPath: "/tmp/aispotlight-app.log"))

// Traditional main.swift entry point. @main doesn't always link correctly
// in SwiftPM executable targets, so we use main.swift directly.
_ = AppLauncher.shared

final class AppLauncher: NSObject, NSApplicationDelegate {
    static let shared = AppLauncher()
    var panel: SpotlightPanel!
    var hotkey: HotkeyManager!
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
        // every launch and causes NSEvent.addGlobalMonitorForEvents to silently
        // fail. The user grants it once in System Settings; we just verify.)
        let trusted = AXIsProcessTrusted()
        Log.write("accessibility trusted=\(trusted)")

        // Don't re-register Carbon hotkey from applicationDidFinishLaunching —
        // do it ONCE on first run. Re-registering in-place causes -9878
        // (already registered). The original start() is called below.

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

        // Try ⌥+Space first (Phase 1 safest). ⌘+Space is owned by Spotlight
        // and RegisterEventHotKey will return a non-zero status for it.
        hotkey = HotkeyManager(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | optionKey), onToggle: toggleAction)
        hotkey.panel = panel
        hotkey.start()
        Log.write("hotkey.start() called (Carbon RegisterEventHotKey ⌥+Space)")

        // Always-on menu bar icon — works as a fallback when the global hotkey
        // can't be installed (macOS 14+ Input Monitoring permission is unreliable).
        _ = StatusBarController(onToggle: toggleAction)
        Log.write("status bar icon installed")

        // First-launch UX: show panel once so the user sees the search experience
        // before they have a working hotkey. They can rebind later in Settings.
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
