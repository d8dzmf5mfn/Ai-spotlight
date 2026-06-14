import Foundation

/// Interprets raw user text into an Intent.
/// Fast path: rule-based parser. Slow path: AI provider (if one is configured).
/// Caches results in an LRU of `cacheLimit` entries to keep API costs down.
public actor QueryInterpreter {
    private let aiProvider: AIProvider?
    private var cache: [String: Intent] = [:]
    private let cacheLimit: Int

    public init(aiProvider: AIProvider? = nil, cacheLimit: Int = 100) {
        self.aiProvider = aiProvider
        self.cacheLimit = cacheLimit
    }

    public func interpret(_ raw: String) async -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown(raw: trimmed) }
        if let hit = cache[trimmed] { return hit }

        let parsed = QueryParser.parse(trimmed)
        let final: Intent
        if case .unknown = parsed, let ai = aiProvider {
            // Rule parser gave up — try the LLM. Any throw falls back to .unknown.
            final = (try? await ai.classify(trimmed)) ?? parsed
        } else {
            final = parsed
        }

        // LRU-ish: if at capacity, evict one arbitrary entry. Good enough for Phase 1.
        if cache.count >= cacheLimit, let k = cache.keys.first {
            cache.removeValue(forKey: k)
        }
        cache[trimmed] = final
        return final
    }
}
