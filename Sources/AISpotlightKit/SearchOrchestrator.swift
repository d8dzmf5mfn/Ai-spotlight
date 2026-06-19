import Foundation

/// Step-3: route decision for hybrid search. Determines which
/// providers to fan out to based on the intent type, avoiding
/// unnecessary Spotlight/SQLite queries.
public enum RouteDecision: Sendable, Equatable {
    /// Query all providers (files + apps + SQLite).
    case all
    /// Only file-oriented providers (FileSystem, ContentSearch, SQLite).
    case filesOnly
    /// Only the app provider.
    case appsOnly
    /// No file/app search needed (e.g. pure AI ask).
    case none
    
    /// Decide the route for a given intent.
    public static func decide(for intent: Intent) -> RouteDecision {
        switch intent {
        case .openApp:
            return .appsOnly
        case .findFile(_, _, _, let terms):
            return terms.isEmpty ? .filesOnly : .filesOnly
        case .ask:
            return .none  // LLM handles this directly
        case .unknown(let raw):
            if raw.isEmpty { return .none }
            return .filesOnly
        }
    }
}

public final class SearchOrchestrator: @unchecked Sendable {
    private let providers: [SearchProvider]

    public init(providers: [SearchProvider]) {
        self.providers = providers
    }

    /// Fan out an intent to all providers in parallel, then merge.
    ///
    /// Phase 6 Step-1.5: return shape changed from `[SearchResult]`
    /// to `[(ProviderID, [SearchResult])]`. The caller now sees
    /// which bucket came from which provider, so `ResultMerger` can
    /// apply per-provider weight. `AppState` is the only caller
    /// (verified 2026-06-17) and it passes the tagged buckets
    /// straight to `ResultMerger.merge(_:)`.
    public func run(intent: Intent) async -> [(ProviderID, [SearchResult])] {
        // Step-3: route decision filters providers based on intent.
        // This avoids unnecessary Spotlight/SQLite queries (e.g.
        // no point searching files for an app launch).
        let route = RouteDecision.decide(for: intent)
        
        // Pairs each provider with the id it should be tagged as.
        // Only includes providers that match the route decision.
        let pairs: [(SearchProvider, ProviderID)] = providers.compactMap { p in
            let id: ProviderID
            switch p.name {
            case "FileSystem":       id = .fileSystem
            case "Content":          id = .contentSearch
            case "Apps":             id = .app
            case "SQLiteAugmentation": id = .sqliteAugmentation
            default:                 id = .fileSystem
            }
            // Filter by route decision
            switch id {
            case .fileSystem, .contentSearch, .sqliteAugmentation:
                guard route == .all || route == .filesOnly else { return nil }
            case .app:
                guard route == .all || route == .appsOnly else { return nil }
            }
            return (p, id)
        }
        guard !pairs.isEmpty else { return [] }
        
        return await withTaskGroup(of: (ProviderID, [SearchResult]).self) { group -> [(ProviderID, [SearchResult])] in
            for (p, id) in pairs {
                group.addTask { (id, await p.search(intent: intent)) }
            }
            var all: [(ProviderID, [SearchResult])] = []
            for await pair in group { all.append(pair) }
            return all
        }
    }
}
