import Foundation

/// Step-2: persisted set of enrolled root paths for SQLite augmentation.
///
/// The Indexing Boundary is the ONLY filter between the filesystem
/// and our SQLite index (see `docs/SEARCH_BACKEND.md` §4.3).
/// Only files inside an enrolled path are written to the SQLite DB.
///
/// **Design:**
/// - Persisted as a JSON file next to the SQLite database
/// - Thread-safe (actor-isolated)
/// - Default: empty set (user must explicitly add paths)
///
/// **Hard boundary:** this MUST NOT grow into a policy engine,
/// ACL system, or permission model (§4.4).
public actor IndexingBoundary {
    /// Persisted enrolled paths. Empty by default.
    private var enrolled: Set<URL> = []
    private let storageURL: URL

    /// Create or load the boundary from `storageURL`.
    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.enrolled = Self.load(from: storageURL)
    }

    // MARK: - Public API

    /// All currently enrolled paths.
    public func all() -> Set<URL> { enrolled }

    /// Whether a given URL is inside an enrolled path.
    public func contains(_ url: URL) -> Bool {
        enrolled.contains { url.path.hasPrefix($0.path + "/") || url.path == $0.path }
    }

    /// Add a path to the boundary. Persists immediately.
    public func add(_ url: URL) {
        enrolled.insert(url)
        save()
    }

    /// Remove a path from the boundary. Persists immediately.
    public func remove(_ url: URL) {
        enrolled.remove(url)
        save()
    }

    /// Replace all enrolled paths. Persists immediately.
    public func replaceAll(with urls: Set<URL>) {
        enrolled = urls
        save()
    }

    // MARK: - Persistence

    /// Load enrolled paths from a JSON file.
    private static func load(from url: URL) -> Set<URL> {
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Save enrolled paths to a JSON file.
    private func save() {
        let paths = enrolled.map { $0.path }.sorted()
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }
}
