import Foundation
import AppKit

/// Scans `/Applications` + running apps. Uses a serial dispatch queue instead
/// of an actor so the cache is populated synchronously in init (B5 fix: the
/// first `search()` call always sees a populated cache).
public final class AppProvider: SearchProvider, @unchecked Sendable {
    public let name = "Apps"
    private var cached: [SearchResult] = []
    private let lock = NSLock()

    public init() {
        // sync scan on the caller's thread (always main, from AppDelegate)
        let results = Self.scan()
        lock.lock()
        cached = results
        lock.unlock()
    }

    public func refresh() async {
        let results = Self.scan()
        lock.lock()
        cached = results
        lock.unlock()
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
        lock.lock()
        let snapshot = cached
        lock.unlock()

        let scored: [Scored] = snapshot
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
