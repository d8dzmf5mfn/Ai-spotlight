import Foundation

/// Built-in pseudo-commands surfaced as search results. These bypass the
/// file/app search and let the user reach hidden UI (Settings, Quit) by
/// typing rather than right-clicking a menu bar item.
public enum Command: Hashable, Sendable {
    case openSettings
    case quit
}

/// Recognizes built-in commands from a user query. Returns the matching
/// `Command` if the query matches one (case-insensitive, whitespace-
/// tolerant), otherwise nil. Lives in the Kit so it can be unit-tested
/// without pulling in AppKit.
public enum CommandMatcher {
    /// Map of command → list of recognized names (lowercased, English +
    /// Chinese). Matching is a **prefix** match: typing "set" matches
    /// "settings", "prefs" matches "preferences", etc. — the same
    /// fuzzy UX as Spotlight/Alfred.
    private static let commands: [(name: String, prefixes: [String])] = [
        ("Open AI Spotlight Settings", [
            "settings", "preferences", "prefs", "pref", "config", "setup", "set",
            "设置", "首选项", "偏好设置", "设置项",
        ]),
        ("Quit AI Spotlight", [
            "quit", "exit", "close", "qui",
            "退出", "离开",
        ]),
    ]

    public static func match(_ q: String) -> Command? {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return nil }
        for (label, prefixes) in commands {
            // User can type a substring of the command name (typing "set"
            // still hits "settings") OR the full command. We don't match
            // in the opposite direction (typing "settingsx" should NOT hit
            // anything) because that would make it impossible to ever
            // type a non-command that happens to start with a known prefix.
            if prefixes.contains(where: { $0 == trimmed || trimmed.hasPrefix($0) }) {
                return Self.command(for: label)
            }
        }
        return nil
    }

    private static func command(for label: String) -> Command? {
        switch label {
        case "Open AI Spotlight Settings": return .openSettings
        case "Quit AI Spotlight":          return .quit
        default:                          return nil
        }
    }
}
