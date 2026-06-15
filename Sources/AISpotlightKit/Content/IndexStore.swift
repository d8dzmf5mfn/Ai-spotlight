import Foundation

/// One indexed file. Stored in the in-memory inverted index and on
/// disk as part of an `IndexSnapshot`. `mtime` and `byteSize` are
/// cached so the indexer can decide "skip this file" without
/// re-reading it on every launch.
public struct IndexDocument: Codable, Equatable, Sendable {
    public let url: URL
    public let mtime: Date
    public let byteSize: Int

    public init(url: URL, mtime: Date, byteSize: Int) {
        self.url = url
        self.mtime = mtime
        self.byteSize = byteSize
    }
}

/// A snapshot of the index, suitable for JSON encoding. The schema
/// version is bumped when the storage shape changes incompatibly; a
/// future `load(from:)` can reject mismatches.
///
/// **Schema v2 (Phase 4.2.7)**: the inverted index now uses
/// `Set<Int32>` (DocID) instead of `Set<URL>`. URLs live in the
/// `documents` table keyed by DocID. This shrinks the
/// 5GB-on-80k-files blow-up down to ~500MB. The on-disk JSON
/// format changed (we serialize `terms: [String: [Int32]]` and
/// `documents: [Int32: IndexDocument]` keyed by Int32), so we
/// bumped the version. A future v1-snapshot file would be
/// rejected on load; we don't need to migrate it because
/// pre-Phase 4.2.7 indices were small (Documents only, 16 files).
public struct IndexSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion: Int = 2

    public let version: Int
    /// DocID → IndexDocument. The URL is inside IndexDocument.
    /// Keying by Int32 (DocID) instead of URL means the
    /// dictionary hash + comparison is O(1) on a 4-byte integer
    /// instead of O(URL.length) on a 100-byte struct.
    public let documents: [Int32: IndexDocument]
    /// Inverted index: term → DocIDs containing it.
    /// The hot path for queries. Storing `[Int32]` instead of
    /// `[URL]` is the core 10x RSS win: each Int32 is 4 bytes
    /// (plus Set hash overhead) instead of 100+ bytes per URL.
    public let terms: [String: [Int32]]
    /// The build timestamp. UI surfaces this in Settings ("Last built").
    public let built: Date

    public init(version: Int = IndexSnapshot.currentVersion,
                documents: [Int32: IndexDocument],
                terms: [String: [Int32]] = [:],
                built: Date = Date()) {
        self.version = version
        self.documents = documents
        self.terms = terms
        self.built = built
    }

    /// Empty snapshot (used when no index file exists on disk yet).
    public static let empty = IndexSnapshot(documents: [:], terms: [:], built: .distantPast)

    /// Render the in-memory index to a snapshot. The terms dict is
    /// derived from the per-document term sets, so callers don't have
    /// to keep two structures in sync when calling this.
    public static func from(documents: [Int32: IndexDocument],
                            documentToTerms: [Int32: Set<String>]) -> IndexSnapshot {
        // Build the inverted index from the per-doc terms. We sort
        // each DocID set for deterministic JSON output.
        var terms: [String: [Int32]] = [:]
        for (docID, docTerms) in documentToTerms {
            for t in docTerms {
                terms[t, default: []].append(docID)
            }
        }
        for (t, ids) in terms {
            terms[t] = ids.sorted()
        }
        return IndexSnapshot(documents: documents, terms: terms)
    }
}

/// A hit returned by `IndexStore.query(...)`. `score` is the number
/// of query terms that matched the document (so a document matching
/// two terms scores 2; ties break by document order in the snapshot,
/// which preserves insertion-order recency).
public struct IndexHit: Equatable, Sendable {
    public let url: URL
    public let score: Int
}

/// Aggregate counts for the Settings UI ("Indexed 1,234 files, 45,678
/// unique terms"). Cheap to compute (just dictionary sizes).
public struct IndexStats: Equatable, Sendable {
    public let documentCount: Int
    public let uniqueTermCount: Int
    public let lastBuilt: Date

