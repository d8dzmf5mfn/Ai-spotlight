import Foundation

/// A `SearchProvider` that uses the `FileSystemAdapter` to search
/// across all storage roots (including OneDrive, iCloud, etc.).
///
/// **Why this exists separately from `FileSystemProvider`:**
/// The existing `FileSystemProvider` relies solely on Spotlight's
/// `MDQuery`, which does not reliably index cloud-storage files
/// (especially placeholder-only files on OneDrive/iCloud).
/// This provider adds a FileManager-based fallback enumeration
/// specifically for cloud-storage paths, so users can find files
/// even when Spotlight hasn't indexed them.
public final class FileSystemAdapterProvider: SearchProvider, @unchecked Sendable {
    public let name = "FileSystemAdapter"

    public init() {}

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        // Extract search terms from the intent
        let terms: [String]
        let rawQuery: String

        switch intent {
        case .findFile(_, _, _, let t):
            terms = t
            rawQuery = t.joined(separator: " ")
        case .unknown(let raw):
            terms = raw.isEmpty ? [] : [raw]
            rawQuery = raw
        case .ask(let query, _):
            // For ask intents, don't search files — the LLM handles it
            return []
        case .openApp:
            return []
        }

        guard !rawQuery.isEmpty else { return [] }

        // Search via the adapter
        let results = FileSystemAdapter.search(query: rawQuery, limit: limit)

        // Stamp with provider ID
        return results.map { result in
            SearchResult(
                title: result.title,
                subtitle: result.subtitle,
                iconSystemName: result.iconSystemName,
                url: result.url,
                kind: result.kind,
                score: result.score,
                contentSnippet: result.contentSnippet,
                providerID: .fileSystem,
                weightedScore: result.weightedScore
            )
        }
    }
}
