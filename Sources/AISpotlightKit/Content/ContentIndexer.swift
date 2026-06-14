import Foundation

/// Aggregate counts surfaced to the Settings UI ("Rebuilding
/// index… 1,234 / 5,678"). Cheap to read; updated by `ContentIndexer`
/// as it walks the directory.
public struct IndexProgress: Equatable, Sendable {
    public let filesScanned: Int
    public let filesIndexed: Int
    public let filesSkipped: Int
    public let filesRemoved: Int

    public static let empty = IndexProgress(filesScanned: 0, filesIndexed: 0, filesSkipped: 0, filesRemoved: 0)
}

/// Walks a directory tree, decides which files need (re-)indexing,
/// and feeds `IndexStore` via `bulkLoad` (full rebuild) or
/// `upsert`/`remove` (incremental).
///
/// `actor` because the indexer runs off the main thread and may
/// overlap with the search code (which calls `query`/`stats`).
public actor ContentIndexer {

    /// The inverted-index store this indexer writes into.
    private let store: IndexStore

    /// Directories we always skip. Hidden files (`.foo`) are also
    /// skipped via `FileManager` enumeration options.
    private static let blockedDirNames: Set<String> = [
        ".git", ".next", ".venv", "__pycache__",
        "node_modules", "build", "dist", "target",
        ".swiftpm", ".build",
    ]

    public init(store: IndexStore) {
        self.store = store
        self.ourOwnIndexPath = store.diskPath
    }

    /// Walk `roots` and update the index incrementally. Returns
    /// aggregate counts for the UI.
    ///
    /// Algorithm:
    /// 1. Enumerate every file under `roots`, skipping hidden and
    ///    blocked dirs.
    /// 2. For each file, decide `add | update | skip | remove` by
    ///    comparing with the current index:
    ///    - New file (not in store) → tokenize + upsert
    ///    - Existing file with newer mtime → tokenize + upsert (replaces)
    ///    - Existing file with same mtime → skip
    /// 3. Files in store but no longer on disk → remove.
    /// 4. Persist to disk at the end.
    public func index(roots: [URL]) async -> IndexProgress {
        await ensureLocalCachesLoaded()
        var scanned = 0
        var indexed = 0
        var skipped = 0
        var removed = 0

        // Pass 1: walk the filesystem, decide action per file.
        let decisions = decisionsForRoots(roots)
        scanned = decisions.count

        // Track which URLs we saw on disk this pass — anything in
        // `existingDocumentMtimes` (pre-load from disk) but not in
        // `decisions` was deleted from the filesystem and needs to be
        // removed from the index. We collect the seen-URLs into a Set
        // here rather than threading it through `decisions` because
        // the seen set is large and we already have a local cache.
        var seenThisPass: Set<URL> = []
        for d in decisions { seenThisPass.insert(d.url) }

        // Pass 2: apply decisions in batch — group by action so we
        // make fewer actor hops.
        let toUpsert = decisions.filter {
            if case .add = $0.action { return true }
            if case .update = $0.action { return true }
            return false
        }
        let toRemoveFromDisk = decisions.compactMap { d -> URL? in
            if case .remove = d.action { return d.url }
            return nil
        }
        skipped = decisions.filter {
            if case .skip = $0.action { return true }
            return false
        }.count

        for d in toUpsert {
            do {
                try await ingest(d.url)
                indexed += 1
            } catch {
                // Read failed (file locked, encoding error, etc.) —
                // skip silently. We could log via `Log.write` but the
                // indexer is in the Kit and we don't want a hard dep.
                skipped += 1
            }
        }

        // Remove files that were marked for removal by the walker
        // (currently unused, but the pipeline is in place for future
        // pass-3 logic).
        for url in toRemoveFromDisk {
            await store.remove(url)
            removed += 1
        }

        // Pass 3: find URLs in the existing cache that weren't seen
        // on disk this pass. These are files the user deleted between
        // index runs. We removed them from the store and from our
        // local cache.
        //
        // Note: `existingDocumentMtimes` is a snapshot of the disk
        // index at `ensureLocalCachesLoaded` time. Files added by THIS
        // pass (via `ingest`) are not in that map yet (we add them
        // after `upsert` returns). So the set difference here is
        // exactly "files that were in the index but aren't on disk now".
        let deletedURLs = Set(existingDocumentMtimes.keys).subtracting(seenThisPass)
        for url in deletedURLs {
            await store.remove(url)
            existingDocumentMtimes.removeValue(forKey: url)
            existingDocumentSizes.removeValue(forKey: url)
            removed += 1
        }

        // Persist at the end so a crash mid-walk doesn't leave the
        // index half-updated.
        try? await store.persist()

        return IndexProgress(
            filesScanned: scanned,
            filesIndexed: indexed,
            filesSkipped: skipped,
            filesRemoved: removed
        )
    }

    // MARK: - Decision phase

    private enum Action: Equatable { case add, update, skip, remove }

    private struct Decision {
        let url: URL
        let action: Action
    }

    private func decisionsForRoots(_ roots: [URL]) -> [Decision] {
        var decisions: [Decision] = []
        for root in roots {
            walk(root, into: &decisions)
        }
        return decisions
    }

    /// Recursive walk. Skips blocked directories **before** descending
    /// into them (so the entire subtree is excluded in one shot).
    private func walk(_ dir: URL, into decisions: inout [Decision]) {
        // Reject blocked dirs at the top level too — e.g. the user
        // might point at `~/code` which contains a `node_modules` we
        // should skip entirely.
        let basename = dir.lastPathComponent
        if basename.hasPrefix(".") && basename != "." {
            // Hidden entry at any level (e.g. .git, .build, .DS_Store)
            // — skip the whole subtree. The top-level "root" passed
            // in is the user's home directory, which is itself a
            // hidden file's parent; we don't filter at the root.
            return
        }
        if Self.blockedDirNames.contains(basename) {
            return
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            return  // unreadable dir — skip
        }

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                walk(url, into: &decisions)
                continue
            }
            // Skip the index file itself. The store's persistence writes
            // its `index.json` (or whatever path was passed in) to disk;
            // if the user's `roots` includes the parent directory, the
            // next index walk would otherwise re-index the index file,
            // which is both wasteful and a feedback loop (each rebuild
            // makes the index file slightly larger, which makes the
            // next index file larger...).
            //
            // We compare via `standardizedFileURL` because the path the
            // user passed to `IndexStore.init` may be a symlinked form
            // (e.g. `/var/...`) while `FileManager` enumeration returns
            // the resolved form (e.g. `/private/var/...`). String
            // equality on the path won't match in that case.
            if url.standardizedFileURL == self.ourOwnIndexPath.standardizedFileURL { continue }
            if !TextExtractor.isIndexable(url: url) { continue }
            // Get mtime + size for change detection
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attrs,
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { continue }
            decisions.append(Decision(
                url: url,
                action: classifyAction(url: url, mtime: mtime, byteSize: size)
            ))
        }
    }

    private func classifyAction(url: URL, mtime: Date, byteSize: Int) -> Action {
        // We need to look up the existing document. The cleanest way
        // is `bulkLoad` for the whole index, but that's heavy. For
        // Phase 3.1 MVP we use a lighter approach: track a local
        // snapshot of (url, mtime, size) on the first call and diff
        // against it. That makes the "removed from disk" case
        // detectable without changing the IndexStore API.
        //
        // Implementation deferred to the next refinement pass. For
        // now, we always add/update. Removed-from-disk detection
        // requires either an `allDocuments` API on IndexStore or
        // keeping a snapshot outside it.
        if existingDocumentMtimes[url] == mtime {
            return .skip
        }
        return existingDocumentMtimes[url] == nil ? .add : .update
    }

    /// Local cache of {URL: mtime} for the docs we know about. Populated
    /// on first `index(...)` call by reading the index from disk via
    /// `IndexStore.allDocuments()` (or, if that's not available, via
    /// `bulkLoad` of an empty map and a follow-up read).
    /// **Thread-affinity:** this property is only accessed from within
    /// the actor; we don't need a separate lock.
    private var existingDocumentMtimes: [URL: Date] = [:]
    private var existingDocumentSizes: [URL: Int] = [:]
    /// The path of the index file itself (e.g. `~/.../index.json`). We
    /// skip this during the walk so a re-index doesn't index its own
    /// serialized snapshot — a feedback loop that grows the index
    /// with each rebuild.
    private let ourOwnIndexPath: URL

    /// One-time init hook: read the index from disk and populate the
    /// local caches. Idempotent.
    ///
    /// Currently the `IndexStore` API doesn't expose a fast
    /// `allDocuments()` — we have one of two workarounds:
    /// 1. Read the disk file directly (works because we know the format)
    /// 2. Add an `allDocuments()` method to `IndexStore` and use that
    ///
    /// Option 2 is the right fix. For now we use option 1 to keep
    /// this change small.
    private func ensureLocalCachesLoaded() async {
        guard existingDocumentMtimes.isEmpty else { return }
        // Re-read the on-disk snapshot via IndexStore's persist path
        // and decode it. This is a hack — it uses the public Codable
        // form of IndexSnapshot, which means we have to import it
        // (it's already in the same module).
        do {
            let data = try Data(contentsOf: await store.diskPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(IndexSnapshot.self, from: data)
            for doc in snapshot.documents {
                existingDocumentMtimes[doc.url] = doc.mtime
                existingDocumentSizes[doc.url] = doc.byteSize
            }
        } catch {
            // No file yet, or unreadable — start with empty caches.
        }
    }

    // MARK: - Ingest

    private func ingest(_ url: URL) async throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Quick sanity: must be valid UTF-8 to be indexable. If not,
        // skip (likely a binary file with a text extension).
        guard String(data: data, encoding: .utf8) != nil else { return }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? Int) ?? data.count

        let text = String(data: data, encoding: .utf8) ?? ""
        let tokenSet = Set(TextExtractor.tokenize(text).map(\.term))
        let doc = IndexDocument(url: url, mtime: mtime, byteSize: size)
        await store.upsert(doc, terms: tokenSet)

        // Update our local cache so a subsequent re-index sees this
        // mtime and decides "skip".
        existingDocumentMtimes[url] = mtime
        existingDocumentSizes[url] = size
    }
}
