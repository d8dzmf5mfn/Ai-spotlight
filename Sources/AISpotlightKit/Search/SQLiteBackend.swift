import Foundation
import SQLite3

/// Step-2: SQLite FTS5 augmentation backend with schema migration.
///
/// See `docs/SEARCH_BACKEND.md` for the full architecture and
/// `docs/STEP1_PLAN.md` for the step-by-step plan.
///
/// **Step-3 status:** FTS5 query implementation with real
/// `search()` that translates a user's Intent into an FTS5 MATCH
/// query, executes it against the files_fts virtual table, and
/// returns ranked `SearchResult`s.
///
/// **Hard boundary:** today no production code writes to this DB
/// (FSEvents sync is Step-2 deferred), so queries return empty
/// results until the sync layer is wired. The query logic is
/// complete and tested, ready for Step-4 activation.
public final class SQLiteBackend: SearchProvider, @unchecked Sendable {
    public let name = "SQLiteAugmentation"

    public init() {
        Self.migrateSchemaIfNeeded(at: Self.databaseURL)
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        Log.write("[SQLiteBackend] search: intent type=\(intent.shortDescription), limit=\(limit)")
        // Handle all intent types by extracting search terms.
        // SQLite FTS5 can match filenames, paths, and folder names
        // regardless of intent classification.
        let terms: [String]
        switch intent {
        case .findFile(_, _, _, let t):
            terms = t
        case .openApp(let name):
            terms = [name]
        case .ask(let query, _):
            terms = query.split(separator: " ").map(String.init)
        case .unknown(let raw):
            terms = raw.split(separator: " ").map(String.init)
        }
        guard !terms.isEmpty else { Log.write("[SQLiteBackend] search: no terms, skipping"); return [] }

        let ftsQuery = Self.translateToFTS5(terms)
        guard !ftsQuery.isEmpty else { Log.write("[SQLiteBackend] search: FTS query empty for terms=\(terms)"); return [] }

        let db = Self.openDatabase(at: Self.databaseURL)
        guard let db else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
        SELECT f.path, f.filename, f.last_modified, f.file_type, rank
        FROM files f
        JOIN files_fts fts ON f.id = fts.rowid
        WHERE files_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.write("[SQLiteBackend] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        // Bind FTS5 query string
        let ftsQueryNS = ftsQuery as NSString
        guard sqlite3_bind_text(stmt, 1, ftsQueryNS.utf8String, -1, nil) == SQLITE_OK else {
            Log.write("[SQLiteBackend] bind text failed")
            return []
        }
        guard sqlite3_bind_int(stmt, 2, Int32(clamping: limit)) == SQLITE_OK else {
            Log.write("[SQLiteBackend] bind limit failed")
            return []
        }

        var results: [SearchResult] = []
        var index = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 0) else { continue }
            let path = String(cString: pathC)
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL else { continue }

            let rank = sqlite3_column_double(stmt, 4)
            // Convert FTS5 rank (negative, closer to 0 = better) to
            // a positive score. FTS5 default rank is in range ~[-50, 0].
            // Multiply by -1 so better matches (rank ~ -50) get higher
            // scores, then clamp to [1, 200].
            // Normalize FTS5 rank (~[-50, 0]) to [0, 1]
            let normalizedRank = max(0, min(1.0, -rank / 50.0))
            // Blend with position bias so earlier results score higher
            let position = Double(limit - index) / Double(limit)
            let score = normalizedRank * 0.7 + position * 0.3

            results.append(SearchResult(
                title: url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().path,
                iconSystemName: "doc.text.magnifyingglass",
                url: url,
                kind: .file,
                score: score,
                contentSnippet: "SQLite augmentation match"
            ))
            index += 1
        }
        Log.write("[SQLiteBackend] search: found \(results.count) results for terms=\(terms)")

        // Phase 6.2: FTS5 with unicode61 tokenizer cannot handle CJK.
        // Fall back to LIKE query when FTS5 returns empty for non-ASCII terms.
        if results.isEmpty, terms.contains(where: { $0.unicodeScalars.contains(where: { !$0.isASCII }) }) {
            let likeResults = fallbackCJKSearch(db: db, terms: terms, limit: limit)
            Log.write("[SQLiteBackend] CJK fallback: found \(likeResults.count) results")
            return likeResults
        }

