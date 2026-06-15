import Foundation

/// Interprets raw user text into an Intent.
///
/// Three-tier routing (Phase 4.2 — LLM-based intent router):
/// 1. **Cache hit** (LRU, 100 entries) — O(1) return.
/// 2. **LLMIntentRouter** (if enabled + a provider is configured) —
///    ask a small LLM to classify the raw query. Better than
///    rules for free-form sentences, Chinese, multi-token app
///    names, etc. Catches the cases that `QueryParser` would
///    miss. Falls through on parse failure.
/// 3. **QueryParser** — fast rule-based parser, no LLM call.
///    Always runs as the final fallback. Returns one of
///    `.findFile` / `.openApp` / `.unknown`.
///
/// The `LLMIntentRouter` is what Apple Siri / Microsoft
/// Copilot / Notion AI use. We can tune the system prompt to
/// make the LLM output stable JSON. Failures fall back to
/// `QueryParser` (graceful degradation — no LLM = no new
/// feature, but nothing breaks).
public actor QueryInterpreter {
    private let aiProvider: AIProvider?
    /// Optional router. When nil (or `useLLMRouter = false` in
    /// Settings), we skip the LLM call and go straight to the
    /// rule parser. The router is on the App target; we let
    /// the caller pass it in (rather than constructing one here)
    /// so the App can control its lifetime.
    private let llmRouter: LLMIntentRouter?
    private var cache: [String: Intent] = [:]
    private var order: [String] = []
    private let cacheLimit: Int

    public init(aiProvider: AIProvider? = nil,
                llmRouter: LLMIntentRouter? = nil,
                cacheLimit: Int = 100) {
        self.aiProvider = aiProvider
        self.llmRouter = llmRouter
        self.cacheLimit = cacheLimit
    }

    public func interpret(_ raw: String) async -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown(raw: trimmed) }

        // Cache hit.
        if let hit = cache[trimmed] {
            if let idx = order.firstIndex(of: trimmed) { order.remove(at: idx) }
            order.append(trimmed)
            return hit
        }

        // Tier 2: LLM-based intent router (Phase 4.2).
        // Try this BEFORE the rule parser so it has a chance to
        // produce a high-confidence .search / .ask / .openApp
        // for queries the rule parser would have given up on.
        // We still fall through to the rule parser if the
        // router says .unknown or low confidence.
        if let router = llmRouter, let _ = aiProvider {
            if let routed = try? await router.route(query: trimmed) {
                let llmIntent = Self.routedToIntent(routed, raw: trimmed)
                // If the router is confident, use it.
                if case .unknown = llmIntent {
                    // Router couldn't classify. Fall through.
                } else {
                    return Self.cache(llmIntent, query: trimmed, cache: &cache, order: &order, cacheLimit: cacheLimit)
                }
            }
        }

        // Tier 3: rule parser (Phase 1 + 4.2 prefix-free app lookup).
        let parsed = QueryParser.parse(trimmed)
        let final: Intent
        if case .unknown = parsed, let _ = aiProvider {
            // Rule parser gave up. Build Intent.ask so the
            // AppState streaming pipeline can take over. The
            // router was tried first and returned .unknown, so
            // the LLM really has no clue — assume free-form
            // question.
            final = .ask(query: trimmed, contextURLs: [])
        } else {
            final = parsed
        }
        return Self.cache(final, query: trimmed, cache: &cache, order: &order, cacheLimit: cacheLimit)
    }

    // MARK: - RoutedIntent → Intent

    /// Convert a `RoutedIntent` from the LLM router into an
    /// `Intent` the rest of the pipeline understands. We keep
    /// this mapping here (not in the router) so the router
    /// stays a Foundation-only utility without depending on
    /// `Intent` directly.
    private static func routedToIntent(_ routed: RoutedIntent, raw: String) -> Intent {
        switch routed.kind {
        case .search:
            // Router says: user wants to find a file. Convert
            // to .findFile with the extracted parameters. The
            // orchestrator's FileSystemProvider does the
            // actual filename fuzzy match.
            return .findFile(
                name: routed.keywords.first,  // best-effort filename
                dateFilter: routed.dateRange.flatMap(DateFilter.init(rawValue:)),
                kind: nil  // fileTypes handled in orchestrator
            )
        case .ask:
            return .ask(query: raw, contextURLs: [])
        case .openApp:
            return .openApp(name: routed.appName ?? raw)
        case .ambiguous, .unknown:
            return .unknown(raw: raw)
        }
    }

    // MARK: - LRU helper

    private static func cache(_ intent: Intent, query: String,
                              cache: inout [String: Intent],
                              order: inout [String],
                              cacheLimit: Int) -> Intent {
        if cache.count >= cacheLimit, let oldest = order.first {
            cache.removeValue(forKey: oldest)
            order.removeFirst()
        }
        cache[query] = intent
        order.append(query)
        return intent
    }
}

