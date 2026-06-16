import Foundation
import CoreServices

/// A `SearchProvider` that runs against macOS's built-in Spotlight
/// index via the `MDQuery` API. Returns matches by file content
/// (not by file name) — the user types "find notes about polyester"
/// and we return files containing that word.
///
/// **Phase 4.2.10 (deep-research-report.md insight)**: macOS
/// Spotlight is already running `mds` and indexing every file
/// on the disk via FSEvents. We don't need to build our own
/// inverted index (which was 1.13GB RSS for 80k files in the
/// Phase 3.1.5 measurement). We just ask `MDQuery` for
/// `kMDItemTextContent` matches.
///
/// **RSS impact**: < 50MB for the whole AI Spotlight process
/// (no persistent in-memory index, no inverted index, no
/// SQLite database). The OS does the indexing in a separate
/// `mds` daemon we don't pay for.
public final class ContentSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Content"

    public init() {}

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        // We only handle findFile-with-terms. Everything else returns
        // empty — the orchestrator fans out to the right provider
        // (FileSystemProvider for name/date/kind MDQuery, AppProvider
        // for openApp).
        guard case let .findFile(_, _, _, terms) = intent else { return [] }
        guard !terms.isEmpty else { return [] }

        // Spotlight's MDQuery uses a query language that's broadly
        // similar to SQL. We OR the per-term matches so any term
        // hit returns a result. To require ALL terms, we'd need a
        // more complex query; OR is the closest match to the
        // InMemory backend's behavior and is the right default for
        // "find any file containing these words".
        //
        // Each term becomes `kMDItemTextContent == "*term*"`. The
        // asterisks make it a wildcard match. We quote each term
        // with single quotes — Spotlight requires quotes around
        // values that contain spaces or special characters.
        let quotedTerms = terms
            .filter { !$0.isEmpty }
            .map { term in
                let escaped = term.replacingOccurrences(of: "'", with: "\\'")
                return "kMDItemTextContent == '*\(escaped)*'"
            }
        let query = quotedTerms.joined(separator: " || ")

        guard let mdq = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else {
            return []
        }
        defer {
            MDQueryStop(mdq)
        }
        defer {
            // MDQueryCreate returns a CFTypeRef. Balance the retain
            // it does with an explicit release.
            let raw = Unmanaged.passUnretained(mdq).toOpaque()
            Unmanaged<CFTypeRef>.fromOpaque(raw).release()
        }

        // Synchronous execute. MDQuery's API is C-style and
        // synchronous; the async-ness of the SearchProvider
        // protocol is just for cross-actor compatibility.
        MDQueryExecute(mdq, CFOptionFlags(kMDQuerySynchronous.rawValue))
        let total = MDQueryGetResultCount(mdq)
        guard total > 0 else { return [] }

        let count = min(total, limit)
        var results: [SearchResult] = []
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdq, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let pathCF = MDItemCopyAttribute(item, kMDItemPath as CFString) else { continue }
            let path = (pathCF as? String) ?? ""
            let url = URL(fileURLWithPath: path)
            results.append(SearchResult(
                title: url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().path,
                iconSystemName: "doc.text.magnifyingglass",
                url: url,
                kind: .file,
                // Content matches get a high base score so they
                // rank above filename matches — the user asked
                // for content, not for a file with that name.
                score: Double(count - i) + 100,
                contentSnippet: "Content match: \(terms.joined(separator: ", "))"
            ))
        }
        return results
    }
}
