import Foundation
import AppKit

/// Scans `/Applications` + running apps. Returns an empty result list
/// immediately on the first `search()` call and populates the cache
/// asynchronously — the goal is to never block the first ⌘+Space
/// keystroke on a directory scan that can take 100-300ms on a
/// Mac with a large `/Applications`.
///
/// Sendability: `cached` is mutated only while holding `lock`, so we
/// mark the class `@unchecked Sendable` rather than make it an actor
/// (actors add an extra hop on every `search` call).
public final class AppProvider: SearchProvider, @unchecked Sendable {
    public let name = "Apps"
    private var cached: [SearchResult] = []
    private let lock = NSLock()

    public init() {
        // Kick off the first scan in the background so the first
        // search() call after launch finds data within ~50-300ms.
        // (If you call search() before the scan finishes, you simply
        // get an empty list — which is the right UX for a Spotlight clone.)
        Task.detached(priority: .userInitiated) { await self.refresh() }
    }

    public func refresh() async {
        let results = await Task.detached(priority: .userInitiated) {
            Self.scan()
        }.value
        lock.lock()
        cached = results
        lock.unlock()
    }

    private static func scan() -> [SearchResult] {
        var seen = Set<URL>()
        var out: [SearchResult] = []
        out.reserveCapacity(64)  // typical Mac has 30-80 user apps

        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL, seen.insert(url).inserted else { continue }
            out.append(Self.makeResult(from: url))
        }

        for dir in Self.appDirectories() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard seen.insert(url).inserted else { continue }
                out.append(Self.makeResult(from: url))
            }
        }

        return out
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        guard case let .openApp(name) = intent else { return [] }
        let q = name.lowercased()

        lock.lock()
        let snapshot = cached
        lock.unlock()

        // Single pass: filter by substring, compute prefix hit for
        // ranking, collect into a tiny array. Avoids the earlier
        // 3-pass (map → filter → sorted) flow.
        var matched: [(r: SearchResult, isPrefix: Bool)] = []
        matched.reserveCapacity(20)
        for result in snapshot {
            let title = result.title
            let lower = title.lowercased()
            guard lower.contains(q) else { continue }
            matched.append((result, lower.hasPrefix(q)))
        }
        matched.sort { lhs, rhs in
            if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix }
            return lhs.r.title.localizedCaseInsensitiveCompare(rhs.r.title) == .orderedAscending
        }
        if matched.count > limit { matched.removeLast(matched.count - limit) }

        return matched.map { entry in
            SearchResult(
                title: entry.r.title,
                subtitle: entry.r.subtitle,
                iconSystemName: entry.r.iconSystemName,
                url: entry.r.url,
                kind: .app,
                score: entry.r.score + (entry.isPrefix ? 100 : 10)
            )
        }
    }

    // MARK: - Helpers

    private static func makeResult(from url: URL) -> SearchResult {
        SearchResult(
            title: url.deletingPathExtension().lastPathComponent,
            subtitle: url.deletingLastPathComponent().path,
            iconSystemName: "app",
            url: url,
            kind: .app,
            score: 0
        )
    }

    private static func appDirectories() -> [URL] {
        var dirs: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        if let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            dirs.append(userApps)
        }
        return dirs
    }
}
