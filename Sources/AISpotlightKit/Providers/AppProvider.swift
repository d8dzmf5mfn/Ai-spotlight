import Foundation
import AppKit

public actor AppProvider: SearchProvider {
    public nonisolated let name = "Apps"
    private var cached: [SearchResult] = []

    /// Synchronous initializer that populates the cache up front, so the first
    /// `search()` call after init always sees a populated cache (B5 fix).
    public init() {
        // Note: this runs on the caller's thread, which for AppDelegate is main.
        // NSWorkspace + FileManager calls are safe here.
        let results = Self.scan()
        // We can't assign to actor-isolated state from a non-isolated init.
        // Use a workaround: a Task that waits on nothing but sets the field.
        Task { await self.setCache(results) }
    }

    private func setCache(_ results: [SearchResult]) {
        self.cached = results
    }

    /// Public refresh trigger so callers (e.g. after user installs an app)
    /// can re-scan without restarting the process.
    public func refresh() async {
        self.cached = Self.scan()
    }

    private static func scan() -> [SearchResult] {
        var seen = Set<URL>()
        var out: [SearchResult] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            guard !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(makeResult(from: url))
        }

        for dir in appDirectories() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard !seen.contains(url) else { continue }
                seen.insert(url)
                out.append(makeResult(from: url))
            }
        }

        return out
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        guard case let .openApp(name) = intent else { return [] }
        let q = name.lowercased()
        struct Scored { let result: SearchResult; let isPrefix: Bool; let isSubstring: Bool }
        let scored: [Scored] = cached
            .map {
                let lower = $0.title.lowercased()
                return Scored(result: $0, isPrefix: lower.hasPrefix(q), isSubstring: lower.contains(q))
            }
            .filter { $0.isSubstring }
            .sorted { lhs, rhs in
                if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix && !rhs.isPrefix }
                return lhs.result.title.localizedCaseInsensitiveCompare(rhs.result.title) == .orderedAscending
            }
        return scored.prefix(limit).map { entry in
            SearchResult(
                title: entry.result.title,
                subtitle: entry.result.subtitle,
                iconSystemName: entry.result.iconSystemName,
                url: entry.result.url,
                kind: .app,
                score: entry.result.score + (entry.isPrefix ? 100 : 10)
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
