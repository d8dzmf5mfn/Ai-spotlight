import Foundation

public struct SearchResult: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let subtitle: String?
    public let iconSystemName: String
    public let url: URL
    public let kind: Kind
    public let score: Double

    public enum Kind: Equatable, Sendable { case file, folder, app }

    public init(title: String, subtitle: String?, iconSystemName: String, url: URL, kind: Kind, score: Double) {
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.url = url
        self.kind = kind
        self.score = score
    }
}

public protocol SearchProvider: Sendable {
    var name: String { get }
    func search(intent: Intent, limit: Int) async -> [SearchResult]
}
