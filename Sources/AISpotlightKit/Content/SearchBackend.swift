import Foundation

/// A search backend for the content index. The plan is
/// to have multiple implementations:
/// - `InMemorySearchBackend` — current Set<Int32>
///   implementation. Fast, simple, but ~5GB RSS at 80k
///   files due to Swift Set hash table overhead.
/// - `SQLiteFTS5Backend` — SQLite-backed. ~50-100MB RSS
///   at 500k files because SQLite uses mmap + page cache
///   and FTS5 has compressed inverted indexes built in.
///
/// The public API of `SearchBackend` is intentionally
/// minimal — just `upsert`, `query`, `bulkLoad`,
/// `remove`, `purge`, and `stats`. The actor wrapping is
/// the caller's responsibility (e.g. `IndexStore` actor
/// delegates to a `SearchBackend` instance).
///
/// The protocol is async to allow for I/O (SQLite needs
/// async dispatch to a serial queue or to use
/// `sqlite3_step` from a background actor). The
/// in-memory backend's async functions are essentially
/// synchronous (no `await` needed for in-memory work),
/// but the API shape is the same so callers don't have
/// to special-case the two backends.
public protocol SearchBackend: Sendable {
    /// Insert or replace a document's term set. The docID
    /// is allocated by the backend (monotonically
    /// increasing per session). Returns the allocated
    /// docID so the caller can later remove or look up
    /// the document.
    func upsert(_ doc: IndexDocument, terms: Set<String>) async throws -> Int32

    /// Bulk-load the term index from a doc → terms map.
    /// Used by the indexer when re-building from scratch.
    /// Does NOT trigger a persist — call `persist` explicitly.
    func bulkLoad(_ docs: [(Int32, IndexDocument, Set<String>)]) async throws

    /// Remove a document. No-op if the URL wasn't indexed.
    func remove(_ url: URL) async throws

    /// Empty all state. The next `bulkLoad` (or `upsert`)
    /// call repopulates.
    func purge() async throws

    /// Persist in-memory state to disk. Atomic write.
    func persist() async throws

    /// Return documents matching ANY of the query terms,
    /// sorted by match count (descending). Resolved URLs
    /// (the docID → URL lookup happens internally).
    func query(_ terms: [String], limit: Int) async throws -> [IndexHit]

    /// Cheap aggregate counts.
    func stats() async throws -> IndexStats
}
