import Foundation
import Combine

// MARK: - IndexSource Protocol

/// A source of indexed files. Each implementation knows how to
/// enumerate its own storage (local FS, cloud, external drives).
public protocol IndexSource: Sendable {
    /// Human-readable name (e.g. "Local FS", "OneDrive").
    var name: String { get }
    /// The provider type this source handles.
    var providerType: FileIndexItem.ProviderType { get }
    /// Perform a full re-scan and return all items.
    func scan() async throws -> [FileIndexItem]
    /// Watch for changes and return events via an async stream.
    func watch() -> AsyncStream<IndexEvent>
}

// MARK: - IndexEngine

/// The central index engine that manages all `IndexSource`
/// implementations and provides a unified search interface.
///
/// **Architecture:**
/// ```
/// IndexEngine
///   ├── LocalIndexSource   (Documents, Downloads, Desktop …)
///   ├── CloudIndexSource   (OneDrive, iCloud, Dropbox, Google Drive …)
///   ├── ExternalIndexSource  (/Volumes/*)
///   └── MDQueryBridge      (Spotlight fallback)
/// ```
///
/// **Lifecycle:**
/// 1. `register(_:)` — add a source
/// 2. `start()` — launch all sources (scan + watch)
/// 3. `search(_:)` — query across all indexed items
/// 4. `stop()` — tear down watchers
public final class IndexEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    /// All currently indexed items (in-memory cache).
    @Published public private(set) var items: [FileIndexItem] = []

    /// Indexing progress (0…1 or nil when idle).
    @Published public private(set) var progress: Double?

    /// Latest event for UI feedback.
    @Published public private(set) var lastEvent: IndexEvent?

    // MARK: - Internal

    private let lock = NSLock()
    private var sources: [IndexSource] = []
    private var watchContinuations: [AsyncStream<IndexEvent>.Continuation] = []
    private var tasks: [Task<Void, Never>] = []

    public init() {}

    // MARK: - Registration

    /// Register an index source. Must be called before `start()`.
    public func register(_ source: IndexSource) {
        lock.lock(); defer { lock.unlock() }
        sources.append(source)
    }

    // MARK: - Lifecycle

    /// Start all registered sources (initial scan + watching).
    public func start() {
        lock.lock()
        let sourcesCopy = sources
        lock.unlock()

        for source in sourcesCopy {
            let task: Task<Void, Never> = Task(priority: .background) { [weak self] in
                _ = await self?.runSource(source)
            }
            tasks.append(task)
        }
    }

    /// Stop all sources and clean up.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        watchContinuations.forEach { $0.finish() }
        watchContinuations.removeAll()
    }

    // MARK: - Search

    /// Search across all indexed items. Returns items whose
    /// filename or path contains `query` (case-insensitive).
    public func search(query: String, limit: Int = 30) -> [FileIndexItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        return items
            .filter { item in
                item.filename.lowercased().contains(trimmed)
                    || item.path.lowercased().contains(trimmed)
            }
            .sorted { $0.lastIndexed > $1.lastIndexed }
            .prefix(limit)
            .map { $0 }
    }

    /// Search by provider type (e.g. only cloud).
    public func search(query: String, in providerType: FileIndexItem.ProviderType, limit: Int = 30) -> [FileIndexItem] {
        return search(query: query, limit: limit)
            .filter { $0.providerType == providerType }
    }

    // MARK: - Internal

    private func runSource(_ source: IndexSource) async {
        // Initial scan
        do {
            let scanned = try await source.scan()
            await MainActor.run {
                self.lock.lock(); defer { self.lock.unlock() }
                // Remove old items from this source, add new ones
                self.items.removeAll { $0.providerType == source.providerType }
                self.items.append(contentsOf: scanned)
                self.lastEvent = .scanComplete(providerType: source.providerType, itemCount: scanned.count)
                Log.write("[IndexEngine] \(source.name): scanned \(scanned.count) items")
            }
        } catch {
            Log.write("[IndexEngine] \(source.name): scan failed: \(error.localizedDescription)")
            await MainActor.run {
                self.lastEvent = .error(providerType: source.providerType, message: error.localizedDescription)
            }
        }

        // Watch for changes
        for await event in source.watch() {
            await handleEvent(event, for: source)
        }
    }

    @MainActor
    private func handleEvent(_ event: IndexEvent, for source: IndexSource) {
        self.lastEvent = event
        lock.lock(); defer { self.lock.unlock() }

        switch event {
        case .upserted(let item):
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx] = item
            } else {
                self.items.append(item)
            }

        case .deleted(let url):
            self.items.removeAll { $0.url == url }

        case .batch(let upserts, let deletes):
            let deleteSet = Set(deletes.map { $0.path })
            self.items.removeAll { deleteSet.contains($0.path) }
            for item in upserts {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx] = item
                } else {
                    self.items.append(item)
                }
            }

        case .scanComplete(let providerType, let itemCount):
            Log.write("[IndexEngine] \(source.name) scan complete: \(itemCount) items")

        case .error(let providerType, let message):
            Log.write("[IndexEngine] \(source.name) error: \(message)")
        }
    }
}

// MARK: - Built-in Index Sources

/// Indexes standard local folders (Documents, Downloads, Desktop).
public final class LocalIndexSource: IndexSource, @unchecked Sendable {
    public let name = "Local FS"
    public let providerType: FileIndexItem.ProviderType = .local

    private let roots: [URL]

    public convenience init() {
        self.init(roots: LocalIndexSource.defaultRoots())
    }

    public init(roots: [URL]) {
        self.roots = roots
    }

    public func scan() async throws -> [FileIndexItem] {
        var items: [FileIndexItem] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = resourceValues?.isDirectory ?? false
                if isDir { continue }

                items.append(FileIndexItem(
                    url: fileURL,
                    providerType: .local,
                    isDirectory: false,
                    fileSize: resourceValues?.fileSize.map(UInt64.init),
                    lastModified: resourceValues?.contentModificationDate,
                    contentType: fileURL.pathExtension
                ))

                if items.count >= 50_000 { break }  // Safety limit
            }
        }
        return items
    }

    public func watch() -> AsyncStream<IndexEvent> {
        AsyncStream { continuation in
            // Periodic re-scan every 60s as a simple watch strategy
            Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard let items = try? await self?.scan() else { continue }
                    continuation.yield(.scanComplete(providerType: .local, itemCount: items.count))
                }
            }
        }
    }

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
        ]
    }
}

/// Indexes cloud-storage paths (OneDrive, iCloud, Dropbox, etc.)
/// using `FileSystemAdapter` for root discovery.
public final class CloudIndexSource: IndexSource, @unchecked Sendable {
    public let name = "Cloud Storage"
    public let providerType: FileIndexItem.ProviderType = .cloud

    public init() {}

    public func scan() async throws -> [FileIndexItem] {
        let roots = FileSystemAdapter.detectCloudStorageRoots()
        var items: [FileIndexItem] = []

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { continue }

                items.append(FileIndexItem(
                    url: fileURL,
                    providerType: .cloud,
                    isDirectory: false,
                    contentType: fileURL.pathExtension
                ))

                if items.count >= 50_000 { break }
            }
        }
        return items
    }

    public func watch() -> AsyncStream<IndexEvent> {
        AsyncStream { continuation in
            Task.detached(priority: .background) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)  // 2 min
                    continuation.yield(.scanComplete(providerType: .cloud, itemCount: 0))
                }
            }
        }
    }
}
