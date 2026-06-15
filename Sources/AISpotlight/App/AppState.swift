import Foundation
import AppKit
import Combine
import AISpotlightKit

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
         llmService: LLMConversationService? = nil) {
        self.interpreter = interpreter
        self.orchestrator = orchestrator
        self.llmService = llmService
    }

    func onQueryChange(_ newQuery: String) {
        // Debounce: cancel the previous search task but wait
        // ~600ms after the last keystroke before firing. The 600ms
        // is a balance: too short and we hammer the LLM with
        // intermediate queries; too long and the UI feels laggy.
        // Note: the in-flight LLM streaming call is also cancelled
        // by this — once the LLM starts streaming, the user's
        // keystrokes that change the query cancel the stream and
        // restart. That's intentional (matches Spotlight/Raycast
        // behavior) but means the LLM provider should be cheap
        // to cancel mid-stream (it is for Ollama).
        searchTask?.cancel()
        llmTask?.cancel()
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

        // Phase 4.1.5: if the user typed a free-form question
        // (Intent.ask), ask the LLM and stream the reply into
        // `llmReply`. The SwiftUI view shows the reply as a separate
        // section under the result list.
        if case .ask(let query, let contextURLs) = intent {
            Log.write("[AppState] Intent.ask detected: q=\(query.prefix(60)) contextURLs=\(contextURLs.count)")
            await runLLMAsk(query: query, contextURLs: contextURLs)
            // Phase 4.2: clear the input field after the ask is
            // dispatched, so the user sees the LLM reply in the
            // panel without the original question still in the
            // text field. Without this, the panel looks cluttered
            // (the user typed it, the LLM answered, but the
            // text field still shows the question). The debounce
            // already prevents re-firing on this same query.
            self.query = ""
        } else {
            // Non-ask query: clear any prior LLM state.
            llmReply = nil; llmError = nil
            Log.write("[AppState] Intent is not ask: \(intent)")
        }
    }

    // MARK: - LLM ask (Phase 4.1.5)

    /// Phase 4.1.5 + 4.1.6: fire a streaming ask to the LLM. Each
    /// chunk from the provider accumulates into `llmReply`, so
    /// the SwiftUI view can render the answer as it arrives.
    /// When the provider doesn't yet support true streaming
    /// (Phase 4.1.6 default impl), the entire reply arrives as
    /// a single chunk — same UX, no code change needed later.
    private func runLLMAsk(query: String, contextURLs: [URL]) async {
        guard let service = llmService else {
            // No LLM configured — show a clear message in the UI.
            Log.write("[AppState] runLLMAsk: NO llmService configured")
            llmReply = "(No AI provider configured. Open Settings to pick Ollama or a custom endpoint.)"
            return
        }
        Log.write("[AppState] runLLMAsk: starting streaming, q=\(query.prefix(60))")
        // Cancel any in-flight LLM call; only the most recent ask matters.
        llmTask?.cancel()
        isLLMBusy = true
        llmReply = ""
        llmError = nil

        llmTask = Task { [weak self] in
            do {
                let context = await LLMContext.from(urls: contextURLs)
                for try await chunk in service.askStreaming(query: query, context: context) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self?.llmReply = (self?.llmReply ?? "") + chunk
                    }
                }
                if Task.isCancelled { return }
                await MainActor.run { self?.isLLMBusy = false }
                Log.write("[AppState] runLLMAsk: stream done, llmReply length=\(self?.llmReply?.count ?? 0)")
            } catch {
                if Task.isCancelled { return }
                let errMsg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run {
                    self?.llmError = errMsg
                    self?.isLLMBusy = false
                }
                Log.write("[AppState] runLLMAsk ERROR: \(errMsg)")
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let cur = selection ?? 0
        let next = max(0, min(results.count - 1, cur + delta))
        selection = next
    }

    func activate() {
        guard let i = selection, results.indices.contains(i) else { return }
        let r = results[i]

        // Handle commands first — they don't go through NSWorkspace.
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

        NSWorkspace.shared.open(r.url)
        closePanel()
    }

    private func closePanel() {
        for w in NSApp.windows where w is SpotlightPanel {
            w.orderOut(nil)
        }
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
