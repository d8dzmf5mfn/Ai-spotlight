public enum Intent: Equatable, Sendable {
    case findFile(name: String?, dateFilter: DateFilter?, kind: FileKind?)
    case openApp(name: String)
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
