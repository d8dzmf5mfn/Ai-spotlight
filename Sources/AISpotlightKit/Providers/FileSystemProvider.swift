import Foundation
import CoreServices

/// Synchronous Spotlight-based file search. Non-actor class so MDQuery
/// results can be populated in init without async races.
public final class FileSystemProvider: SearchProvider, @unchecked Sendable {
    public let name = "FileSystem"
    public init() {}

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        guard case let .findFile(name, date, kind, _) = intent else { return [] }
        let query = buildQuery(name: name, date: date, kind: kind)
        guard !query.isEmpty else { return [] }

        // B1: don't force-unwrap. MDQueryCreate returns NULL on bad syntax.
        guard let mdq = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else {
            return []
        }
        // B3: always release the query, even on early returns.
        defer {
            MDQueryStop(mdq)
        }
        defer {
            // MDQueryCreate returns a CFTypeRef (actually an MDQuery). Cast back and release.
            let raw = Unmanaged.passUnretained(mdq).toOpaque()
            Unmanaged<CFTypeRef>.fromOpaque(raw).release()
        }

        MDQueryExecute(mdq, CFOptionFlags(kMDQuerySynchronous.rawValue))
        let total = MDQueryGetResultCount(mdq)
        guard total > 0 else { return [] }

        // B2: ask the query for the path attribute explicitly. The default result
        // type for an unscoped MDQuery is the *value* of the matched attribute,
        // which is wrong here — we need the file's path, not the value that
        // matched the query string.
        let count = min(total, limit)
        var results: [SearchResult] = []
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdq, i) else { continue }
            // Cast raw to MDItem, then read its path via MDItemCopyAttribute.
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let pathCF = MDItemCopyAttribute(item, kMDItemPath as CFString) else { continue }
            let path = (pathCF as? String) ?? ""
            let url = URL(fileURLWithPath: path)
            results.append(SearchResult(
                title: url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().path,
                iconSystemName: "doc",
                url: url,
                kind: .file,
                score: Double(count - i)
            ))
        }
        return results
    }

    private func buildQuery(name: String?, date: DateFilter?, kind: FileKind?) -> String {
        var parts: [String] = []
        if let n = name, !n.isEmpty {
            // B4: escape single quotes in filename so the query stays valid.
            let escaped = n.replacingOccurrences(of: "'", with: "\\'")
            parts.append("kMDItemDisplayName == '\(escaped)*'c")
        }
        if let d = date {
            let seconds: Int = switch d {
            case .today: -86_400
            case .yesterday: -86_400 * 2
            case .lastWeek: -86_400 * 7
            case .lastMonth: -86_400 * 30
            }
            let from = Date().addingTimeInterval(TimeInterval(seconds))
            parts.append("kMDItemContentModificationDate >= $time.iso(\(from.iso8601))")
        }
        if let k = kind, let uti = k.uti {
            parts.append("kMDItemContentType == '\(uti)'")
        }
        return parts.joined(separator: " && ")
    }
}

extension FileKind {
    var uti: String? {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .image: return "public.image"
        case .document: return "public.document"
        case .code: return "public.source-code"
        case .archive: return "public.archive"
        case .any: return nil
        }
    }
}

extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
