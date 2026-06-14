import Foundation

/// A `SearchProvider` that runs against the in-memory inverted index
/// populated by `ContentIndexer`. Returns matches by file content
/// (not by file name) — the user types "find notes about polyester"
/// and we return files containing that word.
///
/// **Phase 3.1.4** baseline: BM25-style scoring (count of matched
/// terms) + a short content snippet. LLM re-ranking is added in 3.3.
public final class ContentSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Content"

    private let indexStore: IndexStore

    public init(indexStore: IndexStore) {
        self.indexStore = indexStore
    }

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        // We only handle findFile-with-terms. Everything else returns
        // empty — the orchestrator fans out to the right provider
        // (FileSystemProvider for name/date/kind MDQuery, AppProvider
        // for openApp).
        guard case let .findFile(_, _, _, terms) = intent else { return [] }
        guard !terms.isEmpty else { return [] }

        let hits = await indexStore.query(terms, limit: limit)
        // Phase 3.1 MVP: snippet is a placeholder showing which terms
        // matched. A future task (3.1.4 follow-up or 3.3) will read
        // the file contents to produce a real excerpt around the
        // first hit.
        let termSummary = terms.joined(separator: ", ")
        return hits.map { hit in
            SearchResult(
                title: hit.url.lastPathComponent,
                subtitle: hit.url.deletingLastPathComponent().path,
                iconSystemName: "doc.text.magnifyingglass",
                url: hit.url,
                kind: .file,
                // IndexHit.score is the number of distinct query terms
                // that matched. Boost it so content hits rank above
                // other providers' low-scored items.
                score: Double(hit.score) + 100,
                contentSnippet: "Content match: \(termSummary)"
            )
        }
    }
}
