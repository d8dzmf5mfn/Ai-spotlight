import Foundation
import AppKit
import Combine
import AISpotlightKit

/// What kind of LLM error is this? Drives the UI
/// buttons shown next to the error message.
public enum LLMErrorKind: Equatable, Sendable {
    /// Ollama was never started (or was started but is no
    /// longer reachable). Distinguished from idleExit /
    /// userQuit because the user may not have known they
    /// needed to start it. UI shows a "Start Ollama"
    /// button. Phase 4.2.6 default for -1004 when we have
    /// no recent user-quit signal.
    case ollamaNotRunning
    /// Ollama idle-unloaded itself (OLLAMA_KEEP_ALIVE=5m
    /// default). This is the most common case after the
    /// user has been away from the panel for a while.
    /// Same UI as ollamaNotRunning ("Start Ollama" button)
    /// but a different message that hints at the cause
    /// ("idle") so the user knows what's happening.
    case idleExit
    /// User explicitly quit Ollama (Cmd+Q, dock Quit,
    /// Activity Monitor Quit). Same UI as the other
    /// "not running" cases, message is "you quit it, click
    /// to relaunch".
    case userQuit
    /// Ollama crashed mid-response (-1005 'Network
    /// connection lost'). Often jetsam-killed on memory-
    /// constrained Macs running 12B+ models.
    case ollamaCrashed
    /// LLM timed out (-1001). Could be: model too large,
    /// prompt too long, GPU warmup, etc.
    case timeout
    /// Bad HTTP response (4xx/5xx). Could be: bad API key,
    /// bad model name, server error.
    case badResponse(String)
    /// Catch-all. UI just shows the message.
    case other(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var selection: Int? = 0
    @Published var isLoading: Bool = false
    @Published var placeholder: String = "Search files, apps, or ask AI…"
    @Published var emptyMessage: String = "Type to search."

    /// Phase 4.1.5: the LLM's streaming (or one-shot) reply to
    /// the user's question. Non-nil when an LLM ask is in flight or
    /// just completed. The SwiftUI view shows this as a separate
    /// panel under the result list.
    @Published var llmReply: String? = nil
    @Published var isLLMBusy: Bool = false
    @Published var llmError: String? = nil

    /// Phase 4.2.6: classified LLM error for UI rendering. When
    /// the error is `ollamaNotRunning`, the SwiftUI view shows
    /// a "Start Ollama" button next to the error text. Other
    /// cases (timeout, bad response, network lost) just show
    /// the friendly message — the user has to fix them in
    /// Settings or in their environment. We deliberately do NOT
    /// auto-restart Ollama (P2 architecture decision: Ollama is
    /// an external dependency service, not under our control).
    @Published var llmErrorKind: LLMErrorKind? = nil

    /// Phase 4.2.6 (P2): track the last time the Ollama.app
    /// process was terminated. We use this to disambiguate
    /// "user Cmd+Q quit" from "Ollama idle-unloaded itself"
    /// — both look identical from URLSession's perspective
    /// (Code=-1004 'Could not connect'). Listening to
    /// `NSWorkspace.didTerminateApplicationNotification`
    /// gives us the user-quit case; anything else within a
    /// short window of an -1004 is most likely Ollama's
    /// own `OLLAMA_KEEP_ALIVE` idle exit.
    private var lastOllamaQuit: Date? = nil
    private var lastOllamaQuitWasUserInitiated: Bool = false

    /// Phase 4.2.6: prior conversation turns, used to ground
    /// follow-up questions in the LLM. We keep this as a
    /// @Published so the SwiftUI view could (in a future
    /// iteration) show a chat history above the LLM reply.
    /// Capped at 12 messages (6 user + 6 assistant turns) in
    /// the LLMConversationService, but stored here unbounded
    /// so the cap is enforced at the boundary.
    @Published var llmHistory: [LLMConversationService.HistoryEntry] = []

    /// Phase 4.3.2: when true, the LLM has access to the
    /// tool registry and will call tools as needed. The user
    /// can disable this in Settings. Default true because
    /// tool use is the whole point of the "AI Spotlight" pitch.
    @Published var useTools: Bool = true

        /// Phase 4.3.2: the trace of tools the LLM used during the
    /// current ask. Each entry is "Used search_files: Found 5
    /// files matching polyester". The SwiftUI view shows this
    /// above the LLM reply so the user knows what the AI did.
    @Published var toolTrace: [String] = []

    /// Phase 4.4: file paths the LLM mentioned in its reply
    /// (e.g. "/Users/me/notes/polyester.md"). When the LLM
    /// answers "I found the file at /path/to/x.md", we extract
    /// the path and surface it as a clickable SearchResult so
    /// the user can press Enter to open it — no copy-paste
    /// and no "go find the file yourself" flow.
    @Published var llmReplyPaths: [URL] = []

    /// Phase 4.4: name of the tool currently running, if any.
    /// Set by runLLMAsk before the tool handler runs, cleared
    /// after. UI uses this to show "🔧 using search_files..."
    /// progress while the tool is in flight.
    @Published var currentToolName: String? = nil
    /// Phase 5-F: pending user-consent request for a tool call.
    /// When the LLM tries to call a `requiresConsent = true` tool,
    /// we set this tuple and the SearchWindowView shows a modal
    /// asking the user to approve or deny. The async continuation
    /// stored in `pendingConsentContinuation` is resumed when the
    /// user clicks Allow or Deny.
    @Published var pendingConsent: PendingConsent? = nil
    /// continuation to resume after the user picks Allow/Deny
    private var pendingConsentContinuation: CheckedContinuation<Bool, Never>? = nil
    public struct PendingConsent: Equatable, Sendable {
        public let tool: String
        public let args: String  // pre-formatted for display
    }

    /// Phase 4.3.2: the tool registry the LLM can call. Wired
    /// in from main.swift. Set to `nil` to disable tool use.
    private let toolRegistry: LLMToolRegistry

    private let interpreter: QueryInterpreter
    private let orchestrator: SearchOrchestrator
    /// Optional LLM conversation service. Nil when the user picked
    /// "none" in Settings. The search pipeline still works without
    /// it; LLM-driven paths (Intent.ask) just gracefully fall back.
    private let llmService: LLMConversationService?
    private var searchTask: Task<Void, Never>?
    private var llmTask: Task<Void, Never>?
    private var debounceTimer: Timer?

    init(interpreter: QueryInterpreter,
         orchestrator: SearchOrchestrator,
         llmService: LLMConversationService? = nil,
        toolRegistry: LLMToolRegistry = LLMToolRegistry()) {
        self.interpreter = interpreter
        self.orchestrator = orchestrator
        self.llmService = llmService
        self.toolRegistry = toolRegistry
        // Phase 4.2.6 (P2): listen for Ollama.app termination.
        // We use NSWorkspace's notification center to detect when
        // the user explicitly Cmd+Q's Ollama (or quits it via
        // the dock). The idle-unload case (OLLAMA_KEEP_ALIVE=5m)
        // does NOT fire this notification — it just makes the
        // process exit. So we use this to disambiguate.
        //
        // We intentionally do NOT use this for auto-restart.
        // Even if the user Cmd+Q'd Ollama, the right thing is to
        // show a "Start Ollama" button, not to silently relaunch
        // a process the user just quit. See the architecture
        // decision in `.hermes/4.2.5-open-bugs.md` Bug #5.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleOllamaAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        // The notification observer is auto-removed when self
        // is deallocated (we passed self as the observer), so
        // we don't need to call removeObserver manually.
    }

    /// NSWorkspace.didTerminateApplicationNotification handler.
    /// Marked @objc because the selector must be ObjC-compatible.
    /// Only fires for user-initiated quits (Cmd+Q, dock "Quit",
    /// Activity Monitor "Quit Process") — does NOT fire for the
    /// OLLAMA_KEEP_ALIVE idle unload, which is a clean exit
    /// from the process's perspective.
    @objc private func handleOllamaAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.ollama.Ollama" else {
            return
        }
        // The user explicitly quit Ollama. Record the time so
        // the next -1004 in runLLMAsk can be classified as
        // .userQuit instead of .idleExit.
        Self.lastOllamaQuitTimestamp = Date()
        Self.lastOllamaQuitWasUserInitiated = true
        Log.write("[AppState] Ollama.app terminated by user (bundleID=\(app.bundleIdentifier ?? "?"))")
    }

    func onQueryChange(_ newQuery: String) {
        // Debounce: cancel the previous search task but wait
        // ~600ms after the last keystroke before firing.
        //
        // IMPORTANT: we do NOT cancel llmTask here. The
        // previous Phase 4.2.x design cancelled the in-flight
        // LLM task on every keystroke, but the user-pinned
        // bug here is that NSTextField fires
        // `controlTextDidChange` on the SAME tick as the Enter
        // command (the panel-clear/empty-string path), which
        // races with the LLM task just spawned by activate().
        // The LLM task gets cancelled before URLSession can
        // even throw its first -1004, so the catch block in
        // AppState.runLLMAsk never runs and the user sees a
        // blank panel. The LLM is its own commit-gated action;
        // it should only be cancelled by an explicit
        // "user pressed Enter on a new ask" path, not by
        // every keystroke. We let it run to completion (or
        // its own error) — and a subsequent runLLMAsk will
        // bump llmGeneration, making the old task's
        // generation check fail and discarding its results.
        searchTask?.cancel()
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.searchTask = Task { await self.runSearch(newQuery) }
        }
    }

    private func runSearch(_ q: String) async {
        isLoading = true; defer { isLoading = false }

        // Special commands bypass the regular search/AI pipeline. We check
        // them first so they work even when "settings" matches some file
        // by the same name on disk.
        if let command = CommandMatcher.match(q) {
            results = [SearchResult.command(command: command)]
            selection = 0
            // Clear any previous LLM state when the user types a command
            llmReply = nil; llmError = nil
            return
        }

        let intent = await interpreter.interpret(q)
        let r = await orchestrator.run(intent: intent)
        if !Task.isCancelled {
            self.results = r
            self.selection = r.isEmpty ? nil : 0
        }

        // Phase 4.2.x + 4.2.5: populate the LLM context
        // candidate URLs. When the user types a question-style
        // query, we save the top file matches so the eventual
        // LLM ask (when the user presses Enter) can ground its
        // reply in those file contents. This is the "B" use
        // case: 'tell me about polyester' → search finds
        // polyester notes → Enter → LLM reads them → reply.
        //
        // For non-ask queries (find/open), we clear the
        // context list — the user wants files, not LLM
        // interpretation.
        if case .ask = intent {
            // Take up to 5 file/app results as context. We
            // don't filter by kind — the LLM can decide
            // whether a result is relevant from the user's
            // question. 5 is a reasonable upper bound
            // (16 KB per file * 5 = 80 KB of context, well
            // under any LLM's limit).
            lastSearchContextURLs = r.prefix(5).map { $0.url }
        } else {
            lastSearchContextURLs = []
        }
        if case .ask = intent {
            // Keep llmReply/llmError as-is so the AI section
            // header is visible but the body is empty until
            // the user commits with Enter.
        } else {
            // Non-ask query: clear any prior LLM state.
            llmReply = nil; llmError = nil
            lastSearchContextURLs = []
        }
        Log.write("[AppState] runSearch done for q=\(q.prefix(60)), will NOT auto-ask, results=\(r.count)")
    }

    /// The file URLs to pass as context to the next LLM
    /// ask. Populated by runSearch when the user types an
    /// ask-style query and the file search returns matches.
    /// Consumed by runLLMAsk (when the user presses Enter)
    /// to ground the LLM's reply in the file content.
    private var lastSearchContextURLs: [URL] = []

    // MARK: - LLM ask (Phase 4.1.5 + 4.2.x)

    /// Fire an ask to the LLM. The reply (or error) is published
    /// to `llmReply` / `llmError` so the SwiftUI view updates live.
    /// If the user typed a second ask before the first finished, we
    /// cancel the in-flight task — only the most recent question
    /// gets a reply.
    ///
    /// Phase 4.2.x error friendliness:
    /// - NSURLError Code=-1004 (could not connect) — most likely
    ///   Ollama isn't running. We translate to a clear "Ollama
    ///   not running at localhost:11434" message so the user
    ///   knows what to do.
    /// - Other errors (HTTP 4xx/5xx, JSON decode) — show the
    ///   raw error.
    ///
    /// Phase 4.2.x (external review): the previous implementation
    /// had two problems that made errors vanish silently:
    /// 1. The default `askStreaming` impl in `AIProvider.swift`
    ///    wrapped `self.ask(...)` in an unstructured `Task`
    ///    inside the `AsyncThrowingStream` init. When `ask`
    ///    threw synchronously (URLSession's NSURLError -1004
    ///    for Ollama being offline), `continuation.finish(throwing:)`
    ///    ran BEFORE the consumer's `for try await` was even
    ///    attached. The error was silently dropped — the stream
    ///    just terminated "normally" with zero chunks, the
    ///    success-path log fired, and the catch block never
    ///    ran.
    /// 2. The `for try await` body had a `Task.isCancelled`
    ///    check that early-returned on cancel, skipping the
    ///    catch block entirely and leaving `isLLMBusy` stuck
    ///    at true.
    /// Both are fixed:
    /// 1. `AIProvider.askStreaming` now wires `continuation.onTermination`
    ///    to the producer Task, so cancellation propagates
    ///    cleanly and the stream's internal buffer reliably
    ///    carries the terminal error to the consumer.
    /// 2. The for-loop body has NO cancellation check — the
    ///    catch block always runs.
    private func runLLMAsk(query: String, contextURLs: [URL]) async {
        guard let service = llmService else {
            Log.write("[AppState] runLLMAsk: NO llmService configured")
            llmReply = "(No AI provider configured. Open Settings to pick Ollama or a custom endpoint.)"
            return
        }
        Log.write("[AppState] runLLMAsk: starting, q=\(query.prefix(60)), useTools=\(useTools)")
        llmGeneration += 1
        let currentGeneration = llmGeneration
        let historySnapshot = llmHistory
        llmTask?.cancel()
        isLLMBusy = true
        llmReply = ""
        llmError = nil
        toolTrace = []
        llmReplyPaths = []
        currentToolName = nil

        // Phase 4.3.2: when useTools is true, take the tool
        // path. We optimistically dispatch to askWithTools
        // regardless of whether the registry actually has
        // any tools — if it's empty, the loop just returns
        // the LLM's plain text answer without making any
        // tool calls. Cheaper than an await + isEmpty check
        // at the gate, and the wire-time cost is identical.
        if useTools {
            llmTask = Task { [weak self] in
                do {
                    let context = await LLMContext.from(urls: contextURLs)
                    let result = try await service.askWithTools(
                        query: query,
                        history: historySnapshot,
                        context: context,
                        registry: toolRegistry,
                        maxToolTurns: 2
                    ) { toolName in
                        // Phase 4.4: set the current tool name
                        // so the UI can show a "🔧 using X..."
                        // progress indicator. Cleared when the
                        // loop returns (or the catch block fires).
                        await MainActor.run {
                            guard let self, self.llmGeneration == currentGeneration else { return }
                            self.currentToolName = toolName
                        }
                    } onConsentNeeded: { tool, args in
                        // Phase 5-F: ask the user to confirm a
                        // requiresConsent tool call. The dialog
                        // is presented by SearchWindowView via
                        // the published pendingConsent state.
                        // We suspend until the user clicks
                        // Allow or Deny, then resume.
                        return await self?.requestUserConsent(
                            tool: tool, args: args
                        ) ?? false
                    }
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard let self, self.llmGeneration == currentGeneration else { return }
                        self.toolTrace = result.toolCalls.map { call in
                            "🔧 \(call.tool): \(call.summary)"
                        }
                        self.llmReply = result.finalAnswer
                        // Phase 4.4: extract any file paths the LLM
                        // mentioned in its reply, so the user can
                        // press Enter to open them.
                        self.llmReplyPaths = Self.extractPaths(from: result.finalAnswer)
                        self.currentToolName = nil
                        self.isLLMBusy = false
                        self.llmHistory.append(.init(role: .user, text: query))
                        self.llmHistory.append(.init(role: .assistant, text: result.finalAnswer))
                        if self.llmHistory.count > 12 {
                            self.llmHistory.removeFirst(self.llmHistory.count - 12)
                        }
                    }
                    Log.write("[AppState] runLLMAsk: tool flow done, toolCalls=\(result.toolCalls.count), replyLength=\(result.finalAnswer.count)")
                } catch {
                    let classified = Self.classifyLLMError(error)
                    let errMsg = classified.message
                    await MainActor.run {
                        guard let self, self.llmGeneration == currentGeneration else { return }
                        self.currentToolName = nil
                        if Self.isURLCancelled(error) {
                            self.isLLMBusy = false
                        } else {
                            self.llmError = errMsg
                            self.llmErrorKind = classified.kind
                            self.isLLMBusy = false
                        }
                    }
                    Log.write("[AppState] runLLMAsk ERROR: \(errMsg)")
                }
            }
            return
        }

        // Streaming path (no tools).
        llmTask = Task { [weak self] in
            do {
                let context = await LLMContext.from(urls: contextURLs)
                for try await chunk in service.askStreamingWithHistory(query: query, history: historySnapshot, context: context) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard let self, self.llmGeneration == currentGeneration else { return }
                        self.llmReply = (self.llmReply ?? "") + chunk
                    }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.llmGeneration == currentGeneration else { return }
                    self.llmError = nil
                    self.llmErrorKind = nil
                    self.isLLMBusy = false
                    self.llmHistory.append(.init(role: .user, text: query))
                    self.llmHistory.append(.init(role: .assistant, text: self.llmReply ?? ""))
                    if self.llmHistory.count > 12 {
                        self.llmHistory.removeFirst(self.llmHistory.count - 12)
                    }
                }
                Log.write("[AppState] runLLMAsk: stream done, llmReply length=\(self?.llmReply?.count ?? 0), historyCount=\(self?.llmHistory.count ?? 0)")
            } catch {
                let classified = Self.classifyLLMError(error)
                let errMsg = classified.message
                let errKind = classified.kind
                await MainActor.run {
                    guard let self, self.llmGeneration == currentGeneration else { return }
                    if Self.isURLCancelled(error) {
                        self.isLLMBusy = false
                    } else {
                        self.llmError = errMsg
                        self.llmErrorKind = errKind
                        self.isLLMBusy = false
                    }
                }
                Log.write("[AppState] runLLMAsk ERROR: \(errMsg)")
            }
        }
    }



    /// Monotonic counter that lets us ignore the outcome of a
    /// cancelled-but-still-running LLM task. Without this, a
    /// slow Ollama response that arrives AFTER the user has
    /// already pressed Enter on a new ask could clobber the
    /// new ask's state. See the generation check in
    /// `runLLMAsk`'s Task closure.
    private var llmGeneration: Int = 0

    /// Translate raw URLSession / HTTP errors into both a
    /// user-facing message AND a classification (`LLMErrorKind`)
    /// that the SwiftUI view uses to render the right action
    /// (e.g. a "Start Ollama" button for `ollamaNotRunning`).
    ///
    /// NSURLError Code=-1004 ("Could not connect to the server")
    /// on localhost:11434 almost certainly means Ollama isn't
    /// running — that's the 90% case and we should call it out.
    /// Distinguishing "user Cmd+Q quit" from "Ollama idle
    /// unloaded itself" requires P2's NSWorkspace notification
    /// listener; until that lands, both surface as
    /// `.ollamaNotRunning` with the same message. Once P2
    /// ships, we'll refine the message based on the recorded
    /// reason.
    static func classifyLLMError(_ error: Error) -> (kind: LLMErrorKind, message: String) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case -1004: // Could not connect
                // This is the trickiest case to classify
                // because three different reasons produce the
                // same NSURLError -1004:
                //   1. User Cmd+Q'd Ollama.app
                //   2. Ollama idle-unloaded itself
                //      (OLLAMA_KEEP_ALIVE=5m default)
                //   3. Ollama was never started
                //
                // The AppState singleton tracks the last
                // user-initiated quit (P2 NSWorkspace
                // listener). If the last quit was within the
                // last 10 seconds, attribute this to a
                // user-initiated quit. Otherwise, assume
                // idle-unload (the much more common case after
                // the user has been away from the panel for a
                // while).
                //
                // Note: the AppState cannot be a parameter to
                // a static method without a singleton; we
                // use a type-level static for the timestamp
                // so the same classification logic applies
                // everywhere. This is the P2 architecture.
                if let quitTime = lastOllamaQuitTimestamp,
                   Date().timeIntervalSince(quitTime) < 10 {
                    return (.userQuit, "Ollama was quit. Click Start Ollama to relaunch it.")
                }
                return (.idleExit, "Ollama stopped after being idle. Click Start Ollama to relaunch it, or increase OLLAMA_KEEP_ALIVE in Ollama settings.")
            case -1005: // Network connection lost
                // Distinct from -1004: this means the connection
                // WAS up and then died — usually Ollama crashed
                // (often jetsam-killed on a memory-constrained Mac
                // when running a 12B+ model). The user-visible
                // message distinguishes the two cases so they
                // know to check `ollama ps` and possibly pick
                // a smaller model.
                return (.ollamaCrashed, "Ollama crashed mid-response (often due to running a model too large for your Mac's RAM). Try a smaller model in Settings, or restart Ollama.")
            case -1001: // Timed out
                return (.timeout, "LLM timed out. The model may be too large for your Mac, or the prompt was too long.")
            case -1003: // Host not found
                return (.other("LLM host not found. Check Settings → AI Provider."), "LLM host not found. Check Settings → AI Provider.")
            case -999:  // Cancelled (user or new ask interrupted us)
                return (.other(""), "")
            default:
                return (.other("LLM connection error (\(nsError.code)): \(error.localizedDescription)"), "LLM connection error (\(nsError.code)): \(error.localizedDescription)")
            }
        }
        if let aiError = error as? AIProviderError {
            let msg = aiError.errorDescription ?? "AI provider error"
            return (.badResponse(msg), msg)
        }
        return (.other(error.localizedDescription), error.localizedDescription)
    }

    /// Type-level timestamp of the last user-initiated Ollama
    /// quit (Cmd+Q, dock "Quit", Activity Monitor "Quit").
    /// Set by `handleOllamaAppTerminated` in the AppState
    /// init. We use a type-level static rather than an
    /// instance property so the static `classifyLLMError`
    /// method can read it without threading an AppState
    /// reference through every call site.
    ///
    /// This is global mutable state — the same anti-pattern
    /// we'd warn against in a multi-instance app. But AI
    /// Spotlight has exactly one AppState (singleton pattern
    /// via main.swift), so it's fine in practice.
    private static var lastOllamaQuitTimestamp: Date? = nil
    private static var lastOllamaQuitWasUserInitiated: Bool = false

    /// True for the URLSession "this request was cancelled"
    /// NSURLError Code=-999, NOT as a Task cancellation
    /// directly. The `Task.isCancelled` flag is set earlier
    /// (we get a heads-up via that), but the actual error
    /// thrown into our catch block is the URL error.
    private static func isURLCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == -999 {
            return true
        }
        // CocoaError(.userCancelled) is the other path URLSession
        // can take.
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelledError {
            return true
        }
        return false
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let cur = selection ?? 0
        let next = max(0, min(results.count - 1, cur + delta))
        selection = next
    }

    /// Called when the user presses Enter in the search field.
    /// Priority: a selected search result wins over a free-form
    /// LLM question, matching Spotlight / Raycast behavior.
    ///
    /// Phase 4.2.x rationale:
    /// 1. If the user has highlighted a result (arrow keys) and
    ///    presses Enter, open that result. This is the
    ///    Spotlight expectation.
    /// 2. If there's no result (e.g. they typed a free-form
    ///    question that produced no file match), AND the
    ///    intent is .ask, fire the LLM.
    /// 3. Otherwise, fall back to opening the first result
    ///    (or do nothing if results is empty).
    ///
    /// Without the "selected result wins" rule, the user
    /// would type 'tell me about polyester' — see
    /// 'polyester.md' appear in the result list — and then
    /// press Enter expecting to open the file, only to
    /// silently trigger the LLM. That's a bad Spotlight
    /// emulation. The current rule fixes that.
    func activate() async {
        // Phase 5-E: if there's a pending debounce timer
        // from the last keystroke, fire the search NOW
        // instead of waiting 600ms. Without this, the user
        // types "settings" and presses Enter immediately —
        // the debounce hasn't fired yet, runSearch hasn't
        // populated the command result, selection is nil,
        // and the LLM interprets "settings" as an AI query.
        if let timer = debounceTimer, timer.isValid {
            let q = self.query
            timer.invalidate()
            debounceTimer = nil
            // Run the search synchronously before checking
            // selection. This is a fire-and-forget within
            // activate() — the search task will update
            // self.results before the guard-let below reads
            // it, because runSearch awaits and the actor
            // serializes access to self.
            searchTask?.cancel()
            searchTask = Task { await self.runSearch(q) }
            _ = await searchTask?.value
        }
        // Priority 1: a highlighted result always wins.
        if let i = selection, results.indices.contains(i) {
            let r = results[i]
            // Command pseudo-results (settings, quit) take
            // the same path as before.
            if let cmd = r.command {
                switch cmd {
                case .openSettings:
                    NotificationCenter.default.post(name: .aispotlightOpenSettings, object: nil)
                case .quit:
                    NSApp.terminate(nil)
                }
                closePanel()
                return
            }
            // Open the file/app via NSWorkspace, but only close
            // the panel if the LLM isn't currently streaming a
            // reply. When the LLM is busy, the user wants to see
            // the streaming reply, not have the panel slam shut
            // mid-token. They can dismiss the panel manually
            // with Esc once the LLM finishes.
            //
            // Without this guard, opening a file from the result
            // list while an LLM ask is in flight would steal the
            // LLM reply from the user — they'd see the file
            // open (good) but the LLM reply would stream into a
            // panel that's no longer visible.
            NSWorkspace.shared.open(r.url)
            if !isLLMBusy {
                closePanel()
            }
            return
        }

        // Priority 2: no selection, ask intent → fire LLM.
        let intent = await interpreter.interpret(query)
        switch intent {
        case .ask(let q, let contextURLs):
            // Phase 4.2.5: use the candidate file URLs
            // populated by runSearch (top-5 matches from
            // the most recent typing session) as the LLM
            // context. If the user hasn't typed anything
            // that would produce file matches, this is
            // empty and the LLM gets a general-knowledge
            // prompt.
            let urls = !lastSearchContextURLs.isEmpty
                ? lastSearchContextURLs
                : contextURLs
            Log.write("[AppState] activate: ask intent, q=\(q.prefix(40)), contextURLs=\(urls.count)")
            await runLLMAsk(query: q, contextURLs: urls)
            self.query = ""
            return
        case .openApp(let name):
            // Single-word query that the rule parser (or
            // router) classified as an app. If the user pressed
            // Enter, the AppProvider has already shown results;
            // if they didn't pick one (results is empty),
            // fall back to asking the LLM. This makes
            // 'hello' / 'random gibberish' fall into the
            // LLM rather than appearing to do nothing.
            if results.isEmpty {
                Log.write("[AppState] activate: openApp '\(name)' with no match, falling back to LLM ask")
                await runLLMAsk(query: query, contextURLs: [])
                self.query = ""
                return
            }
        case .findFile:
            // The rule parser classified the query as a
            // file-find ('find X' / 'where is report.pdf' /
            // 'the polyester thing I mentioned'). If
            // results is empty, fall back to the LLM —
            // the user's follow-up question may rely on
            // context from the prior turn ('the AI
            // Spotlight I mentioned before') that the
            // rule parser can't see, and the LLM is the
            // only thing that can interpret it.
            //
            // This is the third arm of "Enter fallback" —
            // paired with the .ask and .openApp arms
            // above. Without it, follow-up questions
            // starting with 'find' or 'where' would
            // silently no-op whenever the file isn't on
            // disk.
            if results.isEmpty {
                Log.write("[AppState] activate: findFile with no match, falling back to LLM ask")
                await runLLMAsk(query: query, contextURLs: lastSearchContextURLs)
                self.query = ""
                return
            }
        default:
            break
        }

        // Priority 3: no selection, no ask intent, no usable
        // openApp. Do nothing — the user can pick a result, keep
        // typing, or press Escape. (Future: play a subtle 'no
        // result' cue.)
        Log.write("[AppState] activate: no selection and no ask intent, doing nothing")
    }

    private func closePanel() {
        for w in NSApp.windows where w is SpotlightPanel {
            w.orderOut(nil)
        }
    }

    /// Phase 4.4: scan an LLM reply for absolute file paths.
    /// The LLM often writes things like "see /Users/me/foo.md
    /// for the chemistry notes" — we want the user to be
    /// able to open that file with one click. The regex is
    /// deliberately permissive: it matches /Users/... or
    /// /private/var/... or /tmp/... paths. We filter by
    /// fileExists so prose like "/usr/bin/foo" (just text,
    /// not a real file) is dropped.
    static func extractPaths(from text: String) -> [URL] {
        let pattern = #"(/[A-Za-z0-9_./-]{2,200}?[A-Za-z0-9_-])(?=[\s,;)\]>]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var paths: [URL] = []
        var seen: Set<String> = []
        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let s = String(text[r])
            if seen.contains(s) { continue }
            guard FileManager.default.fileExists(atPath: s) else { continue }
            seen.insert(s)
            paths.append(URL(fileURLWithPath: s))
            if paths.count >= 8 { break }
        }
        return paths
    }

    /// Phase 4.4: user-initiated open of a file path the
    /// LLM mentioned. We use NSWorkspace directly so the
    /// panel's current results list isn't disturbed.
    func openLLMReplyPath(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Phase 5-F: show a consent dialog for a requiresConsent
    /// tool call. Suspends on an async continuation until
    /// the user clicks Allow or Deny in the dialog (which
    /// resumes via `respondToConsent(approved:)`).
    @MainActor
    func requestUserConsent(tool: String, args: [String: String]) async -> Bool {
        // Format the args for display. We don't show the
        // full arg dump — just the first 2 keys with their
        // truncated values, since most tools have 1-2
        // meaningful args.
        let argDescription: String
        if args.isEmpty {
            argDescription = "(no arguments)"
        } else {
            let lines = args.sorted { $0.key < $1.key }.prefix(2).map { (k, v) in
                let truncated = v.count > 60 ? String(v.prefix(60)) + "…" : v
                return "  \(k): \(truncated)"
            }
            argDescription = lines.joined(separator: "\n")
        }
        pendingConsent = PendingConsent(tool: tool, args: argDescription)
        // The continuation is set up by SearchWindowView
        // when it observes pendingConsent = ... and is
        // resumed by respondToConsent.
        return await withCheckedContinuation { cont in
            self.pendingConsentContinuation = cont
        }
    }

    /// Called by the consent dialog when the user clicks
    /// Allow or Deny. Resumes the suspended askWithTools
    /// loop with the user's decision.
    @MainActor
    func respondToConsent(approved: Bool) {
        guard let cont = pendingConsentContinuation else { return }
        pendingConsentContinuation = nil
        pendingConsent = nil
        cont.resume(returning: approved)
    }
}

/// `Command` and `CommandMatcher` are defined in AISpotlightKit/Command.swift.
/// This extension just adds the `SearchResult.command(command:)` factory
/// that wraps a `Command` into a pseudo-result for the result list.

extension SearchResult {
    /// Pseudo-result used for built-in commands. The `title` doubles as the
    /// display label in the result list; `command` carries the actual
    /// `Command` enum so the activator doesn't have to parse the URL.
    static func command(command: Command) -> SearchResult {
        let label: String
        let icon: String
        switch command {
        case .openSettings: label = "Open AI Spotlight Settings"; icon = "gear"
        case .quit:         label = "Quit AI Spotlight";          icon = "power"
        }
        return SearchResult(
            title: label,
            subtitle: "Built-in command",
            iconSystemName: icon,
            url: URL(string: "aispotlight://command/\(command)")!,
            kind: .command,
            score: 1.0,
            command: command
        )
    }
}
