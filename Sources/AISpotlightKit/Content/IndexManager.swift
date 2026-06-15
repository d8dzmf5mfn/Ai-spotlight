import Foundation
import Combine

/// MainActor-isolated coordinator for the content index. Wraps an
/// `IndexStore` and a `ContentIndexer`, exposes published progress
/// for the Settings UI.
///
/// **Design choice (Phase 3.1.5 retry):** this is a plain
/// `@MainActor` class with NO `nonisolated` async methods. The
/// previous attempt used `nonisolated public func startInitialIndex`
/// with `await setIsRunning(true)` hops, which the previous
/// SwiftPM test target couldn't handle on macOS 27 beta (XCTest
/// launcher deadlock — see `~/.hermes/skills/macos-swiftpm-bug-hang`).
/// The Core test target doesn't even include this file; the
/// IndexManager is app-level glue and is not unit-tested.
@MainActor
public final class IndexManager: ObservableObject {
    /// Default directories the indexer walks if the user hasn't
    /// The user's default index roots. Just `~/Documents` for
    /// the zero-friction default — `~/Downloads` is full of
    /// `.zip` / `.dmg` / `.iso` / `.pkg` files that inflate the
    /// inverted index (Phase 3.1.5 measured 4-5 GB RSS for
    /// 80k files across both directories). Users who want
    /// Downloads indexed can add it via the IndexManager
    /// init's `customRoots` parameter, or in Settings
    /// (Phase 4.2.1).
    public static let defaultRoots: [URL] = {
        let fm = FileManager.default
        var dirs: [URL] = []
        for type: FileManager.SearchPathDirectory in [.documentDirectory] {
            if let url = fm.urls(for: type, in: .userDomainMask).first {
                dirs.append(url)
            }
        }
        return dirs
    }()

    /// The full list of roots we'll index. Defaults + user-added.
    public let rootsToIndex: [URL]

    /// The store the indexer writes into.
    private let store: IndexStore

    /// Re-entrancy guard. Set to true while a walk is in progress;
    /// concurrent `startInitialIndex` calls become no-ops.
    private var isRunning = false

    /// The most recent progress. Updated when a walk completes; read
    /// by the Settings UI to show "Last built: …".
    @Published public private(set) var lastProgress: IndexProgress = .empty

    /// True while a walk is in progress.
    @Published public private(set) var isIndexing: Bool = false

    /// The most recent stats snapshot (document count, term count,
    /// last built date). Read by the Settings dashboard.
    @Published public private(set) var stats: IndexStats = .empty

    public init(store: IndexStore, customRoots: [URL] = []) {
        self.store = store
        self.rootsToIndex = Self.defaultRoots + customRoots
    }

    /// Walk all `rootsToIndex` and update the store. Returns the
    /// progress for the UI. If a walk is already running, returns
    /// `IndexProgress.empty` immediately (no-op).
    @discardableResult
    public func startInitialIndex() async -> IndexProgress {
        if isRunning { return .empty }
        isRunning = true
        isIndexing = true
        defer {
            isRunning = false
            isIndexing = false
        }
        let indexer = ContentIndexer(store: store)
        let progress = await indexer.index(roots: rootsToIndex)
        lastProgress = progress
        // Refresh stats snapshot for the UI.
        stats = await store.stats()
        return progress
    }
}
