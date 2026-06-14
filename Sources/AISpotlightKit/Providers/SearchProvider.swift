import Foundation

public struct SearchResult: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let subtitle: String?
    public let iconSystemName: String
    public let url: URL
    public let kind: Kind
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

    public enum Kind: Equatable, Sendable { case file, folder, app, command }

    public init(title: String, subtitle: String?, iconSystemName: String, url: URL, kind: Kind, score: Double, command: Command? = nil, contentSnippet: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.url = url
        self.kind = kind
        self.score = score
        self.command = command
        self.contentSnippet = contentSnippet
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
