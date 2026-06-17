import Foundation

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
        // Pairs each provider with the id it should be tagged as.
        // Today there is exactly one provider per id; if a future
        // refactor adds e.g. multiple content-search sources, this
        // mapping is the single place to update.
        let pairs: [(SearchProvider, ProviderID)] = providers.map { p in
            let id: ProviderID
            switch p.name {
            case "FileSystem":  id = .fileSystem
            case "Content":     id = .contentSearch
            case "Apps":        id = .app
            default:            id = .fileSystem  // unknown provider → safest default
            }
            return (p, id)
        }
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
