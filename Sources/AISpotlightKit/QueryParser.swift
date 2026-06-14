import Foundation

public enum QueryParser {
    public static func parse(_ raw: String) -> Intent {
        let lower = raw.lowercased()
        // App open
        if let m = matchApp(lower, raw: raw) { return m }
        // File find
        return matchFile(lower, raw: raw)
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
        var dateFilter: DateFilter?
        if lower.contains("yesterday") || raw.contains("昨天") { dateFilter = .yesterday }
        else if lower.contains("today") || raw.contains("今天") { dateFilter = .today }
        else if lower.contains("last week") || raw.contains("上周") { dateFilter = .lastWeek }
        else if lower.contains("last month") || raw.contains("上个月") { dateFilter = .lastMonth }

        var kind: FileKind?
        if lower.contains("pdf") || raw.contains("PDF") { kind = .pdf }
        else if lower.contains("image") || lower.contains("photo") || raw.contains("图片") { kind = .image }

        let hasFindVerb = findVerbsEN.contains(where: lower.contains)
            || findVerbsCN.contains(where: raw.contains)

        if dateFilter != nil || kind != nil || hasFindVerb {
            return .findFile(name: extractName(raw), dateFilter: dateFilter, kind: kind)
        }
        return .unknown(raw: raw)
    }

    private static func extractName(_ raw: String) -> String? {
        // Find token with a file extension
        let tokens = raw.split(separator: " ")
        return tokens.first(where: { $0.contains(".") && $0.count > 2 }).map(String.init)
    }
}
