import Foundation

/// Step-2: file system sync service for SQLite augmentation.
///
/// Listens to enrolled paths, scans files, and batch-writes
/// metadata to the SQLite FTS5 backend.
///
/// **Architecture (per `docs/SEARCH_BACKEND.md` §5.2):**
/// ```
/// PeriodicScan (or DirectoryWatcher)
///   ↓
/// Debounce Queue (1–5s batch)
///   ↓
/// Filter (enrolled paths only via IndexingBoundary)
///   ↓
/// SQLite Upsert (batch write, single transaction)
///   ↓
/// FTS5 Update (same transaction)
/// ```
///
/// **Hard limits (§4.2):**
/// - No full file content indexing
/// - `content_preview` is empty until user explicitly opens/pins
/// - No recursive crawl of the entire disk
///
/// **Consistency model:** eventual consistency. No locking with
/// MDQuery (different stores, different writers).
public actor SyncService {
    private let boundary: IndexingBoundary
    private let dbURL: URL
    private var scanTimer: Task<Void, Never>?
    /// Seconds between periodic re-scans. 60s by default.
    private let scanInterval: TimeInterval
    /// FSEvents-based watcher for real-time file change detection.
    private var fsEventsWatcher: FSEventsWatcher?
    /// Max bytes to read from each file for content_preview.
    /// Set to 0 because we do NOT index file contents in Step-2
    /// (per §4.2 hard limits). Content preview is populated only
    /// when the user explicitly opens or pins the file.
    private let maxPreviewBytes: Int = 0

    public init(
        boundary: IndexingBoundary,
        dbURL: URL = SQLiteBackend.databaseURL,
        scanInterval: TimeInterval = 60.0
    ) {
        self.boundary = boundary
        self.dbURL = dbURL
        self.scanInterval = scanInterval
    }

    // MARK: - Lifecycle

    /// Start the sync service: immediately scan enrolled paths,
    /// then schedule periodic re-scans.
    public func start() async {
        Log.write("[SyncService] start: beginning initial scan")
        await scanAllEnrolledPaths()
        startPeriodicScan()
        // Start FSEvents watcher for real-time file change detection.
        // Falls back to periodic polling if FSEvents is unavailable.
        let paths = await boundary.all()
        if !paths.isEmpty {
            startFSEventsWatcher(paths: paths.map { $0.path })
        }
        Log.write("[SyncService] start: periodic scan scheduled every \(Int(scanInterval))s")
    }

    /// Stop the sync service and cancel any pending scans.
    public func stop() {
        scanTimer?.cancel()
        scanTimer = nil
        fsEventsWatcher?.stop()
        fsEventsWatcher = nil
        Log.write("[SyncService] stop: periodic scan cancelled, FSEvents watcher stopped")
    }

    /// Trigger an immediate scan of all currently enrolled paths.
    /// Idempotent — calling this mid-scan is safe (the ongoing
    /// scan finishes first).
    public func scanNow() async {
        Log.write("[SyncService] scanNow: manual scan triggered")
        await scanAllEnrolledPaths()
    }

    /// Call when the set of enrolled paths changes. Stops the old
    /// FSEvents watcher and starts a new one for the updated paths.
    public func updateWatchedPaths(_ paths: [String]) async {
        fsEventsWatcher?.stop()
        fsEventsWatcher = nil
        guard !paths.isEmpty else { return }
        startFSEventsWatcher(paths: paths)
    }

    // MARK: - FSEvents Watcher

    /// Start the FSEvents-based watcher for real-time notifications.
    private func startFSEventsWatcher(paths: [String]) {
        guard !paths.isEmpty else { return }
        fsEventsWatcher?.stop()
        let watcher = FSEventsWatcher(paths: paths, latency: 1.0, queue: .main) { [weak self] in
            guard let self else { return }
            // FSEvents fired on the main queue. Trigger a re-scan
            // via a detached Task so we don't block the UI.
            Task { await self.scanNow() }
        }
        watcher.start()
        fsEventsWatcher = watcher
        Log.write("[SyncService] FSEvents watcher started for \(paths.count) path(s)")
    }

    // MARK: - Periodic Scan

    private func startPeriodicScan() {
        scanTimer?.cancel()
        scanTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.scanInterval * 1_000_000_000))
                } catch {
                    // Task cancelled — exit cleanly
                    return
                }
                guard !Task.isCancelled else { return }
                await self.scanAllEnrolledPaths()
            }
        }
    }

    // MARK: - Scanning

    /// Scan all enrolled paths, collecting file metadata and
    /// batch-upserting to SQLite. Only processes files inside
    /// enrolled root paths (filtered by `IndexingBoundary`).
    private func scanAllEnrolledPaths() async {
        let paths = await boundary.all()
        guard !paths.isEmpty else {
            Log.write("[SyncService] scanAllEnrolledPaths: no enrolled paths, skipping")
            return
        }

        var files: [(path: String, filename: String, lastModified: Int, fileType: String?)] = []
        let isDirectory = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        defer { isDirectory.deallocate() }

        for root in paths {
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: isDirectory),
                  isDirectory.pointee.boolValue else {
                Log.write("[SyncService] scanAllEnrolledPaths: enrolled path does not exist or is not a directory: \(root.path)")
                continue
            }

            // Use FileManager's enumerator for recursive directory walk.
            // We limit to regular files only (no symlinks, no packages).
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // Use synchronous iteration to avoid 'makeIterator' unavailable
            // from async contexts (Swift 6). FileManager's enumerator is not
            // Sendable-safe, so we collect results eagerly in a local array.
            while let fileURL = enumerator.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                      resourceValues.isRegularFile == true || resourceValues.isDirectory == true else { continue }

                // Skip files larger than 5 MB (matching TextExtractor.maxFileSize)
                // Directories are always indexed regardless of size.
                let isDir = resourceValues.isDirectory ?? false
                if !isDir {
                    let fileSize = resourceValues.fileSize ?? 0
                    guard fileSize < 5 * 1024 * 1024 else { continue }
                }

                let lastModified = Int(resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0)
                let ext = fileURL.pathExtension.lowercased()
                let fileType = categorizeExtension(ext, isDirectory: isDir)

                files.append((
                    path: fileURL.path,
                    filename: fileURL.lastPathComponent,
                    lastModified: max(lastModified, 1),
                    fileType: fileType
                ))

                // Write in batches of 500 to avoid unbounded memory use
                if files.count >= 500 {
                    SQLiteBackend.upsertFiles(files, at: dbURL)
                    files.removeAll(keepingCapacity: true)
                }
            }
        }

        // Flush remaining files
        if !files.isEmpty {
            SQLiteBackend.upsertFiles(files, at: dbURL)
        }

        Log.write("[SyncService] scanAllEnrolledPaths: completed, \(files.count) files processed in this batch")
    }

    /// Categorize a file extension into a high-level type.
    /// Mirrors `FileKind` from `Intent.swift` without the dependency.
    private func categorizeExtension(_ ext: String, isDirectory: Bool = false) -> String? {
        if isDirectory { return "folder" }
        switch ext {
        case "pdf": return "pdf"
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp": return "image"
        case "txt", "rtf", "md", "markdown", "doc", "docx", "pages", "key", "numbers": return "document"
        case "swift", "py", "js", "ts", "go", "rs", "rb", "c", "cpp", "h", "m", "mm",
             "java", "kt", "scala", "sh", "bash", "zsh", "css", "html", "sql", "yaml",
             "yml", "json", "xml", "toml", "gradle", "proto": return "code"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "archive"
        default: return nil
        }
    }
}
