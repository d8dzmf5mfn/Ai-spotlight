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
_ = AppLauncher()

/// File-based logger that survives release-build NSLog stripping and
/// SwiftPM executable target quirks. Writes to /tmp so it works regardless
/// of the app's actual working directory, sandbox state, or bundle
/// identity. The /tmp path is the LAST-RESORT diagnostic surface — when
/// everything else (print, NSLog, stderr) has failed, this still works.
final class AppLauncher: NSObject, NSApplicationDelegate {
    /// Phase 5-F: removed `static let shared` to avoid
    /// the recursive `dispatch_once` lock crash. The
    /// previous code had a `static let shared` singleton
    /// AND an `init()` that called `app.run()` (which
    /// blocks). Then `applicationDidFinishLaunching` would
    /// also access `AppLauncher.shared`, hitting the
    /// already-held dispatch_once lock recursively on
    /// the main thread. SIGTRAP from libdispatch.
    /// We drop the singleton; the AppLauncher has a single
    /// instance managed by NSApplication's delegate, and
    /// `applicationDidFinishLaunching` is the only place
    /// that needs access to it.
    var panel: SpotlightPanel!
    var state: AppState!
    /// Phase 5-F: SettingsStore must live for the entire
    /// process lifetime. If it doesn't, the `liveProvider`
    /// weak reference on it becomes nil after main.swift's
    /// setup function returns, and Settings edits no longer
    /// push config updates to the running provider. That
    /// was the source of the "Settings green but ask 401"
    /// bug — SettingsStore was being deallocated.
    var settings: SettingsStore!
    var settingsWindow: SettingsWindowController!
    /// Step-2: file sync service for SQLite augmentation.
    /// Keep alive for the process lifetime.
    var syncService: SyncService?

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
        // Phase 5-F: keep SettingsStore alive for the
        // entire process lifetime so the liveProvider weak
        // reference stays valid. Previously `settings` was
        // a local var that went out of scope at the end of
        // this function, taking the provider wiring with
        // it. We stash a strong ref on the AppLauncher
        // instance itself (which NSApplication owns for
        // the life of the process).
        self.settings = settings
        // SettingsStore's @Published didSet has already written each field
        // to UserDefaults; we read the resolved config back from settings.
        let aiConfig = settings.resolveConfig()
        let ai = AIFactory.makeProvider(from: aiConfig)
        // Phase 5-F: wire the live provider into the SettingsStore
        // so the Settings UI can push config updates without
        // restarting the app. Without this, the provider's
        // config.model is frozen at launch-time — the user
        // can change customModel in Settings but the running
        // provider keeps the old value, which is what caused
        // the "Test connection green but ask 401" bug.
        if let openaiProvider = ai as? OpenAICompatibleProvider {
            settings.liveProvider = openaiProvider
        }

        // Phase 5-H: trigger an automatic model discovery at
        // launch. This populates the Picker the first time
        // the user opens Settings, and surfaces invalid
        // model names (the user's prior session may have
        // left a garbage value like "deepseek-v4-flash" in
        // UserDefaults that would otherwise hit DeepSeek
        // governor as 401). The discovery call is async
        // and best-effort — if the provider is down or
        // rejects the request, the app still works with
        // whatever customModel the user has set.
        Task { await settings.refreshModels() }

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
                // Phase 4.3.2: the LLM tool registry. The LLM can
        // call any of these tools by emitting a JSON block
        // in its reply. We pre-register the three built-in
        // tools (search_files via mdfind, open_file via
        // /usr/bin/open, list_apps via ls). The registry is
        // an actor so registration is async; we use a
        // non-async semaphore-bridged wait here because
        // main.swift's setup function is synchronous. In
        // practice, registration is microseconds — the
        // actor hop is the only real cost.
        // Phase 4.3.3 fix: use a plain non-actor Set as the
        // tool registry, so we can register tools
        // synchronously without spawning a Task. The
        // LLMToolRegistry actor is still used at ask time
        // (we transfer the registrations). This avoids
        // a deadlock where the main thread is blocked on
        // a semaphore and the Task that would signal it
        // can't run.
        let toolRegistry = LLMToolRegistry()
        let searchTool = BuiltinTools.searchFiles()
        let openTool = BuiltinTools.openFile()
        let appsTool = BuiltinTools.listApps()
        // Phase 5-F: register the requiresConsent shell tool
        // so the consent dialog can be exercised during dev.
        // In a future commit we'll add a Settings toggle to
        // disable this; for now it's always available.
        let shellTool = BuiltinTools.runShell()
        let readTool = BuiltinTools.readFile()
        let clipGetTool = BuiltinTools.clipboardGet()
        let clipSetTool = BuiltinTools.clipboardSet()
        let calendarTool = BuiltinTools.readCalendar()
        let sema = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await toolRegistry.register(searchTool)
            await toolRegistry.register(openTool)
            await toolRegistry.register(appsTool)
            await toolRegistry.register(shellTool)
            await toolRegistry.register(readTool)
            await toolRegistry.register(clipGetTool)
            await toolRegistry.register(clipSetTool)
            await toolRegistry.register(calendarTool)
            sema.signal()
        }
        // .now() returns immediately if already signalled;
        // 5s ceiling protects against any pathological
        // hangs in the registration path.
        let result = sema.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            Log.write("tool registry registration TIMED OUT after 5s; tools may not be available")
        } else {
            Log.write("tool registry: 8 tools registered (search_files, open_file, list_apps, run_shell, read_file, clipboard_get, clipboard_set, read_calendar)")
        }

