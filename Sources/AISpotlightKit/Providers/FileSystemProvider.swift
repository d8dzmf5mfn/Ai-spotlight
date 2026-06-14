import Foundation
import CoreServices

public actor FileSystemProvider: SearchProvider {
    public nonisolated let name = "FileSystem"
    public init() {}

    public func search(intent: Intent, limit: Int = 20) async -> [SearchResult] {
        guard case let .findFile(name, date, kind) = intent else { return [] }
        let query = buildQuery(name: name, date: date, kind: kind)
        guard !query.isEmpty else { return [] }

        let mdq = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil)!
        MDQueryExecute(mdq, CFOptionFlags(kMDQuerySynchronous.rawValue))
        guard MDQueryGetResultCount(mdq) > 0 else { return [] }

        let count = min(MDQueryGetResultCount(mdq), limit)
        var results: [SearchResult] = []
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdq, i) else { continue }
            let ptr = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
            let path = ptr as String
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
        MDQueryStop(mdq)
        return results
    }

    private func buildQuery(name: String?, date: DateFilter?, kind: FileKind?) -> String {
        var parts: [String] = []
        if let n = name, !n.isEmpty { parts.append("kMDItemDisplayName == '\(n)*'c") }
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
