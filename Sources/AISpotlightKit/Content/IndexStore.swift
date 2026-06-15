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
public struct IndexSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion: Int = 1

    public let version: Int
    public let documents: [IndexDocument]
    /// Persisted inverted index: term → list of URLs containing it.
    /// Stored so reloads preserve searchability without forcing the
    /// indexer to re-walk the filesystem.
    public let terms: [String: [URL]]
    /// The build timestamp. UI surfaces this in Settings ("Last built").
    public let built: Date

    public init(version: Int = IndexSnapshot.currentVersion,
                documents: [IndexDocument],
                terms: [String: [URL]] = [:],
                built: Date = Date()) {
        self.version = version
        self.documents = documents
        self.terms = terms
        self.built = built
    }

    /// Empty snapshot (used when no index file exists on disk yet).
    public static let empty = IndexSnapshot(documents: [], terms: [:], built: .distantPast)

    /// Render the in-memory index to a snapshot. The terms dict is
    /// derived from the per-document term sets, so callers don't have
    /// to keep two structures in sync when calling this.
    public static func from(documents: [IndexDocument],
                            documentToTerms: [URL: Set<String>]) -> IndexSnapshot {
        // Build the inverted index from the per-doc terms. We sort
        // each URL set for deterministic JSON output.
        var terms: [String: [URL]] = [:]
        for (url, docTerms) in documentToTerms {
            for t in docTerms {
                terms[t, default: []].append(url)
            }
        }
        for (t, urls) in terms {
            terms[t] = urls.sorted { $0.path < $1.path }
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
/// Storage shape:
/// - `documents: [URL: IndexDocument]` — one entry per file we've seen
/// - `documentToTerms: [URL: Set<String>]` — the reverse mapping
/// - `terms: [String: Set<URL>]` — the inverted index (term → files)
///
/// We hold two maps rather than just `terms` so `remove(url)` can
/// find the doc's terms without scanning every term's URL set.
///
/// `actor` because the indexer runs off the main thread and the
/// search code may be called from the main thread; we need a memory
/// barrier to keep the maps consistent.
///
/// **Phase 3.1.1**: bare-bones store. Subsequent tasks (3.1.3
/// ContentIndexer, 3.1.4 ContentSearchProvider) will use this.
public actor IndexStore {
    /// The on-disk path. `.applicationSupportDirectory/AISpotlight/index.json`
    /// in production; tmp file in tests.
    public let diskPath: URL

    /// The persisted metadata for each indexed file. Insertion order
    /// is preserved (Swift Dictionary is order-preserving), which we
    /// rely on for tie-breaking in queries.
    private var documents: [URL: IndexDocument] = [:]
    /// Reverse index: doc → its terms. Used by `remove(url)` to know
    /// which terms to evict.
    private var documentToTerms: [URL: Set<String>] = [:]
    /// Inverted index: term → docs. This is the hot path for queries.
    private var terms: [String: Set<URL>] = [:]
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
        // Rehydrate in-memory state from the loaded snapshot. We can't
        // call rehydrate from inside init before all stored properties
        // are initialized, so we re-do the loop inline. (The duplication
        // is intentional — we want the actor's state set up by the
        // time the init returns.)
        for doc in snapshot.documents {
            self.documents[doc.url] = doc
        }
        for (term, urls) in snapshot.terms {
            self.terms[term] = Set(urls)
            for url in urls {
                self.documentToTerms[url, default: []].insert(term)
            }
        }
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
    public func bulkLoad(_ docs: [URL: (IndexDocument, Set<String>)]) {
        purge()
        for (url, (doc, docTerms)) in docs {
            documents[url] = doc
            documentToTerms[url] = docTerms
            for term in docTerms {
                terms[term, default: []].insert(url)
            }
        }
        built = Date()
    }

    /// Empty all in-memory state. The next `bulkLoad` (or `upsert`)
    /// call repopulates. Persisted file is not touched.
    public func purge() {
        documents.removeAll()
        documentToTerms.removeAll()
        terms.removeAll()
        built = .distantPast
    }

    /// Insert or replace a document's term set. If the URL is
    /// already present, its old terms are evicted from the inverted
    /// index first (so stale terms never linger).
    public func upsert(_ doc: IndexDocument, terms docTerms: Set<String>) {
        // Evict old terms if this URL was already indexed.
        if let old = documentToTerms.removeValue(forKey: doc.url) {
            for t in old {
                if var urls = self.terms[t] {
                    urls.remove(doc.url)
                    if urls.isEmpty {
                        self.terms.removeValue(forKey: t)
                    } else {
                        self.terms[t] = urls
                    }
                }
            }
        }
        documents[doc.url] = doc
        if docTerms.isEmpty {
            documentToTerms.removeValue(forKey: doc.url)
        } else {
            documentToTerms[doc.url] = docTerms
            for t in docTerms {
                self.terms[t, default: []].insert(doc.url)
            }
        }
        built = Date()
    }

    /// Remove a document. After this, the URL should not match any
    /// query. No-op if the URL wasn't indexed.
    public func remove(_ url: URL) {
        guard documents.removeValue(forKey: url) != nil else { return }
        guard let old = documentToTerms.removeValue(forKey: url) else { return }
        for t in old {
            if var urls = self.terms[t] {
                urls.remove(url)
                if urls.isEmpty {
                    self.terms.removeValue(forKey: t)
                } else {
                    self.terms[t] = urls
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
        var scoreByURL: [URL: Int] = [:]
        for term in queryTerms where !term.isEmpty {
            if let urls = self.terms[term] {
                for url in urls {
                    scoreByURL[url, default: 0] += 1
                }
            }
        }
        // Sort by score desc, then by URL string for stable ordering.
        let sorted = scoreByURL.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.path < rhs.key.path
        }
        let sliced = sorted.prefix(limit)
        return sliced.map { IndexHit(url: $0.key, score: $0.value) }
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
            documents: Array(documents.values),
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
        for doc in snapshot.documents {
            documents[doc.url] = doc
        }
        for (term, urls) in snapshot.terms {
            terms[term] = Set(urls)
            for url in urls {
                documentToTerms[url, default: []].insert(term)
            }
        }
        built = snapshot.built
    }
}