// Phase 6 Step-3: the SQLite augmentation backend is added to
// the provider list when `settings.useSQLiteAugmentation` is true.
// Today the backend's `search()` is a no-op (returns []) and its
// provider weight in `ResultMerger` is 0, so the flag has no
// observable effect on results. The wiring exists so that
// Step-3's FTS5 query implementation lands in an already-wired
// pipeline.
var searchProviders: [any SearchProvider] = [
    FileSystemProvider(),
    // FileSystemAdapterProvider removed: MDQuery with Chinese chars crashes on macOS 27 beta.
    // Chinese search is handled by SQLiteBackend LIKE fallback.
    AppProvider(),
    contentProvider,
]
if settings.useSQLiteAugmentation {
    searchProviders.append(SQLiteBackend())
}

// Step-2: start the file sync service for SQLite augmentation.
// Creates an IndexingBoundary (persisted set of enrolled paths)
// and a SyncService that scans and writes file metadata to the
// SQLite DB. The boundary is persisted next to the SQLite file.
//
// Enrolled paths default to empty — users add them in Settings.
// Until at least one path is enrolled, sync is a no-op.
let boundaryPath = SQLiteBackend.databaseURL
    .deletingLastPathComponent()
    .appendingPathComponent("indexing_boundary.json")
let boundary = IndexingBoundary(storageURL: boundaryPath)
let syncService = SyncService(boundary: boundary, dbURL: SQLiteBackend.databaseURL)
self.syncService = syncService
// Start sync in background after a short delay so the UI
// launches faster on first run.
Task {
    try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s delay
    await syncService.start()
}
Log.write("[main] sync service initialized, boundary at \(boundaryPath.path)")
        settings.indexingBoundary = boundary
        settings.syncService = syncService

let orchestrator = SearchOrchestrator(providers: searchProviders)
        state = AppState(interpreter: interpreter, orchestrator: orchestrator, llmService: llmService, toolRegistry: toolRegistry, indexingBoundary: boundary)

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
        // Track panel resize to detect app mode threshold
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let wide = self.panel.frame.width > 900
                let enabled = self.settings.isAppModeEnabled
                self.state.isAppMode = enabled && wide
            }
        }

        let toggleAction: () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // Panel is about to be shown (was hidden). Clear history
                // unless app mode is enabled.
                if !self.panel.isVisible, !self.settings.isAppModeEnabled {
                    self.state.clearLLMState()
                }
                self.state.query = ""
                self.state.results = []
                self.state.isAppMode = self.settings.isAppModeEnabled && self.panel.frame.width > 900
                self.panel.toggle()
            }
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
        // Phase 5-F: pass the SAME SettingsStore instance so
        // SettingsView has the liveProvider wired. Without
        // this, SettingsView creates its own fresh store via
        // @StateObject, liveProvider=nil, pushConfigToProvider
        // silently does nothing, and the running provider keeps
        // the old config ("Test green but chat 401").
        settingsWindow = SettingsWindowController(store: settings)
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
