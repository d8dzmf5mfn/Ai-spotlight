import Foundation
import CoreServices

// MARK: - FileProviderType

/// Known cloud-storage providers on macOS.
public enum FileProviderType: String, CaseIterable, Sendable {
    case oneDrive    = "OneDrive"
    case iCloud      = "iCloud"
    case dropbox     = "Dropbox"
    case googleDrive = "Google Drive"
    case box         = "Box"
    case unknown     = "Unknown"

    /// The expected suffix or prefix of the local storage path.
    public var storagePathComponent: String {
        switch self {
        case .oneDrive:    return "OneDrive"
        case .iCloud:      return "Mobile Documents"
        case .dropbox:     return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .box:         return "Box"
        case .unknown:     return ""
        }
    }
}

// MARK: - FileSystemAdapter

/// Unified adapter that discovers and searches across all mounted
/// file systems: local volumes, cloud-storage providers (OneDrive,
/// iCloud, Dropbox…), and external drives.
///
/// **Why this exists:** Apple's Spotlight (MDQuery) does not always
/// index cloud-storage files reliably, especially when files are
/// placeholder-only (not yet downloaded). This adapter falls back
/// to a direct `FileManager` enumeration of known storage roots so
/// the user can search OneDrive files even when Spotlight hasn't
/// indexed them.
public final class FileSystemAdapter: @unchecked Sendable {

    // MARK: - Known storage roots

    /// All known file-system roots that should be searched.
    /// Includes home-directory standard folders AND detected
    /// cloud-storage paths.
    public static func allStorageRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Standard user folders (always searchable)
        let standardRoots: [URL] = [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Movies"),
        ]

        // Cloud-storage roots
        let cloudRoots = detectCloudStorageRoots()

        // External volumes
        let externalRoots = detectExternalVolumes()

        return (standardRoots + cloudRoots + externalRoots)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Detect cloud-storage provider paths by checking common
    /// locations under the user's home directory.
    public static func detectCloudStorageRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var roots: [URL] = []

