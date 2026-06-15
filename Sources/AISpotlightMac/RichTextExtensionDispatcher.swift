import Foundation
import AISpotlightKit

/// Adapter from `RichTextExtractor` (NSAttributedString-based, lives
/// in this target) to `ExtensionTextDispatcher` (the Core protocol).
///
/// **Why this exists:** the Core `ContentIndexer` looks up extractors
/// in `IndexStore.dispatchers` keyed by file extension. The keys for
/// RTF / RTFD / HTML need to map to an object that conforms to
/// `ExtensionTextDispatcher`. This adapter wraps `RichTextExtractor`
/// (which is the actual extractor) and exposes it through the Core
/// protocol, without forcing Core to import AppKit.
public struct RichTextExtensionDispatcher: ExtensionTextDispatcher, Sendable {
    public init() {}
    public func extract(_ url: URL) throws -> String {
        try RichTextExtractor.extract(url)
    }
}

/// Default registrations for the App target. Call once at startup:
/// `indexStore.dispatchers = RichTextExtensionDispatcher.defaults`.
public extension RichTextExtensionDispatcher {
    static let defaults: [String: any ExtensionTextDispatcher] = {
        let rtf = RichTextExtensionDispatcher()
        return [
            "rtf": rtf,
            "rtfd": rtf,
            "html": rtf,
            "htm": rtf,
        ]
    }()
}