    public static let empty = IndexStats(documentCount: 0, uniqueTermCount: 0, lastBuilt: .distantPast)
}

/// In-memory inverted index for Phase 3.1 ContentSearchProvider.
///
/// Storage shape (Phase 4.2.7 DocID refactor):
/// - `documents: [Int32: IndexDocument]` — DocID → doc, where
///   the URL is inside IndexDocument. Keying by Int32 instead
///   of URL shrinks the dictionary overhead by ~25x (4 bytes
///   hash key vs ~100 byte URL hash key).
/// - `documentToTerms: [Int32: Set<String>]` — reverse map
///   for O(1) eviction in `remove(docID)`.
/// - `terms: [String: Set<Int32>]` — the inverted index,
///   now with Int32 postings. Same 25x shrinkage in the
///   posting lists.
/// - `urlToDocID: [URL: Int32]` — a side map so callers can
///   pass URL (the natural input — it's a file path!) and
///   we look up the DocID internally. Inserts/lookups are
///   O(1) but the URL is only stored in this map, not in
///   the hot posting lists.
///
/// Why this is a 10x RSS win:
/// Old: `Set<URL>` with 13.6M postings (74k files × 50 terms)
///      = 13.6M × 100 byte URL = 1.3GB just for the URLs,
///      plus Set hash overhead = 4-5GB RSS.
/// New: `Set<Int32>` with 13.6M postings
///      = 13.6M × 4 byte Int32 = 55MB for the integers,
///      plus Set hash overhead = 200-500MB RSS.
///
/// `actor` because the indexer runs off the main thread and the
/// search code may be called from the main thread; we need a memory
/// barrier to keep the maps consistent.
///
/// **Phase 3.1.1**: bare-bones store. Subsequent tasks (3.1.3
/// ContentIndexer, 3.1.4 ContentSearchProvider) will use this.
/// **Phase 4.2.7**: DocID refactor for 10x RSS win.
public actor IndexStore {
    /// The on-disk path. `.applicationSupportDirectory/AISpotlight/index.json`
    /// in production; tmp file in tests.
    public let diskPath: URL

    /// The persisted metadata for each indexed file, keyed by
    /// DocID. Insertion order is preserved (Swift Dictionary
    /// is order-preserving), which we rely on for tie-breaking
    /// in queries.
    private var documents: [Int32: IndexDocument] = [:]
    /// Reverse index: docID → its terms. Used by `remove(docID)`
    /// to know which terms to evict.
    private var documentToTerms: [Int32: Set<String>] = [:]
    /// Inverted index: term → docIDs. The hot path for queries.
    private var terms: [String: Set<Int32>] = [:]
    /// URL → DocID map. The URL is the natural key for callers
    /// (it's a file path), so we look up the DocID at the
    /// boundary. Storing the URL here doesn't add to the hot
    /// posting list overhead — this map is bounded by the
    /// number of distinct files, not the number of postings.
    private var urlToDocID: [URL: Int32] = [:]
    /// Monotonically-increasing DocID counter. We never reuse
    /// IDs within a session (so even if a file is removed and
    /// re-added, it gets a new ID — and the old terms are
    /// cleanly evicted first). For 500k files we need IDs up to
    /// ~500k, well within Int32 range (2.1 billion).
    private var nextDocID: Int32 = 1
    /// Build timestamp (refreshed on every `upsert`/`remove`).
    private var built: Date = .distantPast

    /// Per-extension text extractors. Default is empty (Core has no
    /// AppKit-bridged extractors). The App target injects
    /// `RichTextExtractor`-backed dispatchers for `.rtf`, `.rtfd`,
    /// `.html`, `.htm`. See `ExtensionTextDispatcher`.
    public var dispatchers: [String: any ExtensionTextDispatcher] = [:]

    /// Load the on-disk snapshot if it exists; otherwise start empty.
    /// The disk file is **read once** at init; subsequent calls to
    /// `upsert`/`remove`/`persist` operate on the in-memory copy.
    public init(diskPath: URL) throws {
        self.diskPath = diskPath
        let snapshot = (try? Self.loadSnapshot(from: diskPath)) ?? .empty
        // Rehydrate in-memory state from the loaded snapshot. The
        // snapshot now uses DocID keying (v2 schema).
        for (docID, doc) in snapshot.documents {
            self.documents[docID] = doc
            self.urlToDocID[doc.url] = docID
        }
        for (term, ids) in snapshot.terms {
            self.terms[term] = Set(ids)
            for id in ids {
                // documentToTerms is rebuilt from documents;
                // if a doc is missing from snapshot.documents
                // (shouldn't happen but defensive), we still
                // index the term so queries don't return orphan
                // IDs.
                self.documentToTerms[id, default: []].insert(term)
            }
        }
        // Bump nextDocID past the highest ID we loaded.
        self.nextDocID = (snapshot.documents.keys.max() ?? 0) &+ 1
        self.built = snapshot.built
        // If the App target has registered AppKit-bridged dispatchers
        // (RTF / HTML extraction), inherit them into this store.
        // The App target calls into the static stash before creating
        // an IndexStore; we just copy it into our own `dispatchers`
        // map.
        self.dispatchers = IndexStore.pendingDispatchers
    }

    /// Static stash for dispatcher registrations. The App target
    /// (which can import AppKit) writes into this before creating an
    /// IndexStore; the Core IndexStore reads from it in its init.
    public static var pendingDispatchers: [String: any ExtensionTextDispatcher] = [:]

    /// Bulk-load the term index from a doc → terms map. Used by the
    /// indexer when re-building from scratch (faster than calling
    /// `upsert` per-doc, which would also rewrite the on-disk file
    /// after every call). Does NOT trigger a `persist` — call that
    /// explicitly when the bulk operation is complete.
    ///
    /// The key is DocID (Int32) so we can skip the URL→DocID
    /// lookup during bulk loads. The caller is responsible for
    /// allocating DocIDs that don't collide with existing ones
    /// (we start at `nextDocID`).
    public func bulkLoad(_ docs: [Int32: (IndexDocument, Set<String>)]) {
        purge()
        for (docID, (doc, docTerms)) in docs {
            documents[docID] = doc
            urlToDocID[doc.url] = docID
            documentToTerms[docID] = docTerms
            for term in docTerms {
                terms[term, default: []].insert(docID)
            }
        }
        // Bump nextDocID past the highest ID we loaded.
        nextDocID = (docs.keys.max() ?? 0) &+ 1
        built = Date()
    }

    /// Empty all in-memory state. The next `bulkLoad` (or `upsert`)
    /// call repopulates. Persisted file is not touched.
    public func purge() {
        documents.removeAll()
        documentToTerms.removeAll()
        terms.removeAll()
        urlToDocID.removeAll()
        nextDocID = 1
        built = .distantPast
    }

    /// Insert or replace a document's term set. The URL is
    /// the natural key from the caller's perspective; we
    /// look up (or allocate) the DocID internally. If the
    /// URL is already present, its old terms are evicted
    /// from the inverted index first (so stale terms
    /// never linger).
    public func upsert(_ doc: IndexDocument, terms docTerms: Set<String>) {
        // Resolve DocID for this URL: reuse if present, else
        // allocate a new one. We never reuse a DocID within
        // a session — see the comment on `nextDocID`.
        let docID: Int32
        if let existing = urlToDocID[doc.url] {
            docID = existing
        } else {
            docID = nextDocID
            nextDocID &+= 1
            urlToDocID[doc.url] = docID
        }

        // Evict old terms if this DocID was already indexed.
        if let old = documentToTerms.removeValue(forKey: docID) {
            for t in old {
                if var ids = self.terms[t] {
                    ids.remove(docID)
                    if ids.isEmpty {
                        self.terms.removeValue(forKey: t)
                    } else {
                        self.terms[t] = ids
                    }
                }
            }
        }
        documents[docID] = doc
        if docTerms.isEmpty {
            documentToTerms.removeValue(forKey: docID)
        } else {
            documentToTerms[docID] = docTerms
            for t in docTerms {
                self.terms[t, default: []].insert(docID)
            }
        }
        built = Date()
    }

    /// Remove a document. After this, the URL should not match any
    /// query. No-op if the URL wasn't indexed.
    public func remove(_ url: URL) {
        // Look up the DocID first. If the URL was never indexed,
        // this is a no-op.
        guard let docID = urlToDocID.removeValue(forKey: url) else { return }
        guard documents.removeValue(forKey: docID) != nil else { return }
        guard let old = documentToTerms.removeValue(forKey: docID) else { return }
        for t in old {
            if var ids = self.terms[t] {
                ids.remove(docID)
                if ids.isEmpty {
                    self.terms.removeValue(forKey: t)
                } else {
                    self.terms[t] = ids
                }
            }
        }
        built = Date()
    }

    /// Return documents matching ANY of the query terms, sorted by
    /// match count (descending). The caller is expected to apply
    /// LLM re-ranking on top; this is the BM25-style baseline.
    public func query(_ queryTerms: [String], limit: Int) -> [IndexHit] {
        // Score = number of distinct query terms that hit the document.
        // Keyed by DocID for O(1) accumulation; we resolve URLs
        // from the documents table at the end. This keeps the
        // hot loop free of URL hashing.
        var scoreByDocID: [Int32: Int] = [:]
        for term in queryTerms where !term.isEmpty {
            if let ids = self.terms[term] {
                for id in ids {
                    scoreByDocID[id, default: 0] += 1
                }
            }
        }
        // Sort by score desc, then by DocID for stable ordering.
        let sorted = scoreByDocID.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let sliced = sorted.prefix(limit)
        return sliced.compactMap { (docID, score) -> IndexHit? in
            guard let url = documents[docID]?.url else { return nil }
            return IndexHit(url: url, score: score)
        }
    }

    /// Cheap aggregate counts for the Settings dashboard.
    public func stats() -> IndexStats {
        IndexStats(
            documentCount: documents.count,
            uniqueTermCount: terms.count,
            lastBuilt: built
        )
    }

    /// Persist the current in-memory state to disk as JSON. Atomic
    /// write (write to a temp file, then rename) so a crash mid-write
    /// doesn't corrupt the on-disk index.
    public func persist(to path: URL) throws {
        let snapshot = IndexSnapshot.from(
            documents: documents,
            documentToTerms: documentToTerms
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        // Ensure the parent directory exists (e.g. `~/Library/Application Support/AISpotlight/`).
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Atomic write via temp + rename.
        let tmp = path.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // If destination exists, FileManager.replaceItemAt is atomic;
        // if not, a simple move works. We use FileManager.default.replaceItemAt
        // for both cases via the URL overload that doesn't fail when the
        // destination is absent.
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }

    /// Convenience: persist to the path the store was initialized with.
    public func persist() throws {
        try persist(to: diskPath)
    }

    // MARK: - Disk format

    private static func loadSnapshot(from path: URL) throws -> IndexSnapshot {
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(IndexSnapshot.self, from: data)
        return snapshot
    }

    /// Populate the in-memory inverted index from a loaded snapshot.
    /// Called once at init time, after the disk read. The snapshot's
    /// `terms` dict is the source of truth; we rebuild
    /// `documentToTerms` from it (so we have both forward and reverse
    /// indexes for fast upsert/remove).
    private func rehydrate(from snapshot: IndexSnapshot) {
        documents.removeAll()
        documentToTerms.removeAll()
        terms.removeAll()
        urlToDocID.removeAll()
        nextDocID = 1
        for (docID, doc) in snapshot.documents {
            documents[docID] = doc
            urlToDocID[doc.url] = docID
        }
        for (term, ids) in snapshot.terms {
            terms[term] = Set(ids)
            for id in ids {
                documentToTerms[id, default: []].insert(term)
            }
        }
        nextDocID = (snapshot.documents.keys.max() ?? 0) &+ 1
        built = snapshot.built
    }
}
