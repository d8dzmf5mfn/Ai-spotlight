import Foundation

/// Merges result buckets from multiple providers into a single
/// ranked list.
///
/// TODO-11: All provider scores are now normalized to [0, 1] before
/// entering the merger. The per-provider weight therefore controls the
/// actual cross-provider ranking:
///   - `contentSearch` (weight 1.2) outranks `fileSystem` (weight 1.0)
///   - `app` (weight 1.1) sits between content and files
///   - `sqliteAugmentation` (weight 1.0) ranks alongside files
///
/// Without this normalization, `ContentSearch` used +100 base boost
/// and `AppProvider` used +100 prefix boost, making it impossible for
/// weights to meaningfully reorder results.
public enum ResultMerger {
    /// Merge provider-tagged buckets, dedup by URL (keep higher
    /// weighted score), sort by weighted score descending.
    ///
    /// Step-5: dedup handles the case where the same file appears
    /// from both MDQuery (FileSystem/ContentSearch) and SQLite
    /// augmentation. The higher weighted score wins.
    ///
    /// Bucket shape changed from `[[SearchResult]]` to
    /// `[(ProviderID, [SearchResult])]` so the merger can identify
    /// the source of each result. This is a breaking change for
    /// the public `merge` signature; `SearchOrchestrator.run()` and
    /// `ResultMergerTests` were updated in the same commit.
    public static func merge(_ groups: [(ProviderID, [SearchResult])]) -> [SearchResult] {
        var byURL: [URL: SearchResult] = [:]
        for (provider, bucket) in groups {
            let weight = providerWeight(provider)
            for r in bucket {
                let adjusted = r.score * weight
                // Compare on weighted score; on tie, prefer the
                // result that was inserted first (deterministic,
                // since buckets arrive in the same order every
                // call from `SearchOrchestrator`).
                if let existing = byURL[r.url] {
                    if existing.weightedScore >= adjusted {
                        continue
                    }
                }
                // Reconstruct with stamped providerID + weightedScore.
                // SearchResult fields are `let`, so we cannot mutate;
                // we build a new value with the same id (preserves
                // Identifiable stability) and the new metadata.
                let stamped = SearchResult(
                    title: r.title,
                    subtitle: r.subtitle,
                    iconSystemName: r.iconSystemName,
                    url: r.url,
                    kind: r.kind,
                    score: r.score,
                    command: r.command,
                    contentSnippet: r.contentSnippet,
                    providerID: provider,
                    weightedScore: adjusted
                )
                byURL[r.url] = stamped
            }
        }
        let sorted = byURL.values.sorted { (a: SearchResult, b: SearchResult) in
            a.weightedScore > b.weightedScore
        }
        return sorted
    }

    /// Per-provider ranking weight. All scores are normalized to [0, 1]
    /// so the weight directly controls cross-provider ordering:
    ///   - `contentSearch` (1.2) — content matches > file name matches
    ///   - `app` (1.1) — app prefix matches rank between content and files
    ///   - `fileSystem` (1.0) — baseline
    ///   - `sqliteAugmentation` (1.0) — alongside file system results
    static func providerWeight(_ provider: ProviderID) -> Double {
        switch provider {
        case .fileSystem:         return 1.0
        case .contentSearch:       return 1.2
        case .app:                 return 1.1
        case .sqliteAugmentation:  return 1.0   // Step-3: SQLite augmentation matches are enrolled/indexed files — rank alongside file system results
        }
    }
}
