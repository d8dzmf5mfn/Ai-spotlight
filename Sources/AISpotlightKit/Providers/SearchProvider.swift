import Foundation

/// Identifies which `SearchProvider` produced a `SearchResult`. Used by
/// `ResultMerger` to apply per-provider ranking policy without
/// changing the public `SearchResult` shape.
///
/// Phase 6 Step-1.5 (ranking stabilization): added so the merger
/// can apply a weight per source. See TODO-11 in PROJECT_PLAN.md.
///
/// Phase 6 Step-3 (search backend integration): added
/// `.sqliteAugmentation` for the optional SQLite FTS5 backend.
/// See TODO-8 in PROJECT_PLAN.md.
public enum ProviderID: String, Sendable, Equatable {
    case fileSystem
    case contentSearch
    case app
    case sqliteAugmentation
}

public struct SearchResult: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let subtitle: String?
    public let iconSystemName: String
    public let url: URL
    public let kind: Kind
    /// Raw score assigned by the originating `SearchProvider`. Scales
    /// differ per provider (see TODO-11 / `docs/AUDIT_2026-06-17.md`
    /// §11.2). Do not compare across providers without normalization
    /// — use the `weightedScore` written by `ResultMerger` instead.
    public let score: Double
    /// Built-in command this result triggers on activate, if any. Set
    /// for `SearchResult.command(...)` results; nil for file/folder/app
    /// results (which open via `NSWorkspace.shared.open(url)`). Keeping
    /// the command in a dedicated field is cleaner than encoding it into
    /// the URL string and parsing it back.
    public let command: Command?
    /// Optional preview snippet showing why this result matched (e.g. a
    /// 200-char excerpt from the file's contents). Set by
    /// ContentSearchProvider (Phase 3.1). Currently only meaningful for
    /// `kind == .file`; the UI shows it as a second subtitle line.
    public let contentSnippet: String?
    /// Which `SearchProvider` produced this result. `nil` for
    /// `SearchResult.command(...)` pseudo-results that do not come
    /// from a provider. Stamped by `ResultMerger.merge(_:)` during
    /// the bucket-to-list phase.
    public let providerID: ProviderID?
    /// `providerID`'s per-provider weight applied to `score`. Written
    /// by `ResultMerger.merge(_:)`; the UI and ranking consumers
    /// should sort on this, not the raw `score`. `0` for
    /// provider-less pseudo-results.
    public let weightedScore: Double

    public enum Kind: Equatable, Sendable { case file, folder, app, command }

    public init(title: String, subtitle: String?, iconSystemName: String, url: URL, kind: Kind, score: Double, command: Command? = nil, contentSnippet: String? = nil, providerID: ProviderID? = nil, weightedScore: Double = 0) {
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.url = url
        self.kind = kind
        self.score = score
        self.command = command
        self.contentSnippet = contentSnippet
        self.providerID = providerID
        self.weightedScore = weightedScore
    }
}

public protocol SearchProvider: Sendable {
    var name: String { get }
    func search(intent: Intent, limit: Int) async -> [SearchResult]
}

public extension SearchProvider {
    func search(intent: Intent) async -> [SearchResult] {
        await search(intent: intent, limit: 20)
    }
}
