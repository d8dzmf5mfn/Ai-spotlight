import Foundation

/// Step-1 stub for the SQLite FTS5 augmentation backend.
///
/// See `docs/SEARCH_BACKEND.md` for the full architecture and
/// `docs/STEP1_PLAN.md` for the step-by-step plan.
///
/// **Step-1 status:** type-only conformance. `search(intent:limit:)`
/// always returns `[]`. No database file is created, no schema
/// migration runs, no `import SQLite3` happens — this is purely
/// a structural placeholder so the `SearchProvider` protocol has
/// a second conformer waiting for Step-2 / Step-3 work.
///
/// **Why no schema in init():** Step-1 must not introduce a
/// runtime dependency (system library linking, file I/O, schema
/// migration). The `SQLiteBackend.init()` body is intentionally
/// empty. Schema and DB-file creation land in Step-2, after
/// SwiftPM SQLite3 linking is solved as its own discrete task.
///
/// **Hard boundary:** adding database calls, file I/O, or
/// `import SQLite3` to this file is a Step-2 concern, not Step-1.
public final class SQLiteBackend: SearchProvider, @unchecked Sendable {
    public let name = "SQLiteAugmentation"

    public init() {
        // Intentionally empty. Step-1 is type-only.
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        // Step-1: empty stub. Real FTS5 query implementation
        // lands in Step-3 (merge layer).
        return []
    }
}