        // OneDrive: typically at ~/Library/CloudStorage/OneDrive-<tenant>/
        // or ~/OneDrive/
        let possibleOneDrivePaths: [URL] = [
            home.appendingPathComponent("Library/CloudStorage"),
            home.appendingPathComponent("OneDrive"),
        ]
        for base in possibleOneDrivePaths {
            guard fm.fileExists(atPath: base.path) else { continue }
            // If it's a directory with sub-items, enumerate children
            if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
                for item in items {
                    if item.lastPathComponent.contains("OneDrive") || item.lastPathComponent.hasPrefix("OneDrive") {
                        roots.append(item)
                    }
                }
            }
            // If the base itself is a OneDrive path, add it
            if base.lastPathComponent == "OneDrive" && !roots.contains(base) {
                roots.append(base)
            }
        }

        // iCloud Drive: ~/Library/Mobile Documents/
        let icloud = home.appendingPathComponent("Library/Mobile Documents")
        if fm.fileExists(atPath: icloud.path) {
            roots.append(icloud)
        }

        // Dropbox: ~/Dropbox/
        let dropbox = home.appendingPathComponent("Dropbox")
        if fm.fileExists(atPath: dropbox.path) {
            roots.append(dropbox)
        }

        // Google Drive: ~/Google Drive/ or ~/Library/CloudStorage/GoogleDrive
        let gdrive1 = home.appendingPathComponent("Google Drive")
        let gdrive2 = home.appendingPathComponent("Library/CloudStorage/GoogleDrive")
        if fm.fileExists(atPath: gdrive1.path) { roots.append(gdrive1) }
        if fm.fileExists(atPath: gdrive2.path) { roots.append(gdrive2) }

        return roots
    }

    /// Detect mounted external volumes at /Volumes.
    public static func detectExternalVolumes() -> [URL] {
        let volumes = URL(fileURLWithPath: "/Volumes")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: volumes, includingPropertiesForKeys: [.volumeNameKey]
        ) else { return [] }
        // Skip the "Macintosh HD" alias and hidden volumes
        return items.filter { item in
            let name = item.lastPathComponent
            return !name.hasPrefix(".")
                && name != "Macintosh HD"
                && FileManager.default.fileExists(atPath: item.path)
        }
    }

    // MARK: - Search

    /// Search across all storage roots for files matching `query`.
    /// Falls back from Spotlight MDQuery to FileManager enumeration
    /// when MDQuery returns incomplete results.
    public static func search(query: String, limit: Int = 30) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let roots = allStorageRoots()
        var results: [SearchResult] = []
        var seen = Set<String>()

        // Phase 1: Try Spotlight MDQuery first (fast, metadata-rich)
        let spotlightResults = spotlightSearch(query: trimmed, limit: limit)
        for r in spotlightResults {
            if seen.insert(r.url.path).inserted {
                results.append(r)
            }
        }

        // Phase 2: Fallback — direct FileManager enumeration for
        // cloud-storage roots where Spotlight may be incomplete.
        if results.count < limit {
            for root in roots {
                guard root.path.contains("OneDrive")
                        || root.path.contains("Mobile Documents")
                        || root.path.contains("CloudStorage")
                else { continue }  // Only fallback for cloud storage

                let dirEnumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let fileURL = dirEnumerator?.nextObject() as? URL {
                    guard results.count < limit else { break }

                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    let isDir = resourceValues?.isDirectory ?? false
                    if isDir { continue }

                    let filename = fileURL.lastPathComponent
                    // Case-insensitive substring match
                    if filename.localizedCaseInsensitiveContains(trimmed) {
                        if seen.insert(fileURL.path).inserted {
                            results.append(SearchResult(
                                title: filename,
                                subtitle: fileURL.deletingLastPathComponent().path,
                                iconSystemName: "doc",
                                url: fileURL,
                                kind: .file,
                                score: 0.9  // High score for direct match
                            ))
                        }
                    }
                }
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Internal Spotlight search via MDQuery.
    /// CJK queries are SKIPPED — MDQuery predicate parser crashes with
    /// Chinese characters on macOS 27 beta (SIGSEGV at MDQueryExecute).
    private static func spotlightSearch(query: String, limit: Int) -> [SearchResult] {
        // Phase 6.2: CJK characters crash MDQuery on macOS beta. Skip.
        if CJKUtils.containsCJK(query) {
            return []
        }

        // Escape single quotes for MDQuery
        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        let mdQueryStr = "kMDItemDisplayName == '*\(escaped)*'cd"  // cd = case+diacritic insensitive

        guard let mdq = MDQueryCreate(kCFAllocatorDefault, mdQueryStr as CFString, nil, nil) else {
            return []
        }
        // B3: always release the query, even on early returns.
        // CRITICAL: defer blocks execute in LIFO order — release (declare FIRST, run LAST)
        // must be declared BEFORE stop so that stop runs first on scope exit.
        defer {
            let raw = Unmanaged.passUnretained(mdq).toOpaque()
            Unmanaged<CFTypeRef>.fromOpaque(raw).release()
        }
        defer {
            MDQueryStop(mdq)
        }

        MDQueryExecute(mdq, CFOptionFlags(kMDQuerySynchronous.rawValue))
        let total = MDQueryGetResultCount(mdq)
        guard total > 0 else { return [] }
        let count = min(total, limit)

        var results: [SearchResult] = []
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdq, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let pathCF = MDItemCopyAttribute(item, kMDItemPath as CFString) as? String else { continue }
            let url = URL(fileURLWithPath: pathCF)

            // Skip directories for file search
            if let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                continue
            }

            // Score: first results get higher score
            let score = count > 0 ? Double(count - i) / Double(count) : 0
            results.append(SearchResult(
                title: url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().path,
                iconSystemName: "doc",
                url: url,
                kind: .file,
                score: score
            ))
        }
        return results
    }
}
