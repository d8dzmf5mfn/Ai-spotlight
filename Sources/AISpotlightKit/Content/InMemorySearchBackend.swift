import Foundation

/// In-memory implementation of `SearchBackend`. Wraps the
/// Set<Int32> inverted index from Phase 4.2.7's DocID
/// refactor. ~5GB RSS at 80k files (Swift Set hash table
/// overhead), but fast (no I/O) and easy to test.
///
/// The SQLite FTS5 backend is the recommended replacement
/// for production (Phase 4.2.8). This in-memory backend
/// is the default during development and tests because
/// it requires no external dependencies.
public actor InMemorySearchBackend: SearchBackend {
    /// DocID → IndexDocument. URLs live inside IndexDocument.
    private var documents: [Int32: IndexDocument] = [:]
    /// Reverse index: docID → its terms.
    private var documentToTerms: [Int32: Set<String>] = [:]
    /// Inverted index: term → docIDs. The hot path for queries.
    private var terms: [String: Set<Int32>] = [:]
    /// URL → DocID map. Bounded by file count, not posting count.
    private var urlToDocID: [URL: Int32] = [:]
    /// Monotonic DocID counter. Never reused within a session.
    private var nextDocID: Int32 = 1
    /// Build timestamp.
    private var built: Date = .distantPast
    /// The path to write the index JSON to. None = in-memory only.
    private let diskPath: URL?

    public init(diskPath: URL? = nil) {
        self.diskPath = diskPath
        if let path = diskPath,
           let data = try? Data(contentsOf: path),
           let snapshot = try? JSONDecoder.snapshotDecoder.decode(IndexSnapshot.self, from: data) {
            rehydrate(from: snapshot)
        }
    }

    public func upsert(_ doc: IndexDocument, terms docTerms: Set<String>) async throws -> Int32 {
        // Resolve or allocate DocID
        let docID: Int32
        if let existing = urlToDocID[doc.url] {
            docID = existing
        } else {
            docID = nextDocID
            nextDocID &+= 1
            urlToDocID[doc.url] = docID
        }
        // Evict old terms if any
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
        if !docTerms.isEmpty {
            documentToTerms[docID] = docTerms
            for t in docTerms {
                self.terms[t, default: []].insert(docID)
            }
        }
        built = Date()
        return docID
    }

    public func bulkLoad(_ docs: [(Int32, IndexDocument, Set<String>)]) async throws {
        try await purge()
        for (docID, doc, docTerms) in docs {
            documents[docID] = doc
            urlToDocID[doc.url] = docID
            documentToTerms[docID] = docTerms
            for t in docTerms {
                self.terms[t, default: []].insert(docID)
            }
        }
        nextDocID = (docs.map { $0.0 }.max() ?? 0) &+ 1
        built = Date()
    }

    public func remove(_ url: URL) async throws {
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

    public func purge() async throws {
        documents.removeAll()
        documentToTerms.removeAll()
        terms.removeAll()
        urlToDocID.removeAll()
        nextDocID = 1
        built = .distantPast
    }

    public func persist() async throws {
        guard let path = diskPath else { return }
        let snapshot = IndexSnapshot.from(documents: documents, documentToTerms: documentToTerms)
        let data = try JSONEncoder.snapshotEncoder.encode(snapshot)
        try data.write(to: path, options: .atomic)
    }

    public func query(_ queryTerms: [String], limit: Int) async throws -> [IndexHit] {
        var scoreByDocID: [Int32: Int] = [:]
        for term in queryTerms where !term.isEmpty {
            if let ids = self.terms[term] {
                for id in ids {
                    scoreByDocID[id, default: 0] += 1
                }
            }
        }
        let sorted = scoreByDocID.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        return sorted.prefix(limit).compactMap { (docID, score) -> IndexHit? in
            guard let url = documents[docID]?.url else { return nil }
            return IndexHit(url: url, score: score)
        }
    }

    public func stats() async throws -> IndexStats {
        IndexStats(
            documentCount: documents.count,
            uniqueTermCount: terms.count,
            lastBuilt: built
        )
    }

    /// Re-hydrate from a persisted snapshot. Called by init.
    private func rehydrate(from snapshot: IndexSnapshot) {
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

// MARK: - JSONEncoder/Decoder helpers

extension JSONEncoder {
    /// Shared encoder for IndexSnapshot persistence.
    /// Sorts keys for deterministic output (helps tests
    /// and on-disk diffs).
    static var snapshotEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    /// Shared decoder for IndexSnapshot loading.
    static var snapshotDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
