import Foundation

public enum ResultMerger {
    /// Merge result buckets from multiple providers.
    /// - Deduplicates by URL (keeps the entry with the higher score).
    /// - Sorts the final result by score, descending.
    public static func merge(_ buckets: [[SearchResult]]) -> [SearchResult] {
        var byURL: [URL: SearchResult] = [:]
        for bucket in buckets {
            for r in bucket {
                if let existing = byURL[r.url], existing.score >= r.score {
                    continue
                }
                byURL[r.url] = r
            }
        }
        return byURL.values.sorted { $0.score > $1.score }
    }
}
