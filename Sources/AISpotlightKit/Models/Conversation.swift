import Foundation

/// A saved conversation with a title, messages, and metadata.
public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [Message]
    public let createdAt: Date
    public var updatedAt: Date

    public struct Message: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public let role: Role
        public let text: String
        public let attachments: [Attachment]
        public init(role: Role, text: String, attachments: [Attachment] = []) {
            self.role = role
            self.text = text
            self.attachments = attachments
        }
    }

    public struct Attachment: Codable, Equatable, Sendable {
        public let filename: String
        public let path: String
        public let mimeType: String
        public init(filename: String, path: String, mimeType: String) {
            self.filename = filename
            self.path = path
            self.mimeType = mimeType
        }
    }

    public init(id: UUID = UUID(), title: String = "", messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages.count > 100 ? Array(messages.suffix(100)) : messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Manages saved conversations on disk.
public actor ConversationStore {
    private let fileURL: URL
    private var conversations: [Conversation] = []

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AISpotlight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("conversations.json")
        self.conversations = Self.load(from: fileURL)
    }

    public func all() -> [Conversation] { conversations.sorted { $0.updatedAt > $1.updatedAt } }
    public func save(_ conversation: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            var updated = conversation; updated.updatedAt = Date(); conversations[idx] = updated
        } else {
            var new = conversation; new.updatedAt = Date(); conversations.append(new)
            if conversations.count > 50 {
                conversations.sort { $0.updatedAt > $1.updatedAt }
                conversations = Array(conversations.prefix(50))
            }
        }
        Self.persist(conversations, to: fileURL)
    }
    public func delete(_ id: UUID) { conversations.removeAll { $0.id == id }; Self.persist(conversations, to: fileURL) }
    public func deleteAll() { conversations.removeAll(); Self.persist(conversations, to: fileURL) }
    public func get(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    private static func load(from url: URL) -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else { return [] }
        return decoded
    }
    private static func persist(_ list: [Conversation], to url: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
