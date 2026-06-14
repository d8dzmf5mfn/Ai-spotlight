import Foundation

/// Interprets raw user text into an Intent.
/// Fast path: rule-based parser. Slow path: AI provider (if one is configured).
/// Caches results in an LRU of `cacheLimit` entries to keep API costs down.
public actor QueryInterpreter {
    private let aiProvider: AIProvider?
    private var cache: [String: Intent] = [:]
    /// Insertion-order bookkeeping. `cache` itself doesn't preserve
    /// order in Swift, so we use a separate array to drive LRU eviction:
    /// when we touch a key we re-append it, and eviction removes the
    /// oldest entry. The cost is an O(cacheLimit) `firstIndex(of:)` on
    /// each call, which is fine for a 100-entry cache.
    private var order: [String] = []
    private let cacheLimit: Int

    public init(aiProvider: AIProvider? = nil, cacheLimit: Int = 100) {
        self.aiProvider = aiProvider
        self.cacheLimit = cacheLimit
    }

    public func interpret(_ raw: String) async -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown(raw: trimmed) }

        // Cache hit: bump the key to the most-recently-used end of `order`.
        if let hit = cache[trimmed] {
            if let idx = order.firstIndex(of: trimmed) { order.remove(at: idx) }
            order.append(trimmed)
            return hit
        }

        let parsed = QueryParser.parse(trimmed)
        let final: Intent
        if case .unknown = parsed, let ai = aiProvider {
            // Rule parser gave up — try the LLM. Any throw falls back to .unknown.
            final = (try? await ai.classify(trimmed)) ?? parsed
        } else {
            final = parsed
        }

        // LRU eviction: remove the oldest entry if we're at capacity.
        if cache.count >= cacheLimit, let oldest = order.first {
            cache.removeValue(forKey: oldest)
            order.removeFirst()
        }
        cache[trimmed] = final
        order.append(trimmed)
        return final
    }
}
