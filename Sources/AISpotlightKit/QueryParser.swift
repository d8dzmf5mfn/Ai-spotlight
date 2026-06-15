import Foundation

public enum QueryParser {
    /// Parse a free-form query into an Intent. Trims whitespace first.
    public static func parse(_ raw: String) -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown(raw: trimmed) }
        let lower = trimmed.lowercased()
        // Phase 4.2: prefer find verbs (find/show/search/...) when
        // they're present, because that disambiguates "find Safari"
        // (a file) from "Safari" (an app). The find verb check used
        // to come after the app check, but that meant "find Safari"
        // tried to open the app, which is wrong.
        if let m = matchFindVerb(raw: raw) { return m }
        // App open: tries both "open Safari" (with prefix) and
        // "Safari" (no prefix, single token).
        if let m = matchApp(lower: lower, raw: trimmed) { return m }
        // File find
        let fileIntent = matchFile(raw)
        // Phase 4.2: only convert a multi-token .unknown into
        // .openApp if it looks like an app name (no question
        // mark, no "I" / "what" / "how" / "tell me" / "explain"
        // starters that suggest a free-form question for the
        // LLM). "Visual Studio Code" → openApp; "hello world" /
        // "I had a shower" / "tell me about polyester" → stay
        // .unknown (LLM will be asked).
        if case .unknown = fileIntent, looksLikeAppName(trimmed) {
            return .openApp(name: trimmed)
        }
        return fileIntent
    }

    /// Heuristic: does this trimmed query look like an app name
    /// (a title-cased multi-word phrase) rather than a free-form
    /// sentence for the LLM?
    ///
    /// True for: "Visual Studio Code", "Sublime Text", "GitHub
    /// Desktop", "1Password 7"
    ///
    /// False for: "hello world", "I had a shower", "tell me
    /// about polyester", "what is the meaning of life"
    ///
    /// The rule of thumb: free-form sentences for the LLM almost
    /// always contain a lowercase verb or a question word, or
    /// start with a pronoun. App names almost never do — they're
    /// title-cased proper nouns.
    private static func looksLikeAppName(_ raw: String) -> Bool {
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count < 2 { return false }
        // Question words and pronouns at the start strongly suggest
        // free-form text, not an app name.
        let startsWithFreeForm: Set<String> = [
            "i", "you", "he", "she", "we", "they", "what", "how",
            "why", "when", "where", "who", "tell", "explain", "show",
            "give", "make", "do", "can", "could", "would", "should",
            "is", "are", "was", "were", "will", "did", "does",
        ]
        if let first = tokens.first?.lowercased(), startsWithFreeForm.contains(first) {
            return false
        }
        // Question marks in the body also strongly suggest free-form.
        if raw.contains("?") { return false }
        // If EVERY token is lowercase, it's probably not an app name
        // (most apps are at least partly title-cased). This catches
        // "i had a shower" / "hello world" / "tell me about
        // polyester" while still allowing "iA Writer" (proper
        // mixed case) and "1Password" (starts with a digit).
        let allLower = tokens.allSatisfy { $0 == $0.lowercased() }
        if allLower { return false }
        return true
    }

    private static let openVerbsEN = ["open", "launch", "start", "run"]
    private static let findVerbsEN = ["find", "show", "search", "get", "locate"]
    private static let findVerbsCN = ["找", "打开", "搜索", "查找"]

    /// Returns a .findFile intent if the query contains a find
    /// verb. Returns nil otherwise (caller falls through to app
    /// matching or generic file find).
    private static func matchFindVerb(raw: String) -> Intent? {
        let rawStripped = raw
            .replacingOccurrences(of: "'s",  with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "’s",  with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "的", with: "")
        let lowerStripped = rawStripped.lowercased()
        let tokens = lowerStripped.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let tokenSet = Set(tokens)
        let hasFindVerb = !Set(findVerbsEN).isDisjoint(with: tokenSet)
            || findVerbsCN.contains(where: raw.contains)
        if hasFindVerb {
            return matchFile(raw)
        }
        return nil
    }

    private static func matchApp(lower: String, raw: String) -> Intent? {
        // Phase 4.2: prefix-free app lookup. The earlier code
        // required "open Safari" / "launch Safari" / etc. as a
        // prefix, which is friction compared to Spotlight/Raycast.
        // New behavior: a single token (e.g. "Safari") is treated
        // as an app name — the file system is unlikely to have a
        // file with the same name, and the user almost certainly
        // means the app. Multi-token queries fall through to
        // matchFile (which already handles "find X" / "show me X
        // yesterday" / etc).
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
        // Prefix-free: only for SINGLE-token queries. "Safari" → app.
        // "hello world" / "Visual Studio Code" / "I had a shower"
        // stay in the multi-token land and go to matchFile
        // (which may return .findFile or .unknown).
        let tokenCount = raw.split(separator: " ", omittingEmptySubsequences: true).count
        if tokenCount == 1 && !raw.isEmpty {
            return .openApp(name: raw)
        }
        return nil
    }

    private static func matchFile(_ raw: String) -> Intent {
        // Strip possessive forms ("yesterday's", "上周的") so the date
        // check matches the bare token. We lowercase once and reuse —
        // earlier version called `.lowercased()` three separate times.
        let rawStripped = raw
            .replacingOccurrences(of: "'s",  with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "’s",  with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "的", with: "")
        let lowerStripped = rawStripped.lowercased()
        let tokens = lowerStripped.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let tokenSet = Set(tokens)

        // Date filter: check the (lowercased) token set for English
        // keywords and the (original-case) raw string for Chinese (no
        // case folding needed for Chinese).
        var dateFilter: DateFilter?
        if tokenSet.contains("yesterday") || rawStripped.contains("昨天") { dateFilter = .yesterday }
        else if tokenSet.contains("today")     || rawStripped.contains("今天") { dateFilter = .today }
        else if lowerStripped.contains("last week")  || rawStripped.contains("上周")  { dateFilter = .lastWeek }
        else if lowerStripped.contains("last month") || rawStripped.contains("上个月") { dateFilter = .lastMonth }

        // Kind: image wins over pdf. The "image" / "photo" / "图片"
        // tokens are checked in the (lowercased) token set; ".pdf"
        // suffix is also token-set-friendly.
        var kind: FileKind?
        let hasImageToken = tokenSet.contains("image")
            || tokenSet.contains("photo")
            || rawStripped.contains("图片")
        let hasPdfToken = tokenSet.contains("pdf")
            || tokens.contains(where: { $0.hasSuffix(".pdf") })
        if hasImageToken { kind = .image }
        else if hasPdfToken { kind = .pdf }

        // Find verb: token-set intersection is faster than substring scan
        // and doesn't false-positive on "shower"/"opening"/etc.
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
