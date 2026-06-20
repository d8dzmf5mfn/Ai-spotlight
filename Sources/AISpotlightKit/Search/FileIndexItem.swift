import Foundation

// MARK: - FileIndexItem

/// The unified index model for ALL file-system sources (local FS,
/// OneDrive, iCloud, external drives, etc.).
///
/// **Design goal:** one struct that every index source writes and
/// every search consumer reads. No more scattered URL+metadata pairs.
public struct FileIndexItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String       // Stable hash of URL
    public let url: URL
    public let filename: String
    public let path: String
    public let providerType: ProviderType
    public let isDirectory: Bool
    public let fileSize: UInt64?
    public let lastModified: Date?
    public let contentType: String?  // UTI or MIME type
    public let contentPreview: String?  // First N chars (max 2000)
    public let lastIndexed: Date

    public enum ProviderType: String, Codable, Sendable, CaseIterable {
        case local       // ~/Documents, ~/Downloads, etc.
        case cloud       // OneDrive, iCloud Drive, Dropbox, Google Drive
        case external    // External/removable volumes
        case app         // /Applications

        public var label: String {
            switch self {
            case .local:    return "Local"
            case .cloud:    return "Cloud"
            case .external: return "External"
            case .app:      return "App"
            }
        }
    }

    public init(url: URL, providerType: ProviderType, isDirectory: Bool, fileSize: UInt64? = nil, lastModified: Date? = nil, contentType: String? = nil, contentPreview: String? = nil) {
        self.id = url.path.hashValue.description + providerType.rawValue
        self.url = url
        self.filename = url.lastPathComponent
        self.path = url.path
        self.providerType = providerType
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.lastModified = lastModified
        self.contentType = contentType
        self.contentPreview = contentPreview
        self.lastIndexed = Date()
    }
}

// MARK: - IndexEvent

/// Events emitted by `IndexSource` implementations to notify the
/// `IndexEngine` of filesystem changes.
public enum IndexEvent: Sendable, Equatable {
    /// A file was added or modified.
    case upserted(FileIndexItem)
    /// A file was deleted.
    case deleted(url: URL)
    /// A batch of changes occurred (FSEvents coalescing).
    case batch(upserts: [FileIndexItem], deletes: [URL])
    /// The source finished a full re-scan.
    case scanComplete(providerType: FileIndexItem.ProviderType, itemCount: Int)
    /// An error occurred during indexing.
    case error(providerType: FileIndexItem.ProviderType, message: String)
}
