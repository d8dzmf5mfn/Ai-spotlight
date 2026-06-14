import Foundation

public enum Intent: Equatable, Codable, Sendable {
    /// A request to find a file. The optional `name` is for filename
    /// MDQuery (e.g. "report.pdf"); `terms` is the broader bag of
    /// search keywords (file name + content) used by content-aware
    /// search (Phase 3.1+). Either, both, or neither may be present.
    case findFile(name: String?, dateFilter: DateFilter?, kind: FileKind?, terms: [String] = [])
    case openApp(name: String)
    /// A conversational question (Phase 3.4). The user's natural-language
    /// query that the LLM should answer, possibly using indexed file
    /// snippets as context. `contextURLs` may be pre-populated by a
    /// hybrid search (e.g. the panel does a quick file lookup, then
    /// passes the top hits to the LLM).
    case ask(query: String, contextURLs: [URL] = [])
    case unknown(raw: String)

    /// Convenience for "no intent matched" — same as `.unknown(raw: "")`.
    public static let fallback = Intent.unknown(raw: "")
}

public enum DateFilter: String, Codable, Sendable {
    case today, yesterday, lastWeek, lastMonth
}

public enum FileKind: String, Codable, Sendable {
    case pdf, image, document, code, archive, any
}
