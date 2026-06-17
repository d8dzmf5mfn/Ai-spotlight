import Foundation

/// Runtime configuration for the search backend.
///
/// See `docs/SEARCH_BACKEND.md` for context. Step-1: this type
/// exists but is **not read** by any production code. Step-3
/// (merge layer) is the first place that reads
/// `useSQLiteAugmentation`.
public struct SearchConfig: Sendable {
    /// Whether the SQLite augmentation backend participates
    /// in queries. Defaults to `false` so Step-1 ships with
    /// zero behavior change. Step-4 flips this to `true`.
    public var useSQLiteAugmentation: Bool

    public init(useSQLiteAugmentation: Bool = false) {
        self.useSQLiteAugmentation = useSQLiteAugmentation
    }
}