        return results
    }

    /// Phase 6.2: LIKE-based fallback for CJK queries that FTS5 cannot handle.
    private func fallbackCJKSearch(db: OpaquePointer?, terms: [String], limit: Int) -> [SearchResult] {
        guard let db else { return [] }

        var results: [SearchResult] = []
        var index = 0
        var seen = Set<String>()

        for term in terms where !term.isEmpty {
            let likePattern = "%" + term + "%"
            let sql = "SELECT path, filename, last_modified, file_type FROM files WHERE (filename LIKE ?1 OR path LIKE ?1) AND is_deleted = 0 LIMIT ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                continue
            }

            let patternNS = likePattern as NSString
            sqlite3_bind_text(stmt, 1, patternNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(clamping: limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard results.count < limit else { break }
                guard let pathC = sqlite3_column_text(stmt, 0) else { continue }
                let path = String(cString: pathC)
                guard seen.insert(path).inserted else { continue }

                let url = URL(fileURLWithPath: path)
                let score = Double(limit - index) / Double(limit)

                results.append(SearchResult(
                    title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    iconSystemName: "doc.text.magnifyingglass",
                    url: url,
                    kind: .file,
                    score: score,
                    contentSnippet: "CJK LIKE match"
                ))
                index += 1
            }
            sqlite3_finalize(stmt)

            if results.count >= limit { break }
        }

        return results
    }

    // MARK: - FTS5 Query Translation

    // MARK: - FTS5 Query Translation

    /// Translate an array of user search terms into an FTS5 MATCH
    /// expression. Multiple terms are OR'd so any term hit returns
    /// a result.
    ///
    /// FTS5 special characters that must be escaped:
    ///   ^ * " ( ) + - ~ AND OR NOT NEAR
    ///
    /// Strategy: strip FTS5 operators, escape remaining special
    /// chars, join with OR, and use prefix matching on the last
    /// word of each term for partial-match UX.
    static func translateToFTS5(_ terms: [String]) -> String {
        let cleaned = terms
            .filter { !$0.isEmpty }
            .map { sanitizeFTS5Term($0) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return "" }

        // Each term becomes a quoted phrase with prefix match.
        // FTS5: `"term"*` means "match the phrase 'term' as a prefix".
        let parts = cleaned.map { "\"\($0)\"*" }
        return parts.joined(separator: " OR ")
    }

    /// Sanitize a single search term for FTS5. We strip FTS5
    /// operators and escape embedded double-quotes.
    private static func sanitizeFTS5Term(_ raw: String) -> String {
        // Strip known FTS5 boolean operators (case-insensitive).
        var s = raw
        // Remove common operators that interfere with FTS5 parsing
        let operators = [" OR ", " AND ", " NOT ", " NEAR "]
        for op in operators {
            s = s.replacingOccurrences(of: op, with: " ", options: .caseInsensitive)
        }

        // Remove leading special chars that FTS5 would interpret
        // as operators: ^ + - ~
        while let first = s.first, "+-~^".contains(first) {
            s = String(s.dropFirst())
        }

        // Escape embedded double-quotes by doubling them (FTS5 convention)
        s = s.replacingOccurrences(of: "\"", with: "\"\"")

        // Remove any remaining lone special characters except spaces,
        // alphanumerics, and common punctuation. Keep CJK (non-ASCII).
        // CharacterSet is not Sequence, so we check via character's
        // Unicode scalars against a pre-built CharacterSet.
        let allowedChars = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_'."))
        s = s.filter { c in
            guard c.isASCII else { return true }
            return c.unicodeScalars.allSatisfy { allowedChars.contains($0) }
        }

        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Database Connection

    /// Open SQLite database at `url`. Returns nil on failure.
    /// Logs the error but does not throw — caller falls back to
    /// empty results gracefully.
    private static func openDatabase(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open(url.path, &db)
        guard rc == SQLITE_OK else {
            Log.write("[SQLiteBackend] open failed at \(url.path): rc=\(rc)")
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
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
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            Log.write("[SQLiteBackend] createDirectory warning: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            Log.write("[SQLiteBackend] open failed at \(url.path); schema migration skipped")
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

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

    // MARK: - Batch Write Operations (Step-2 Sync Layer)

    /// Batch upsert files into the SQLite DB. Opens the DB,
    /// runs all operations in a single transaction, then closes.
    /// Idempotent: calling this twice with the same data is safe.
    ///
    /// - Parameters:
    ///   - files: array of file metadata to upsert
    ///   - url: path to the SQLite DB
    ///
    /// Files already in the DB are updated (same path); new files
    /// are inserted. The FTS5 index is kept in sync via `files_fts`.
    /// `content_preview` is left empty until a user explicitly opens
    /// or pins the file (per §4.2 hard limits).
    public static func upsertFiles(_ files: [(path: String, filename: String, lastModified: Int, fileType: String?)], at url: URL) {
        guard !files.isEmpty else { return }
        let db = openDatabase(at: url)
        guard let db else { return }
        defer { sqlite3_close(db) }

        // Begin transaction
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            Log.write("[SQLiteBackend] upsertFiles: BEGIN failed")
            return
        }

        let insertFileSQL = """
        INSERT OR REPLACE INTO files (path, filename, last_modified, file_type)
        VALUES (?1, ?2, ?3, ?4)
        """
        let insertFtsSQL = """
        INSERT OR REPLACE INTO files_fts (rowid, filename, path, content_preview)
        VALUES ((SELECT id FROM files WHERE path = ?1), ?2, ?1, '')
        """

        var fileStmt: OpaquePointer?
        var ftsStmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, insertFileSQL, -1, &fileStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, insertFtsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
            Log.write("[SQLiteBackend] upsertFiles: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_finalize(fileStmt)
            sqlite3_finalize(ftsStmt)
            return
        }
        defer { sqlite3_finalize(fileStmt); sqlite3_finalize(ftsStmt) }

        var successCount = 0
        for file in files {
            // Bind files table
            sqlite3_bind_text(fileStmt, 1, (file.path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(fileStmt, 2, (file.filename as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(fileStmt, 3, Int64(file.lastModified))
            if let ft = file.fileType {
                sqlite3_bind_text(fileStmt, 4, (ft as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(fileStmt, 4)
            }

            if sqlite3_step(fileStmt) == SQLITE_DONE {
                sqlite3_reset(fileStmt)
            } else {
                Log.write("[SQLiteBackend] upsertFiles: file insert failed for \(file.path)")
                sqlite3_reset(fileStmt)
                continue
            }

            // Bind files_fts table
            sqlite3_bind_text(ftsStmt, 1, (file.path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(ftsStmt, 2, (file.filename as NSString).utf8String, -1, nil)
            // path = file.path (already bound as arg 1)
            // content_preview = '' (already in SQL)

            if sqlite3_step(ftsStmt) == SQLITE_DONE {
                sqlite3_reset(ftsStmt)
            } else {
                Log.write("[SQLiteBackend] upsertFiles: FTS insert failed for \(file.path)")
                sqlite3_reset(ftsStmt)
                continue
            }

            successCount += 1
        }

        let commitRC = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if commitRC == SQLITE_OK {
            Log.write("[SQLiteBackend] upsertFiles: \(successCount)/\(files.count) files upserted")
        } else {
            Log.write("[SQLiteBackend] upsertFiles: COMMIT failed: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    /// Soft-delete files by path. Sets `is_deleted = 1` so the
    /// FTS5 index remains consistent (hard-deleting FTS5 content
    /// while it's still referenced by the files table would break
    /// the relationship).
    public static func markDeleted(paths: [String], at url: URL) {
        guard !paths.isEmpty else { return }
        let db = openDatabase(at: url)
        guard let db else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        var stmt: OpaquePointer?
        let sql = "UPDATE files SET is_deleted = 1 WHERE path = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.write("[SQLiteBackend] markDeleted: prepare failed")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        for path in paths {
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_DONE {
                sqlite3_reset(stmt)
            } else {
                sqlite3_reset(stmt)
            }
        }

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            Log.write("[SQLiteBackend] markDeleted: \(paths.count) files soft-deleted")
        } else {
            Log.write("[SQLiteBackend] markDeleted: COMMIT failed")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    /// Remove the soft-delete marker for files at the given paths.
    /// Called when a deleted file reappears (e.g. user moved it back).
    public static func unmarkDeleted(paths: [String], at url: URL) {
        guard !paths.isEmpty else { return }
        let db = openDatabase(at: url)
        guard let db else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        var stmt: OpaquePointer?
        let sql = "UPDATE files SET is_deleted = 0 WHERE path = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        for path in paths {
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_DONE {
                sqlite3_reset(stmt)
            } else {
                sqlite3_reset(stmt)
            }
        }

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            Log.write("[SQLiteBackend] unmarkDeleted: \(paths.count) files restored")
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

}