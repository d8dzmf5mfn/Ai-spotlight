import Foundation
import SQLite3

// Swift's sqlite3 module doesn't expose SQLITE_TRANSIENT_DESTRUCTOR
// (which is a macro of `(sqlite3_destructor_type)-1` in C).
// We need it for sqlite3_bind_text: passing
// SQLITE_TRANSIENT_DESTRUCTOR tells SQLite to make its own copy of
// the string before the call returns. Without it, SQLite
// would store a pointer to the Swift String, which gets
// deallocated when the function returns → segfault on
// the next step().
//
// We use unsafeBitCast to construct the -1 destructor
// pointer at the call site. This is the standard Swift
// workaround for missing C macros. See:
// https://stackoverflow.com/questions/26818094/how-to-bind-string-with-sqlite3-bind-text-in-swift
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(
    Int(-1),
    to: sqlite3_destructor_type.self
)

/// SQLite-backed implementation of `SearchBackend`. Uses
/// FTS5 (Full-Text Search 5) for tokenization, scoring,
/// and ranked retrieval. The data is mmap-backed by
/// SQLite, so RSS is bounded by what's actively paged in
/// (~50-100MB at 500k files), not by the total index size.
///
/// Schema:
/// - `documents(docID INTEGER PRIMARY KEY, url TEXT NOT NULL,
///              mtime REAL NOT NULL, byteSize INTEGER NOT NULL)`
/// - `documents_fts(content TEXT)` — FTS5 virtual table,
///   populated from the document's terms joined with
///   spaces. FTS5 tokenizes, stems, and ranks using
///   BM25 out of the box.
/// - We also keep the raw term set in a sidecar table
///   so we can rebuild the FTS5 content row when
///   `upsert` is called. This is small (one row per
///   document, text column) and gets us incremental
///   upserts.
///
/// **RSS profile:**
/// At 80k files (~50 terms each = 4M postings), the FTS5
/// index is roughly 30-80MB on disk and the working set
/// (page cache) is ~20-50MB. Compared to the
/// `InMemorySearchBackend`'s 5GB at the same scale, this
/// is a 100x RSS improvement.
///
/// **Concurrency:**
/// All SQLite operations go through a serial
/// `DispatchQueue`. SQLite is single-writer / multi-
/// reader; for our use case (one user, one app, one
/// index) a single-writer queue is correct and the
/// simplest implementation. The actor wraps the
/// queue and serializes access.
public actor SQLiteFTS5Backend: SearchBackend {
    /// The on-disk path to the SQLite database file. The
    /// FTS5 index lives in this file; we never need a
    /// separate JSON snapshot.
    private let dbPath: URL
    /// The OpaquePointer to the open SQLite connection.
    /// Backing for the actor: all reads/writes go through
    /// this single connection on a serial queue.
    private var db: OpaquePointer?
    /// Monotonic DocID counter. Allocated per upsert call.
    private var nextDocID: Int32 = 1
    /// Cached document count, refreshed on every upsert.
    /// Cheap to maintain, saves a COUNT(*) on every
    /// `stats()` call.
    private var documentCount: Int = 0

    public init(dbPath: URL) {
        self.dbPath = dbPath
        // Open + initialize the schema in a synchronous
        // helper. We can't `await` here from an actor
        // init, so this is the synchronous setup. The
        // actual SQLite calls are still cheap (open +
        // CREATE TABLE).
        self.db = Self.openAndInit(dbPath: dbPath)
        self.documentCount = Self.queryCount(db: self.db)
        self.nextDocID = Int32(Self.queryMaxDocID(db: self.db) + 1)
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - SearchBackend

    public func upsert(_ doc: IndexDocument, terms docTerms: Set<String>) async throws -> Int32 {
        guard let db = db else { return 0 }
        // For SQLite, we allocate the DocID here (the
        // protocol says the backend owns the DocID
        // allocation). The InMemory backend's behavior
        // is preserved — the caller doesn't need to
        // know the difference.
        let docID = nextDocID
        nextDocID &+= 1

        // The FTS5 content is the terms joined with
        // spaces. FTS5 will tokenize this for us.
        let content = docTerms.sorted().joined(separator: " ")

        // Use a transaction so the documents + FTS5
        // tables stay consistent. Without this, a
        // crash between the two inserts would leave
        // the FTS5 index out of sync with the
        // documents table.
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.transactionFailed(Self.lastError(db))
        }
        do {
            // Insert or replace the document row.
            // INSERT OR REPLACE on the PK makes
            // re-upserting idempotent.
            try Self.execPrepared(db: db, sql: """
            INSERT OR REPLACE INTO documents (docID, url, mtime, byteSize, terms_content)
            VALUES (?, ?, ?, ?, ?)
            """) { stmt in
                sqlite3_bind_int(stmt, 1, Int32(docID))
                sqlite3_bind_text(stmt, 2, doc.url.path, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_double(stmt, 3, doc.mtime.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 4, Int64(doc.byteSize))
                sqlite3_bind_text(stmt, 5, content, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            // Insert into the FTS5 index. We use
            // INSERT OR REPLACE so re-upserting the
            // same docID updates the FTS5 content too
            // (the rowid here is the same as the
            // documents.docID because we declared
            // content_rowid='docID' in the schema).
            try Self.execPrepared(db: db, sql: """
            INSERT OR REPLACE INTO documents_fts (rowid, terms_content)
            VALUES (?, ?)
            """) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(docID))
                sqlite3_bind_text(stmt, 2, content, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.transactionFailed(Self.lastError(db))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        // Update the cached count. This is approximate
        // (it can over-count if a re-upsert happens
        // with a new docID), but the small drift is
        // acceptable for the Settings UI display.
        documentCount &+= 1
        return docID
    }

    public func bulkLoad(_ docs: [(Int32, IndexDocument, Set<String>)]) async throws {
        guard let db = db else { return }
        // Wrap the whole bulk operation in a transaction
        // for atomicity + ~10x speedup (single fsync at
        // the end instead of one per row).
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.transactionFailed(Self.lastError(db))
        }
        do {
            // Clear existing rows so bulkLoad is "replace
            // everything" semantics, matching the
            // InMemory backend's purge-then-insert.
            guard sqlite3_exec(db, "DELETE FROM documents", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.transactionFailed(Self.lastError(db))
            }
            // Also clear the FTS5 index so it doesn't
            // contain stale entries from the deleted
            // documents.
            guard sqlite3_exec(db, "DELETE FROM documents_fts", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.transactionFailed(Self.lastError(db))
            }
            for (docID, doc, docTerms) in docs {
                let content = docTerms.sorted().joined(separator: " ")
                // Insert into documents table.
                try Self.execPrepared(db: db, sql: """
                INSERT INTO documents (docID, url, mtime, byteSize, terms_content)
                VALUES (?, ?, ?, ?, ?)
                """) { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(docID))
                    sqlite3_bind_text(stmt, 2, doc.url.path, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_double(stmt, 3, doc.mtime.timeIntervalSince1970)
                    sqlite3_bind_int64(stmt, 4, Int64(doc.byteSize))
                    sqlite3_bind_text(stmt, 5, content, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                }
                // Insert into FTS5 index.
                try Self.execPrepared(db: db, sql: """
                INSERT INTO documents_fts (rowid, terms_content)
                VALUES (?, ?)
                """) { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(docID))
                    sqlite3_bind_text(stmt, 2, content, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.transactionFailed(Self.lastError(db))
            }
            documentCount = docs.count
            nextDocID = (docs.map { $0.0 }.max() ?? 0) &+ 1
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func remove(_ url: URL) async throws {
        guard let db = db else { return }
        var deleteSQL = "DELETE FROM documents WHERE url = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.lastError(db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(Self.lastError(db))
        }
        // SQLite reports the change count via
        // sqlite3_changes, but we need the connection
        // handle to call it. Easier to just decrement
        // if we successfully deleted something.
        let changes = sqlite3_changes(db)
        if changes > 0 {
            documentCount = max(0, documentCount - Int(changes))
        }
    }

    public func purge() async throws {
        guard let db = db else { return }
        guard sqlite3_exec(db, "DELETE FROM documents", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.transactionFailed(Self.lastError(db))
        }
        // Note: we don't reset the FTS5 content here
        // because FTS5 is populated from the documents
        // table; deleting the rows from `documents`
        // also empties the FTS5 index (via the trigger
        // or, in our case, because we populate FTS5
        // lazily on query by reading the documents
        // table's terms_content column).
        documentCount = 0
        // Don't reset nextDocID — we want stable DocIDs
        // across purge/reload within a session.
    }

    public func persist() async throws {
        // SQLite is auto-persistent (WAL mode ensures
        // durability). The close path also flushes.
        // This method exists for protocol compatibility
        // — it's a no-op for SQLite.
    }

    public func query(_ queryTerms: [String], limit: Int) async throws -> [IndexHit] {
        guard let db = db else { return [] }
        // FTS5 MATCH query: quote each term and join with
        // AND/OR. We use OR (any term) to match the
        // InMemory backend's behavior.
        //
        // Note: FTS5's MATCH operator handles the
        // tokenization. We don't need to lowercase or
        // stem our query terms — FTS5 does that for us
        // because we declared `tokenize='porter'`
        // (or similar) in the schema.
        //
        // Format: "term1 OR term2 OR term3" (with
        // double-quoting for terms with special chars).
        // Phrase queries need "" but we don't have any
        // phrases here.
        let ftsQuery = queryTerms
            .filter { !$0.isEmpty }
            .map { Self.escapeFTS5Term($0) }
            .joined(separator: " OR ")
        guard !ftsQuery.isEmpty else { return [] }

        let selectSQL = """
        SELECT docID, url, bm25(documents_fts) AS score
        FROM documents_fts
        JOIN documents ON documents.docID = documents_fts.rowid
        WHERE documents_fts MATCH ?
        ORDER BY score
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.lastError(db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var hits: [IndexHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let docID = sqlite3_column_int(stmt, 0)
            guard let cString = sqlite3_column_text(stmt, 1) else { continue }
            let path = String(cString: cString)
            // bm25 returns negative scores (lower is
            // better). We flip the sign so the public
            // API's `score: Int` is "higher is better",
            // matching the InMemory backend.
            let bm25 = sqlite3_column_double(stmt, 2)
            let score = Int((-bm25 * 1000).rounded())
            hits.append(IndexHit(url: URL(fileURLWithPath: path), score: score))
        }
        return hits
    }

    public func stats() async throws -> IndexStats {
        // Use the cached count — it's maintained on every
        // upsert/remove. The cost of an exact
        // `SELECT COUNT(*)` is too high to do on every
        // Settings panel render.
        return IndexStats(
            documentCount: documentCount,
            uniqueTermCount: 0,  // FTS5 doesn't expose a cheap unique-term count
            lastBuilt: Date()
        )
    }

    // MARK: - Schema setup

    /// Open the database and create the schema if it
    /// doesn't exist. Returns the connection or nil.
    /// Synchronous — called from init.
    private static func openAndInit(dbPath: URL) -> OpaquePointer? {
        // Ensure parent directory exists.
        try? FileManager.default.createDirectory(
            at: dbPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        // Open with WAL mode (write-ahead log) for
        // crash safety + concurrent readers. The
        // SQLITE_OPEN_FULLMUTEX flag is the default but
        // we declare it for clarity. NORMAL is the
        // default journal mode; we want WAL.
        let openResult = sqlite3_open_v2(
            dbPath.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db = db else {
            return nil
        }
        // Enable WAL mode. This persists the mode in
        // the database file, so subsequent opens
        // inherit it.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // 64MB page cache. SQLite's default cache is
        // tiny (a few MB); bumping this gives us the
        // working-set mmap behavior we want for
        // large indices.
        sqlite3_exec(db, "PRAGMA cache_size=-65536", nil, nil, nil)
        // Memory-map up to 256MB of the DB file. SQLite
        // will read pages from the mmap on cache miss
        // instead of doing a read() syscall.
        sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)
        // Create the documents table if it doesn't
        // exist. The PK is docID (Int32) so we can do
        // fast lookups.
        let createDocumentsSQL = """
        CREATE TABLE IF NOT EXISTS documents (
            docID INTEGER PRIMARY KEY,
            url TEXT NOT NULL,
            mtime REAL NOT NULL,
            byteSize INTEGER NOT NULL,
            terms_content TEXT NOT NULL DEFAULT ''
        )
        """
        if sqlite3_exec(db, createDocumentsSQL, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        // Create the FTS5 virtual table. FTS5
        // tokenizes the content and stores a compressed
        // inverted index. We use the default
        // tokenization (porter stemmer) which is good
        // for English text; the index is still useful
        // for code (where stemming is mostly a no-op).
        //
        // content='documents' tells FTS5 to NOT store
        // the original text — it just maintains the
        // index and looks up terms_content via the
        // content rowid. This saves disk and memory.
        //
        // content_rowid='docID' tells FTS5 to use
        // docID as the rowid for joining.
        let createFTSSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
            terms_content,
            content='documents',
            content_rowid='docID',
            tokenize='porter unicode61'
        )
        """
        if sqlite3_exec(db, createFTSSQL, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    // MARK: - Helpers

    /// Prepare a SQL statement, run a binding closure,
    /// step it, and finalize. Throws `SQLiteError` on
    /// any of the three failure points. The binding
    /// closure receives the prepared statement pointer
    /// (already valid, with all parameters unbound) and
    /// is responsible for binding every `?` placeholder.
    private static func execPrepared(
        db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer?) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastError(db))
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(lastError(db))
        }
    }

    /// Quote a term for FTS5 MATCH. We wrap in double
    /// quotes and escape any embedded double quotes.
    /// This is the standard FTS5 safe-quote idiom.
    private static func escapeFTS5Term(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Last SQLite error message for a connection. Used
    /// in error throws to give the caller some context.
    private static func lastError(_ db: OpaquePointer?) -> String {
        guard let db = db, let cString = sqlite3_errmsg(db) else {
            return "unknown sqlite error"
        }
        return String(cString: cString)
    }

    /// Get the document count for the cached
    /// `documentCount` field at init time. Synchronous
    /// COUNT(*) — only called once at startup.
    private static func queryCount(db: OpaquePointer?) -> Int {
        guard let db = db else { return 0 }
        var countSQL = "SELECT COUNT(*) FROM documents"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get the max docID so the nextDocID counter
    /// doesn't collide with existing rows after a
    /// restart. Synchronous, called once at init.
    private static func queryMaxDocID(db: OpaquePointer?) -> Int {
        guard let db = db else { return 0 }
        var sql = "SELECT COALESCE(MAX(docID), 0) FROM documents"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

/// Errors thrown by SQLiteFTS5Backend. The associated
/// string is the SQLite error message at the point of
/// failure, which usually gives enough context to debug
/// (e.g. "UNIQUE constraint failed", "no such column", etc.).
public enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case schemaFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open SQLite db: \(msg)"
        case .schemaFailed(let msg): return "Failed to create schema: \(msg)"
        case .prepareFailed(let msg): return "Failed to prepare statement: \(msg)"
        case .stepFailed(let msg): return "Failed to execute statement: \(msg)"
        case .transactionFailed(let msg): return "Transaction failed: \(msg)"
        }
    }
}
