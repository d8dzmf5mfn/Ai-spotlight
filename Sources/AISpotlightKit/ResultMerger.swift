import Foundation

/// Merges result buckets from multiple providers into a single
/// ranked list.
///
/// Phase 6 Step-1.5 (ranking stabilization): the merge now takes
/// provider-tagged buckets (`[(ProviderID, [SearchResult])]`) so it
/// can apply a per-provider weight. The weight compensates for the
/// fact that the three providers assign raw scores on incompatible
/// scales:
///   - `FileSystemProvider`   — 0..N-1
///   - `ContentSearchProvider` — 100..100+N-1 (+100 base boost)
///   - `AppProvider`          — 10 or 100 + N
/// Without a weight, the `ContentSearch` +100 base makes its
/// results always outrank `FileSystem` results, and the
/// `AppProvider` prefix-boost (also +100) collides with
/// `ContentSearch`'s base boost. See `docs/AUDIT_2026-06-17.md`
/// §11.2 for the full breakdown.
///
/// **The weight here is a *soft* normalization, not a contract.**
/// It controls provider-level dominance but does not unify the
/// underlying score semantics. A real ranking contract (TODO-11)
/// is a separate, larger change.
public enum ResultMerger {
    /// Merge provider-tagged buckets, dedup by URL (keep higher
    /// weighted score), sort by weighted score descending.
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

    /// Per-provider ranking weight. Tuned so that:
    ///   - a top `FileSystem` match (raw ~20) becomes weighted ~20
    ///   - a top `ContentSearch` match (raw ~120) becomes weighted ~144
    ///   - a top `AppProvider` prefix match (raw ~100+N) becomes weighted ~110
    /// This preserves the "content > filename > apps" intent that
    /// the +100 hard-coded boost encoded, but with a *tunable*
    /// surface instead of a hard-coded magic number.
    static func providerWeight(_ provider: ProviderID) -> Double {
        switch provider {
        case .fileSystem:   return 1.0
        case .contentSearch: return 1.2
        case .app:          return 1.1
        }
    }
}
