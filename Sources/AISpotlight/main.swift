import AppKit
import AISpotlightKit
import AISpotlightMac
import Foundation
import SwiftUI
import KeyboardShortcuts
// Bootstrap log: first thing main.swift does, before any framework setup.
// If everything after this fails, we'll still have proof that main.swift
// was entered and how far execution got. See Log.bootstrap for why this
// can't just be a Log.write call.
Log.bootstrap("main.swift top-level code entered")

// The supported Phase 1+ entry points are:
//   - menu bar icon (always available, see StatusBarController)
//   - ⌘+Space (via KeyboardShortcuts, see HotkeyService)
//   - "settings" / "quit" as a search command (see CommandMatcher)
_ = AppLauncher.shared

/// File-based logger that survives release-build NSLog stripping and
/// SwiftPM executable target quirks. Writes to /tmp so it works regardless
/// of the app's actual working directory, sandbox state, or bundle
/// identity. The /tmp path is the LAST-RESORT diagnostic surface — when
/// everything else (print, NSLog, stderr) has failed, this still works.
///
/// IMPORTANT: any tool that wants to debug launch-time issues in a
/// SwiftPM .app should write its first message via `Log.bootstrap` (the
/// top of main.swift does this) — do NOT wait for class initialization,
/// because Swift 6 strict-concurrency + lazy static initialization has
/// subtle ordering bugs that can silently drop messages.
enum Log {
    /// Path is hardcoded to /tmp so the file is reachable whether the app
    /// is launched from Finder, Terminal, or via NSWorkspace.
    static let url: URL = URL(fileURLWithPath: "/tmp/aispotlight-app.log")

    /// Call this from the very first line of main.swift, before any
    /// framework setup. Uses the simplest possible mechanism (Data.write)
    /// and avoids the Log enum entirely, so even if the Log type fails to
    /// initialize for any reason, the message still lands on disk.
    static func bootstrap(_ msg: String) {
        let line = "\(Date()) [bootstrap] \(msg)\n"
        try? Data(line.utf8).write(to: url)
    }

    /// Writes a line to the log. Safe to call from any thread.
    static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let h = try? FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

final class AppLauncher: NSObject, NSApplicationDelegate {
    static let shared = AppLauncher()
    var panel: SpotlightPanel!
    var state: AppState!
    var settingsWindow: SettingsWindowController!

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

        // Phase 3.2.2: wire the AppKit-bridged extractors into the
        // Core IndexStore's dispatcher map. Without this, RTF/HTML
        // files would fall through to the plain-UTF-8 path and
        // return empty text.
        injectAppKitDispatchers()

        // Check Accessibility (do NOT prompt — that resets the grant
        // every launch. The user grants it once in System Settings; we just
        // verify.)
        let trusted = AXIsProcessTrusted()
        Log.write("accessibility trusted=\(trusted)")

        let settings = SettingsStore()
        // SettingsStore's @Published didSet has already written each field
        // to UserDefaults; we read the resolved config back from settings.
        let aiConfig = settings.resolveConfig()
        let ai = AIFactory.makeProvider(from: aiConfig)
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

        // Settings window — receives `.aispotlightOpenSettings` from the
        // menu bar menu AND from the "settings" search command. Mandatory
        // because `.accessory` apps have no standard App menu → Settings…
        // entry. Held as a strong reference in `self.settingsWindow` —
        // otherwise the NotificationCenter observer would be deallocated
        // and `.aispotlightOpenSettings` would silently do nothing.
        settingsWindow = SettingsWindowController()
        Log.write("settings window controller installed")

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

    /// Inject the AppKit-bridged text extractors into the Core
    /// IndexStore. Called once at startup so RTF/HTML files go
    /// through `RichTextExtractor` instead of falling through to
    /// the plain-UTF-8 path.
    ///
    /// This is a no-op when no IndexStore is wired up yet (3.1.5
    /// IndexManager is still on hold). Re-architect Phase 4.
    private func injectAppKitDispatchers() {
        // The Core IndexStore is created lazily when the IndexManager
        // runs. For now we expose the dispatcher map globally via a
        // static: the next IndexStore that gets created will copy
        // it. (Phase 4 will wire this properly.)
        AppLauncher.pendingDispatchers = RichTextExtensionDispatcher.defaults
        Log.write("AppKit dispatchers registered: \(RichTextExtensionDispatcher.defaults.count) extensions")
    }

    /// Stash for dispatcher registrations until an IndexStore is
    /// available. (Phase 3.x: IndexManager is on hold; once it
    /// returns, the IndexStore copies these into its own
    /// `dispatchers` map at init.)
    static var pendingDispatchers: [String: any ExtensionTextDispatcher] = [:]

    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let v = view else { return nil }
        if let tf = v as? NSTextField { return tf }
        for sub in v.subviews {
            if let tf = findTextField(in: sub) { return tf }
        }
        return nil
    }
}
