import Foundation

public enum QueryParser {
    /// Parse a free-form query into an Intent. Trims whitespace first.
    public static func parse(_ raw: String) -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // App open
        if let m = matchApp(lower, raw: trimmed) { return m }
        // File find
        return matchFile(lower, raw: trimmed)
    }

    private static let openVerbsEN = ["open", "launch", "start", "run"]
    private static let findVerbsEN = ["find", "show", "search", "get", "locate"]
    private static let findVerbsCN = ["找", "打开", "搜索", "查找"]

    private static func matchApp(_ lower: String, raw: String) -> Intent? {
        for v in openVerbsEN {
            if lower.hasPrefix(v + " "), lower.count > v.count + 1 {
                let name = String(raw.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
                return .openApp(name: name)
            }
        }
        if lower.hasPrefix("打开") && raw.count > 2 {
            let name = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !name.contains("找") { return .openApp(name: name) }
        }
        return nil
    }

    private static func matchFile(_ lower: String, raw: String) -> Intent {
        let tokens = lower.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let tokenSet = Set(tokens)  // for exact-word verb matching (fixes substring bugs)

        var dateFilter: DateFilter?
        if tokenSet.contains("yesterday") || raw.contains("昨天") { dateFilter = .yesterday }
        else if tokenSet.contains("today") || raw.contains("今天") { dateFilter = .today }
        else if lower.contains("last week") || raw.contains("上周") { dateFilter = .lastWeek }
        else if lower.contains("last month") || raw.contains("上个月") { dateFilter = .lastMonth }

        var kind: FileKind?
        // Match "pdf" as a standalone token, OR as the extension of any token (e.g. "report.pdf").
        // The extension check restores the old behavior for the "find report.pdf" case.
        let hasPdfToken = tokenSet.contains("pdf") || tokens.contains(where: { $0.hasSuffix(".pdf") })
        let hasImageToken = tokenSet.contains("image") || tokenSet.contains("photo") || raw.contains("图片")
        if hasPdfToken { kind = .pdf }
        else if hasImageToken { kind = .image }

        // Verb detection: exact word match in tokens (not substring) — fixes
        // "shower" matching "show" and "opening" matching "open".
        let hasFindVerb = !Set(findVerbsEN).isDisjoint(with: tokenSet)
            || findVerbsCN.contains(where: raw.contains)

        if dateFilter != nil || kind != nil || hasFindVerb {
            return .findFile(name: extractName(raw), dateFilter: dateFilter, kind: kind)
        }
        return .unknown(raw: raw)
    }

    /// Find a filename token: a word containing a dot, with trailing punctuation stripped.
    /// "Find notes." → nil (trailing period stripped, then "notes" has no dot)
    /// "find report.pdf" → "report.pdf"
    private static func extractName(_ raw: String) -> String? {
        let tokens = raw.split(separator: " ")
        for token in tokens {
            // Strip common trailing punctuation
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if cleaned.contains(".") && cleaned.count > 2 {
                return String(cleaned)
            }
        }
        return nil
    }
}
