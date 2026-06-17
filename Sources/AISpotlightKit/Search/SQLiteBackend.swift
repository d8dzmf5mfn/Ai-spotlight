import Foundation
import SQLite3

/// Step-2: SQLite FTS5 augmentation backend with schema migration.
///
/// See `docs/SEARCH_BACKEND.md` for the full architecture and
/// `docs/STEP1_PLAN.md` for the step-by-step plan.
///
/// **Step-2 status:** type conformance + schema migration. On
/// `init()`, opens (or creates) the DB file at
/// `~/Library/Application Support/AISpotlight/search_augment.sqlite`
/// and runs the schema DDL. Schema is idempotent — running init
/// twice is safe (every CREATE uses IF NOT EXISTS).
///
/// **Still NOT Step-3:** `search(intent:limit:)` returns `[]` always.
/// FTS5 query implementation lands in Step-3 (merge layer).
///
/// **Hard boundary:** no production code invokes this backend
/// yet. `SearchOrchestrator` does not know it exists. Wiring in
/// happens via `useSQLiteAugmentation` flag in Step-3.
public final class SQLiteBackend: SearchProvider, @unchecked Sendable {
    public let name = "SQLiteAugmentation"

    public init() {
        Self.migrateSchemaIfNeeded(at: Self.databaseURL)
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        // Step-2: still empty stub. Real FTS5 query implementation
        // lands in Step-3 (merge layer).
        return []
    }

    // MARK: - Database location

    /// `~/Library/Application Support/AISpotlight/search_augment.sqlite`
    /// (per `docs/SEARCH_BACKEND.md` §1 Q2 decision).
    public static let databaseURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("AISpotlight", isDirectory: true)
        return dir.appendingPathComponent("search_augment.sqlite")
    }()

    // MARK: - Schema migration

    /// Runs the Step-2 schema DDL on the DB at `url`. Idempotent:
    /// every CREATE uses IF NOT EXISTS, so calling this on an
    /// already-migrated DB is a no-op.
    ///
    /// Schema (per `docs/SEARCH_BACKEND.md` §4.1, decision B:
    /// FTS5 self-contained):
    /// - `files` — bounded metadata (path, filename, last_modified,
    ///   file_type, is_deleted soft-delete flag)
    /// - `files_fts` — FTS5 virtual table over filename, path, and
    ///   a bounded content_preview column
    ///
    /// `user_signals` (pinned / recently-opened) is intentionally
    /// omitted in Step-2 — it is a separate table with stricter
    /// scope discipline (§4.4 of SEARCH_BACKEND.md) and will be
    /// added in a later step, gated on a real product need.
    static func migrateSchemaIfNeeded(at url: URL) {
        // Ensure parent directory exists. createDirectory with
        // .withIntermediateDirectories returns the URL on success
        // or throws if a file exists at the path (we don't care
        // — the dir may already exist).
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            // Directory likely already exists. If it's a real
            // error, the subsequent open() will surface it.
            Log.write("[SQLiteBackend] createDirectory warning: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            // Don't crash the app on DB open failure — Step-2 is
            // still additive (no caller uses this backend yet).
            // Log and return; the search() stub will keep returning [].
            Log.write("[SQLiteBackend] open failed at \(url.path); schema migration skipped")
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        // Foreign keys off (default). WAL off (single-process).
        // Both can be tuned later in Step-2 follow-ups.
        let ddl = """
        CREATE TABLE IF NOT EXISTS files (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT UNIQUE NOT NULL,
          filename TEXT NOT NULL,
          last_modified INTEGER NOT NULL,
          file_type TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
          filename,
          path,
          content_preview,
          tokenize = 'porter unicode61'
        );

        CREATE INDEX IF NOT EXISTS idx_files_last_modified
          ON files(last_modified);
        CREATE INDEX IF NOT EXISTS idx_files_is_deleted
          ON files(is_deleted);
        """

        let execResult = sqlite3_exec(db, ddl, nil, nil, nil)
        if execResult != SQLITE_OK {
            let errMsg = String(cString: sqlite3_errmsg(db))
            Log.write("[SQLiteBackend] schema migration failed: \(errMsg)")
        }
    }
}
