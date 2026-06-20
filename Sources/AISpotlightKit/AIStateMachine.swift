import Foundation
import Combine

// MARK: - AI State Definition

/// The canonical state of the AI subsystem. Every UI component
/// binds to this; no component decides its own visibility.
public enum AIState: Equatable, Sendable {
    /// No activity. Panel shows placeholder.
    case idle
    /// A file/spotlight search is in flight.
    case searching(query: String)
    /// Background indexer is scanning or watching.
    case indexing(progress: Double?)
    /// LLM is generating a response (streaming or tool-using).
    case thinking(toolName: String?)
    /// LLM has produced a reply and is displaying it.
    case responding(reply: String)
    /// An error occurred (Ollama offline, HTTP 401, timeout, …).
    case error(kind: String?, message: String)

    public var shortLabel: String {
        switch self {
        case .idle:               return "idle"
        case .searching:          return "searching"
        case .indexing:           return "indexing"
        case .thinking:           return "thinking"
        case .responding:         return "responding"
        case .error:              return "error"
        }
    }

    /// True when the panel should show a spinner.
    public var isBusy: Bool {
        switch self {
        case .searching, .thinking, .indexing: return true
        case .idle, .responding, .error:       return false
        }
    }

    /// True when the edge glow should be active.
    public var needsEdgeGlow: Bool {
        switch self {
        case .thinking, .searching, .responding: return true
        case .idle, .indexing, .error:           return false
        }
    }

    /// Glow intensity [0…1] for animation.
    public var glowIntensity: Double {
        switch self {
        case .idle, .indexing:      return 0
        case .searching:            return 0.4
        case .thinking:             return 0.8
        case .responding:           return 0.6
        case .error:                return 0.3
        }
    }
}

// MARK: - AIStateMachine

/// Observable state machine that drives the entire AI pipeline.
///
/// **Design principle:** every state transition is validated.
/// Invalid transitions (e.g. `idle -> responding` without going
/// through `thinking`) are silently ignored. This prevents the
/// UI from showing inconsistent states.
public final class AIStateMachine: ObservableObject, @unchecked Sendable {

    // MARK: - Published state (UI binds to these)

    /// The canonical state. Every UI component that needs to
    /// know "what's happening now" reads this.
    @Published public private(set) var state: AIState = .idle {
        didSet { objectWillChange.send() }
    }

    /// The current search / LLM query text.
    @Published public var query: String = ""

    /// File/app/search results.
    @Published public var results: [SearchResult] = []

    /// Highlighted row index, or nil when empty.
    @Published public var selection: Int? = 0

    /// Streaming LLM reply text (grows as chunks arrive).
    @Published public var llmReply: String? = nil

    /// File paths extracted from the LLM's reply.
    @Published public var llmReplyPaths: [URL] = []

    /// Conversation history for Chat mode.
    @Published public var llmHistory: [LLMConversationService.HistoryEntry] = []

    /// Tool-call trace for the current turn.
    @Published public var toolTrace: [String] = []

    /// Human-readable empty-state message.
    @Published public var emptyMessage: String = "Type to search."

    /// Placeholder shown in the search field.
    @Published public var placeholder: String = "Search files, apps, or ask AI…"

    // MARK: - Generation guard

    /// Monotonic counter that lets us ignore stale results from
    /// cancelled-but-still-running tasks.
    public private(set) var generation: Int = 0
    public func bumpGeneration() { generation += 1 }

    // MARK: - State transitions

    /// Transition to a new state. Invalid transitions are ignored
    /// so the UI never sees contradictory states.
    @MainActor
    public func transition(to newState: AIState) {
        guard isValidTransition(from: state, to: newState) else {
            Log.write("[AIStateMachine] ignored invalid transition: \(state.shortLabel) -> \(newState.shortLabel)")
            return
        }
        let fromLabel = state.shortLabel
        state = newState
        Log.write("[AIStateMachine] \(fromLabel) -> \(newState.shortLabel)")
    }

    /// Reset to idle and clear all transient state.
    @MainActor
    public func reset() {
        state = .idle
        query = ""
        results = []
        selection = nil
        llmReply = nil
        llmReplyPaths = []
        toolTrace = []
        emptyMessage = "Type to search."
        // Don't clear llmHistory — the user may want to revisit
        // the conversation after dismissing the panel.
    }

    // MARK: - Validation

    /// Allowed transitions. Anything not listed here is silently
    /// rejected.
    private func isValidTransition(from old: AIState, to new: AIState) -> Bool {
        switch (old, new) {
        // Idle → anything (except itself)
        case (.idle, .idle):                   return false
        case (.idle, _):                       return true

        // Searching → idle (cancelled), thinking (found → LLM), or error
        case (.searching, .idle):              return true
        case (.searching, .thinking):          return true
        case (.searching, .error):             return true

        // Thinking → responding (reply ready), idle (cancelled), error
        case (.thinking, .responding):         return true
        case (.thinking, .idle):               return true
        case (.thinking, .error):              return true
        // Thinking → thinking (tool call loop, tool completed)
        case (.thinking, .thinking):           return true

        // Responding → idle (cleared), searching (new query)
        case (.responding, .idle):             return true
        case (.responding, .searching):        return true
        case (.responding, .thinking):         return true

        // Error → idle (cleared)
        case (.error, .idle):                  return true
        case (.error, .searching):             return true

        // Indexing — orthogonal to search/LLM, allowed from any state
        case (_, .indexing):                   return true
        case (.indexing, .idle):               return true
        case (.indexing, .searching):          return true
        case (.indexing, .thinking):           return true
        case (.indexing, .error):              return true

        // Everything else is invalid
        default:                               return false
        }
    }
}
