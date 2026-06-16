import Foundation

/// Phase 5-G: lightweight memory layer. Remembers what the
/// user has been doing in this session (and across sessions
/// via UserDefaults) so the AI can answer context-aware
/// questions like "what was that Swift file I just opened?"
/// or "summarize my recent searches".
///
/// **What we store**:
/// - `recentFiles`: the last N files the user opened via
///   the panel. LLM can refer to "the file I just looked at"
///   without the user naming it.
/// - `recentSearches`: the last N queries the user typed.
///   Useful for "I searched for X yesterday, find again"
///   style questions.
/// - `recentApps`: the last N apps the user launched. LLM
///   can guess what app the user means when they say "open
///   my notes" by matching the most recently-used one.
///
/// **What we DO NOT store**:
/// - File contents (would be a privacy concern; let the
///   LLM read them on demand via the `read_file` tool).
/// - API keys (already in Keychain).
/// - LLM conversation history (separate, in HistoryStore).
///
/// **Persistence**: UserDefaults via JSONEncoder. Lightweight,
/// no SQLite needed for ~20 items. If memory needs to grow
/// past 1000 items, we move to SQLite — the API is the same,
/// only the backend changes (see `pluggable-storage-backend`).
public actor MemoryStore {
    public static let shared = MemoryStore()

    // Phase 5-G: small caps. The user can scroll back
    // through "last 20 files" but anything older is gone.
    // Larger caps are unfriendly in the panel UI and make
    // every LLM ask carry more prompt tokens.
    public static let recentFilesCap = 20
    public static let recentSearchesCap = 20
    public static let recentAppsCap = 10

    /// Stored in UserDefaults under these keys. Each is
    /// a JSON-encoded array of strings.
    private static let kFiles = "memory.recentFiles"
    private static let kSearches = "memory.recentSearches"
    private static let kApps = "memory.recentApps"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Recorded when the user opens a file via the panel.
    /// Dedupes by path (so re-opening a file moves it to
    /// the front of the list, not duplicated).
    public func recordFileOpen(_ url: URL) {
        var list = load(Self.kFiles).compactMap { $0 as? String }
        // Standardize via .standardizedFileURL so equivalent
        // paths (e.g. /var/folders/... vs /private/var/...)
        // don't both appear. See `fileurl-symlink-comparison`
        // skill for the gotcha.
        let path = url.standardizedFileURL.path
        list.removeAll(where: { $0 == path })
        list.insert(path, at: 0)
        if list.count > Self.recentFilesCap {
            list = Array(list.prefix(Self.recentFilesCap))
        }
        save(Self.kFiles, list)
    }

    /// Recorded on every non-empty runSearch call.
    public func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load(Self.kSearches).compactMap { $0 as? String }
        list.removeAll(where: { $0 == trimmed })
        list.insert(trimmed, at: 0)
        if list.count > Self.recentSearchesCap {
            list = Array(list.prefix(Self.recentSearchesCap))
        }
        save(Self.kSearches, list)
    }

    /// Recorded when the user launches an app via the panel.
    public func recordAppLaunch(_ appName: String) {
        var list = load(Self.kApps).compactMap { $0 as? String }
        list.removeAll(where: { $0 == appName })
        list.insert(appName, at: 0)
        if list.count > Self.recentAppsCap {
            list = Array(list.prefix(Self.recentAppsCap))
        }
        save(Self.kApps, list)
    }

    // MARK: - Read accessors (sync, no actor hop needed)

    /// Synchronous access for the LLM prompt path. The
    /// actor protects the write paths; reads just return
    /// what's in UserDefaults. Marked `nonisolated` so
    /// callers (including the LLM prompt path) can read
    /// without an actor hop. We achieve this by routing
    /// through a thin helper that's also nonisolated and
    /// only touches the (Sendable) UserDefaults.
    public nonisolated func recentFiles() -> [String] {
        return loadNonisolated(Self.kFiles)
    }
    public nonisolated func recentSearches() -> [String] {
        return loadNonisolated(Self.kSearches)
    }
    public nonisolated func recentApps() -> [String] {
        return loadNonisolated(Self.kApps)
    }

    /// Same as `contextBlock()` but nonisolated, so the LLM
    /// system-block builder can call it synchronously.
    public nonisolated func contextBlockSync() -> String {
        let files = recentFiles()
        let searches = recentSearches()
        let apps = recentApps()
        if files.isEmpty && searches.isEmpty && apps.isEmpty {
            return ""
        }
        var out = "Recent activity in this app:\n"
        if !files.isEmpty {
            out += "  Files opened: " + files.prefix(5).map {
                ($0 as NSString).lastPathComponent
            }.joined(separator: ", ") + "\n"
        }
        if !searches.isEmpty {
            out += "  Recent searches: " + searches.prefix(5).joined(separator: ", ") + "\n"
        }
        if !apps.isEmpty {
            out += "  Apps launched: " + apps.prefix(5).joined(separator: ", ") + "\n"
        }
        return out
    }

    /// Render as a context block for the LLM system prompt.
    /// Returns empty string if there's nothing to remember.
    public func contextBlock() -> String {
        let files = recentFiles()
        let searches = recentSearches()
        let apps = recentApps()
        if files.isEmpty && searches.isEmpty && apps.isEmpty {
            return ""
        }
        var out = "Recent activity in this app:\n"
        if !files.isEmpty {
            out += "  Files opened: " + files.prefix(5).map {
                ($0 as NSString).lastPathComponent
            }.joined(separator: ", ") + "\n"
        }
        if !searches.isEmpty {
            out += "  Recent searches: " + searches.prefix(5).joined(separator: ", ") + "\n"
        }
        if !apps.isEmpty {
            out += "  Apps launched: " + apps.prefix(5).joined(separator: ", ") + "\n"
        }
        return out
    }

    // MARK: - Persistence helpers

    private func load(_ key: String) -> [Any] {
        defaults.array(forKey: key) ?? []
    }

    /// Nonisolated variant of `load`. The UserDefaults
    /// instance itself is captured in the actor's init
    /// but since it's a Sendable class and the only thing
    /// we read is the array, this is safe across actor
    /// boundaries.
    private nonisolated func loadNonisolated(_ key: String) -> [String] {
        let arr = defaults.array(forKey: key) ?? []
        return arr.compactMap { $0 as? String }
    }

    private func save(_ key: String, _ list: [String]) {
        defaults.set(list, forKey: key)
    }

    /// Clear all memory. Bound to a future Settings button
    /// ("Clear memory" / "Forget recent activity"). Exposed
    /// here so tests can reset state. nonisolated so the
    /// Settings UI and tests can call without an actor hop.
    public nonisolated func clearAll() {
        defaults.removeObject(forKey: Self.kFiles)
        defaults.removeObject(forKey: Self.kSearches)
        defaults.removeObject(forKey: Self.kApps)
    }
}
