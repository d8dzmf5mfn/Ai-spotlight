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

        // Phase 4.2.5: disable the LLMIntentRouter by default.
        // Every keystroke past the 0.6s debounce was firing a
        // separate LLM call to classify the intent (router ask,
        // 1-2s on Ollama gemma2:2b). For a user typing a 5-word
        // question, that's 5 redundant LLM calls, each one
        // risking Ollama crash. The rule-based QueryParser
        // handles the common cases (find X, open X, single-
        // token app lookup) — the LLM router is only useful
        // for free-form Chinese or other cases the rule parser
        // gives up on. We make the router opt-in via a
        // Settings toggle (Phase 4.2.6) — for now, default off
        // to keep the system stable.
        // let llmRouter: LLMIntentRouter? = ai.map { LLMIntentRouter(provider: $0) }
        let llmRouter: LLMIntentRouter? = nil
        let interpreter = QueryInterpreter(aiProvider: ai, llmRouter: llmRouter)

        // Phase 4.1.5: build the LLM conversation service. We use
        // the same `ai` instance — if the user picked Ollama, the
        // conversation goes to localhost:11434; if they picked
        // "custom" with an OpenAI-compatible URL, it goes there;
        // if they picked "none", this service exists but every
        // ask returns an error (handled gracefully by AppState).
        let llmService: LLMConversationService? = ai.map {
            LLMConversationService(provider: $0)
        }

        // Phase 4.2.10: removed the in-memory IndexStore entirely.
        // Both FileSystemProvider and ContentSearchProvider now
        // ask macOS Spotlight (mds daemon) via the MDQuery API.
        // We don't persist or build our own inverted index —
        // Spotlight already indexed every file on disk for us.
        // This drops the app's RSS from ~1.13GB to ~50MB at
        // 80k indexed files.

        // Build the orchestrator with all three providers.
        // ContentSearchProvider uses kMDItemTextContent under
        // the hood — no in-memory index, no mmap, no SQLite.
        let contentProvider = ContentSearchProvider()
        let orchestrator = SearchOrchestrator(providers: [
            FileSystemProvider(),
            AppProvider(),
            contentProvider,
        ])
        state = AppState(interpreter: interpreter, orchestrator: orchestrator, llmService: llmService)

        // Start indexing in the background after a short delay
        // Phase 4.2.10: removed the IndexManager initial-walk.
        // The old walk indexed files into our private in-memory
        // store. The new architecture uses macOS Spotlight
        // (mds daemon) which has been indexing the user's files
        // continuously since the OS was installed. There's
        // nothing for us to walk — the data is already there.
        //
        // We still log "initial index walk done" so the status
        // bar shows the same lifecycle as before, but the
        // actual work is a no-op now.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            Log.write("starting initial index walk (Spotlight already indexes for us)")
            Log.write("initial index walk done: scanned=0 indexed=0 skipped=0 (Spotlight handles this)")
        }

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
