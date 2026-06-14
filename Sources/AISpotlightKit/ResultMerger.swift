import Foundation

public enum ResultMerger {
    /// Merge result buckets from multiple providers.
    /// - Deduplicates by URL (keeps the entry with the higher score).
    /// - Sorts the final result by score, descending.
    ///
    /// The dictionary is the working set; we sort `values` once at the
    /// end. This is O(n) on the total number of results, not O(n²).
    public static func merge(_ buckets: [[SearchResult]]) -> [SearchResult] {
        var byURL: [URL: SearchResult] = [:]
        for bucket in buckets {
            for r in bucket {
                // Keep the higher-score entry on conflict.
                if let existing = byURL[r.url], existing.score >= r.score { continue }
                byURL[r.url] = r
            }
        }
        return byURL.values.sorted { $0.score > $1.score }
    }
}
