import Foundation

/// Determines which `SearchProvider` should be the *primary*
/// (and only) provider for a given query intent.
///
/// **Design principle:** exactly one "primary" provider runs per
/// search. No more fanning out to all providers and hoping for
/// the best. Fallback happens only when the primary returns
/// empty results.
///
/// **Rules:**
/// - CJK queries → SQLiteBackend (LIKE-based, no MDQuery)
/// - App queries → AppProvider
/// - File queries (ASCII) → FileSystemProvider (MDQuery preferred)
/// - Unknown / Ask → hybrid: FileSystemProvider + SQLiteBackend
public enum SearchMode: Sendable, Equatable {
    /// Only the SQLite backend (for CJK text search).
    case sqliteOnly
    /// Only the app provider.
    case appOnly
    /// Only the file system provider (MDQuery).
    case mdQueryOnly
    /// Primary + fallback (file system first, then SQLite).
    case hybrid
    /// No search needed (pure LLM ask).
    case none
}

public enum SearchRouter {

    /// Determine the search mode for a given intent.
    public static func route(for intent: Intent) -> SearchMode {
        switch intent {
        case .openApp:
            return .appOnly

        case .findFile(let name, _, _, let terms):
            // Check if any term contains CJK characters
            let allTerms = ([name].compactMap { $0 } + terms)
            let hasCJK = allTerms.contains { CJKUtils.containsCJK($0) }
            if hasCJK {
                return .sqliteOnly
            }
            // Single filename match → MDQuery
            if let n = name, !n.isEmpty {
                return .mdQueryOnly
            }
            return .mdQueryOnly

        case .ask:
            return .hybrid

        case .unknown(let raw):
            if raw.isEmpty { return .none }
            // CJK unknown queries → SQLite
            if CJKUtils.containsCJK(raw) {
                return .sqliteOnly
            }
            return .mdQueryOnly
        }
    }
}
