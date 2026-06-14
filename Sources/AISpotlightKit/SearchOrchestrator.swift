import Foundation

public actor SearchOrchestrator {
    private let providers: [SearchProvider]

    public init(providers: [SearchProvider]) {
        self.providers = providers
    }

    /// Fan out an intent to all providers in parallel, merge results, return ranked.
    public func run(intent: Intent) async -> [SearchResult] {
        let buckets = await withTaskGroup(of: [SearchResult].self) { group -> [[SearchResult]] in
            for provider in providers {
                let p = provider
                group.addTask { await p.search(intent: intent) }
            }
            var all: [[SearchResult]] = []
            for await bucket in group { all.append(bucket) }
            return all
        }
        return ResultMerger.merge(buckets)
    }
}
