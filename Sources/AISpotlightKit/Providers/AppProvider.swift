import Foundation
import AppKit

public actor AppProvider: SearchProvider {
    public nonisolated let name = "Apps"
    private var cached: [SearchResult] = []

    public init() { Task { await self.refresh() } }

    public func refresh() async {
        var seen = Set<URL>()
        var out: [SearchResult] = []

        // 1) Running applications
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            guard !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(makeResult(from: url, score: 0))
        }

        // 2) /Applications + /System/Applications + ~/Applications
        for dir in appDirectories() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard !seen.contains(url) else { continue }
                seen.insert(url)
                out.append(makeResult(from: url, score: 0))
            }
        }

        self.cached = out
    }

    public func search(intent: Intent, limit: Int = 10) async -> [SearchResult] {
        guard case let .openApp(name) = intent else { return [] }
        let q = name.lowercased()
        // Rank: exact-prefix match > substring match
        struct Scored { let result: SearchResult; let isPrefix: Bool; let isSubstring: Bool }
        let scored: [Scored] = cached
            .map { Scored(result: $0, isPrefix: $0.title.lowercased().hasPrefix(q), isSubstring: $0.title.lowercased().contains(q)) }
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

    private func makeResult(from url: URL, score: Double) -> SearchResult {
        SearchResult(
            title: url.deletingPathExtension().lastPathComponent,
            subtitle: url.deletingLastPathComponent().path,
            iconSystemName: "app",
            url: url,
            kind: .app,
            score: score
        )
    }

    private func appDirectories() -> [URL] {
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
